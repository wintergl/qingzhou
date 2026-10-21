using System.Text.Json.Nodes;
using System.Windows.Threading;

namespace Qingzhou;

public sealed record Member(string? IdentityKey, string Name, string? Issue, bool? Available, double? Delay, bool Current)
{
    public string Id => IdentityKey ?? Name;
}

public sealed record GroupInfo(string Id, string Name, string RuntimeName, bool Selected, IReadOnlyList<Member> Members)
{
    public bool IsSubscription => Id.StartsWith("subscription:");
}

/// App state shared by every page; mirrors VPNStore on macOS.
public sealed class Store
{
    public readonly ICoreClient Core;
    readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    DispatcherTimer? polling;
    bool refreshing, startupRequested, started, stopped, readingTraffic, transportClosed, statusReadFailed;
    VPNTrayState? connectionState;
    IRuntimeMonitor? monitor;
    bool networkPending, sendingNetwork;
    bool? pendingAvailability;
    DesktopActivity? pendingEnvironment;
    Task environmentPump = Task.CompletedTask;
    long networkGeneration, statusGeneration;

    public Store(ICoreClient? core = null) => Core = core ?? new CoreClient();
    public DesktopActivity Activity { get; private set; } = new();

    public JsonNode? Status { get; private set; }
    public List<JsonNode> Nodes { get; private set; } = [];
    public List<GroupInfo> Groups { get; private set; } = [];
    public List<JsonNode> Risks { get; private set; } = [];
    public JsonNode? Traffic { get; private set; }
    public JsonNode? Connectivity { get; private set; }
    public JsonNode? Websites { get; private set; }
    public JsonNode? RiskProgress { get; private set; }
    public string DataDir { get; private set; } = "";
    public bool PreviewOnly { get; private set; } = true;
    public bool LegacyOwner { get; private set; }
    public bool OwnsRuntime { get; private set; }
    public bool RiskBatchRunning { get; private set; }
    public bool RiskKeyConfigured { get; private set; }
    public bool LaunchAtLogin { get; private set; }
    public string? Busy { get; private set; }
    public string? Message { get; set; }
    public string? BatchMessage { get; private set; }
    public string? RiskBatchNote { get; private set; }

    /// Argument: true when only traffic data changed.
    public event Action<bool>? Changed;
    public event Action<string>? Navigate;
    public Action<string>? ShowError;
    public Action<JsonNode?>? OnCompanyRouting;

    public JsonNode? Settings => Status.At("settings");
    public bool StatusKnown => Status is not null && !transportClosed && !statusReadFailed;
    public bool Running => Status.At("mihomo").At("state").Str() == "running";
    public string RecoveryState => Status.At("mihomo").At("networkRecovery").At("state").Str() ?? "idle";
    public bool Recovering => RecoveryState is "waiting-network" or "recovering" or "failed" or "helper-update-required";
    public bool Connected => Running && !Recovering && StatusKnown;
    public bool PersonalTrayConnected => StatusKnown && Running && (RecoveryState is "idle" or "ready");
    public VPNTrayState TrayState => !StatusKnown ? (transportClosed || statusReadFailed ? VPNTrayState.Unknown : VPNTrayState.Loading)
        : connectionState ?? (Status.At("mihomo").At("state").Str() == "error" ? VPNTrayState.Error : RecoveryState switch
        {
            "waiting-network" or "recovering" => VPNTrayState.Connecting,
            "failed" or "helper-update-required" => VPNTrayState.Error,
            _ => Running ? VPNTrayState.Connected : VPNTrayState.Disconnected,
        });
    public string TrayTitle => TrayState switch
    {
        VPNTrayState.Loading => "读取连接状态…",
        VPNTrayState.Unknown => "连接状态未知",
        VPNTrayState.Connecting when connectionState is null && RecoveryState == "waiting-network" => "等待网络恢复…",
        VPNTrayState.Connecting when connectionState is null && RecoveryState == "recovering" => "网络恢复中…",
        VPNTrayState.Connecting => "正在连接…",
        VPNTrayState.Disconnecting => "正在断开…",
        VPNTrayState.Error when RecoveryState == "failed" => "网络恢复失败",
        VPNTrayState.Error when RecoveryState == "helper-update-required" => "连接服务待更新",
        VPNTrayState.Error => "连接异常",
        VPNTrayState.Connected when Status.At("mihomo").At("mode").Str() == "subscription-probe" => "订阅检测中",
        VPNTrayState.Connected when Settings.At("tun").Bool() == false => "代理服务已开启",
        VPNTrayState.Connected => "VPN 已开启",
        _ => "VPN 已关闭",
    };
    public bool ConnectionRequested => Running || Recovering;
    public string ConnectionLabel => transportClosed ? "服务已结束" : statusReadFailed ? "状态未知" : Status is null ? "读取中" : RecoveryState switch
    {
        "waiting-network" => "等待网络",
        "recovering" => "恢复连接中",
        "failed" => "恢复失败",
        "helper-update-required" => "连接服务需更新",
        _ => Running ? "已连接" : "未连接",
    };
    public string RecoveryMessage => RecoveryState switch
    {
        "waiting-network" => "网络暂不可用，恢复后会自动重新连接。也可以点击断开，取消自动恢复。",
        "recovering" => "网络发生变化，正在等待网络稳定并恢复连接。",
        "failed" => Status.At("mihomo").At("networkRecovery").At("error").Str() ?? "自动恢复未完成，可以点击重试或断开连接。",
        "helper-update-required" => "请重新打开最新版本的轻舟后再连接。",
        _ => "",
    };
    public JsonNode? LatestRecovery => Status.At("mihomo").At("networkRecovery").At("history") is JsonArray records && records.Count > 0 ? records[0] : null;
    public string LatestRecoveryMessage
    {
        get
        {
            var record = LatestRecovery;
            if (record is null) return "";
            var result = record.At("outcome").Str() switch
            {
                "verified" => "分流已恢复 · 代理访问已验证",
                "unverified" => "分流已恢复 · 代理访问尚未确认",
                "checking" => "分流已恢复 · 正在检查代理访问",
                "failed" => "自动恢复失败",
                "cancelled" => "已取消恢复",
                "interrupted" => "网络再次变化，旧检测已结束",
                _ => "连接服务待更新",
            };
            var time = DateTimeOffset.TryParse(record.At("finishedAt").Str(), out var date) ? date.ToLocalTime().ToString("MM-dd HH:mm:ss") : "时间未知";
            var seconds = Math.Max(1, (int)((record.At("durationMs").Num() ?? 0) / 1000));
            return $"{result}\n{time} · 耗时 {seconds} 秒";
        }
    }
    public string SelectedProxy => Settings.At("selectedProxy").Str() ?? "尚未读取";
    public string DisplaySelectedProxy => Groups.FirstOrDefault(g => g.RuntimeName.Length > 0 && g.RuntimeName == SelectedProxy)?.Name ?? SelectedProxy;
    public HashSet<string> Favorites => Settings.At("favoriteNodeNames").Strings().ToHashSet();
    public IEnumerable<JsonNode> ProviderNodes => Nodes.Where(n => n.At("identityKey").Str() is not null);
    public JsonNode? CurrentRisk => Risks.FirstOrDefault(r => r.At("nodeName").Str() == SelectedProxy);
    public bool CanMutate => !stopped && StatusKnown && !PreviewOnly && Busy is null;
    public bool ConnectionProtected => LegacyOwner && Running && !OwnsRuntime;

    public void Notify(bool trafficOnly = false)
    {
        if (stopped) return;
        ConfigurePolling();
        Changed?.Invoke(trafficOnly);
    }
    public void Go(string page) => Navigate?.Invoke(page);
    void Fail(string message) { if (!stopped) ShowError?.Invoke(message); }

    public async Task Start(IRuntimeMonitor? runtimeMonitor = null)
    {
        if (started || stopped) return;
        started = true;
        Core.Event += OnCoreEvent;
        polling = new DispatcherTimer();
        polling.Tick += Poll;
        monitor = runtimeMonitor;
        if (monitor is not null)
        {
            monitor.NetworkChanged += OnNetworkChanged;
            monitor.ActivityChanged += OnActivityChanged;
            monitor.Start();
            await environmentPump;
        }
        if (stopped) return;
        try { LaunchAtLogin = await Task.Run(LoginTask.Enabled); } catch { }
        if (stopped) return;
        await Refresh();
        if (stopped) return;
        await ConnectOnStartup();
        if (stopped) return;
        await RestoreRiskKey();
    }

    void OnCoreEvent(string name, JsonNode? data)
    {
        var copy = data?.DeepClone();
        if (!stopped && !dispatcher.HasShutdownStarted)
            dispatcher.InvokeAsync(() => { if (!stopped) OnEvent(name, copy); });
    }

    void ConfigurePolling()
    {
        if (polling is null) return;
        var delay = Activity.PollInterval(StatusKnown, Running);
        if (stopped || transportClosed || Busy is not null || refreshing || readingTraffic || delay is null)
        { polling.Stop(); return; }
        if (polling.Interval != delay.Value) polling.Interval = delay.Value;
        if (!polling.IsEnabled) polling.Start();
    }

    async void Poll(object? sender, EventArgs e)
    {
        polling?.Stop();
        if (stopped || transportClosed || Activity.Sleeping) return;
        if (!StatusKnown)
            await RecoverInitialState();
        else await RefreshTraffic();
        ConfigurePolling();
    }

    async Task RecoverInitialState()
    {
        await Refresh(showError: false);
        if (!stopped && StatusKnown)
        {
            await ConnectOnStartup();
            if (!stopped) await RestoreRiskKey();
        }
    }

    void InvalidateNetworkResults()
    {
        networkGeneration++;
        Connectivity = null;
        Websites = null;
        Traffic = null;
    }

    void OnActivityChanged(DesktopActivity next)
    {
        if (stopped) return;
        var previous = Activity;
        Activity = next;
        if (previous.Sleeping != next.Sleeping) InvalidateNetworkResults();
        pendingEnvironment = next;
        if (environmentPump.IsCompleted) environmentPump = SendEnvironment();
        Notify();
        if (next.CanRefresh && !previous.CanRefresh)
        {
            if (!StatusKnown) _ = RecoverInitialState();
            else _ = RefreshTraffic();
        }
    }

    async Task SendEnvironment()
    {
        while (!stopped && pendingEnvironment is { } next)
        {
            pendingEnvironment = null;
            try
            {
                await Core.Request("native:runtime-environment", new JsonObject
                {
                    ["sleeping"] = next.Sleeping, ["lowPower"] = next.LowPower,
                    ["networkEvents"] = monitor?.NetworkEventsAvailable == true,
                });
            }
            catch { /* Core's conservative watchdog remains active if a notification fails. */ }
        }
    }

    void OnNetworkChanged(bool? available)
    {
        if (stopped || transportClosed) return;
        InvalidateNetworkResults();
        pendingAvailability = available;
        networkPending = true;
        Notify();
        if (!sendingNetwork) _ = SendNetworkChange();
    }

    async Task SendNetworkChange()
    {
        sendingNetwork = true;
        try
        {
            while (!stopped && networkPending)
            {
                networkPending = false;
                var payload = new JsonObject();
                if (pendingAvailability is { } available) payload["available"] = available;
                try { await Core.Request("native:network-changed", payload); }
                catch { /* Background recovery also checks the physical path periodically. */ }
            }
        }
        finally { sendingNetwork = false; }
    }

    public void Stop()
    {
        if (stopped) return;
        // Update visible pages once so their own timers stop before core shutdown.
        Activity = Activity with { Sleeping = true };
        Changed?.Invoke(false);
        stopped = true;
        polling?.Stop();
        Core.Event -= OnCoreEvent;
        if (monitor is not null)
        {
            monitor.NetworkChanged -= OnNetworkChanged;
            monitor.ActivityChanged -= OnActivityChanged;
            monitor.Dispose();
        }
    }

    void OnEvent(string name, JsonNode? data)
    {
        if (name == "core:disconnected")
        {
            transportClosed = true;
            statusGeneration++;
            OnCompanyRouting?.Invoke(null);
            InvalidateNetworkResults();
            Message = data.Str() ?? "VPN 服务已结束，请重新打开轻舟。";
            Notify();
            return;
        }
        if (name == "vpn:status")
        {
            if (Status is JsonObject status && data is not null) { status["mihomo"] = data; statusGeneration++; }
            Notify();
            return;
        }
        if (name == "company:routing-state")
        {
            OnCompanyRouting?.Invoke(data);
            return;
        }
        if (name == "nodes:risk-progress")
        {
            RiskProgress = data;
            var finished = data.At("finished").Bool() == true;
            RiskBatchRunning = !finished;
            if (data.At("result") is { } result && result.At("nodeName").Str() is { } node)
            {
                var index = Risks.FindIndex(r => r.At("nodeName").Str() == node);
                if (index >= 0) Risks[index] = result; else Risks.Add(result);
            }
            Notify();
            if (finished)
            {
                if (data.At("error").Str() is { } error) Fail(error);
                _ = Refresh();
            }
            return;
        }
        if (name.Contains("progress"))
        {
            var done = (data.At("checked") ?? data.At("completed")).Num() ?? 0;
            var total = data.At("total").Num() ?? 0;
            BatchMessage = $"检测进度 {done:0} / {total:0}";
            if (data.At("finished").Bool() == true)
            {
                BatchMessage = "检测已完成";
                _ = Refresh();
            }
            Notify();
        }
    }

    public async Task Refresh(bool showError = true)
    {
        if (stopped || refreshing || transportClosed) return;
        refreshing = true;
        ConfigurePolling();
        try
        {
            var data = await Core.Request("native:bootstrap");
            if (stopped) return;
            Status = data.At("status");
            statusReadFailed = Status is null;
            statusGeneration++;
            Nodes = data.At("nodes").Items().ToList();
            Risks = data.At("risks").Items().ToList();
            Traffic = data.At("traffic");
            PreviewOnly = data.At("previewOnly").Bool() ?? true;
            LegacyOwner = data.At("legacyOwnerRunning").Bool() == true;
            OwnsRuntime = data.At("ownsRuntime").Bool() == true;
            DataDir = data.At("dataDir").Str() ?? "";
            Groups = BuildGroups(data.At("groups"));
            OnCompanyRouting?.Invoke(data.At("companyRouting"));
        }
        catch (Exception e)
        {
            statusReadFailed = true;
            statusGeneration++;
            OnCompanyRouting?.Invoke(null);
            if (showError) Fail(e.Message);
        }
        finally
        {
            refreshing = false;
            Notify();
        }
    }

    List<GroupInfo> BuildGroups(JsonNode? runtime)
    {
        var states = runtime.Items()
            .Where(s => s.At("group").At("id").Str() is not null)
            .GroupBy(s => s.At("group").At("id").Str()!)
            .ToDictionary(g => g.Key, g => g.First());
        return Settings.At("nodeGroups").Items().Select(group =>
        {
            var id = group.At("id").Str() ?? "";
            var name = group.At("name").Str() ?? id;
            if (states.TryGetValue(id, out var state))
            {
                var members = state.At("members").Items().Select(m => new Member(
                    m.At("identityKey").Str(), m.At("lastKnownName").Str() ?? "", m.At("issue").Str(),
                    m.At("available").Bool(), m.At("delay").Num(), m.At("current").Bool() == true)).ToList();
                return new GroupInfo(id, name, state.At("runtimeName").Str() ?? "", state.At("selected").Bool() == true, members);
            }
            // Subscription groups are kept in the saved schema but the runtime
            // API only returns custom groups. Show both.
            var subscription = id.StartsWith("subscription:") ? id["subscription:".Length..] : null;
            var built = group.At("nodeNames").Strings().Select(nodeName =>
            {
                var node = Nodes.FirstOrDefault(n => n.At("name").Str() == nodeName &&
                    (subscription is null || n.At("subscriptionId").Str() == subscription));
                return new Member(node.At("identityKey").Str(), nodeName, node is null ? "节点已移除或订阅停用" : null,
                    node.At("available").Bool(), node.At("delay").Num(), node.At("selected").Bool() == true);
            }).ToList();
            return new GroupInfo(id, name, "", false, built);
        }).ToList();
    }

    async Task RefreshTraffic()
    {
        if (stopped || readingTraffic || refreshing || !Running || !Activity.CanRefresh || Busy is not null) return;
        readingTraffic = true;
        ConfigurePolling();
        var generation = networkGeneration;
        var confirmation = statusGeneration;
        try
        {
            var traffic = await Core.Request("traffic:get-monitor");
            if (stopped || generation != networkGeneration || confirmation != statusGeneration) return;
            Traffic = traffic;
            Notify(trafficOnly: true);
        }
        catch
        {
            if (!stopped && generation == networkGeneration && confirmation == statusGeneration)
            {
                statusReadFailed = true;
                statusGeneration++;
                OnCompanyRouting?.Invoke(null);
                Notify();
            }
        }
        finally { readingTraffic = false; ConfigurePolling(); }
    }

    async Task ConnectOnStartup()
    {
        if (startupRequested || !CanMutate) return;
        startupRequested = true;
        Busy = Running ? "读取连接状态" : "自动连接 VPN";
        connectionState = Running ? null : VPNTrayState.Connecting;
        Notify();
        try
        {
            var result = await Core.Request("native:startup-connect");
            if (Status is JsonObject status && result.At("mihomo") is { } mihomo) status["mihomo"] = mihomo.DeepClone();
            await Refresh();
            var outcome = result.At("startupOutcome").Str();
            if (outcome == "connected") Message = "已自动连接 VPN。";
            else if (outcome == "waiting-network") Message = "网络尚未就绪，就绪后将自动连接 VPN。";
        }
        catch (Exception e) { Fail($"自动连接未完成：{e.Message}"); }
        finally
        {
            connectionState = null;
            Busy = null;
            Notify();
        }
    }

    public async void Act(string title, string channel, JsonObject? payload = null)
    {
        if (!CanMutate) { Fail("服务尚未就绪或已有操作正在进行，请稍后重试。"); return; }
        Busy = title;
        connectionState = channel switch { "vpn:start" => VPNTrayState.Connecting, "vpn:stop" => VPNTrayState.Disconnecting, _ => null };
        Message = null;
        Notify();
        try
        {
            var result = await Core.Request(channel, payload);
            if (result.At("controllerOk").Bool() == false)
                throw new CoreException(result.At("controllerError").Str() ?? "内核连接验证失败。");
            await Refresh();
            Message = $"{title}完成";
        }
        catch (Exception e) { Fail(e.Message); }
        finally
        {
            connectionState = null;
            Busy = null;
            Notify();
        }
    }

    public async Task SaveRoutingRule(JsonObject payload, bool editing)
    {
        if (!CanMutate) throw new CoreException("服务尚未就绪或已有操作正在进行，请稍后重试。");
        Busy = "保存分流规则";
        Message = null;
        Notify();
        try
        {
            await Core.Request(editing ? "routing:edit-rule" : "routing:add-rule", payload);
            await Refresh();
            Message = "分流规则已保存";
        }
        finally { Busy = null; Notify(); }
    }

    public void ConnectOrDisconnect()
    {
        if (!CanMutate) return;
        if (!ConnectionRequested && SelectedProxy != "DIRECT" &&
            !ProviderNodes.Any(n => n.At("name").Str() == SelectedProxy && n.At("identityAmbiguous").Bool() != true))
        {
            Message = "请选择一个具体节点后连接 VPN。";
            Go("节点");
            Notify();
            return;
        }
        if (ConnectionProtected) CheckConnectivity();
        else Act(ConnectionRequested ? "断开 VPN" : "连接 VPN", ConnectionRequested ? "vpn:stop" : "vpn:start");
    }

    public void RetryRecovery() => Act("重试恢复", "vpn:retry-recovery");

    public void Select(JsonNode node)
    {
        if (node.At("identityKey").Str() is { } identity) Act("切换出口", "nodes:select-v2", new JsonObject { ["identityKey"] = identity });
        else if (node.At("name").Str() == "DIRECT") Act("切换出口", "nodes:select", new JsonObject { ["nodeName"] = "DIRECT" });
    }

    public void ToggleFavorite(JsonNode node) => Act("保存收藏", "native:favorite", new JsonObject { ["name"] = node.At("name").Str() });

    public void SaveGroups(IEnumerable<JsonNode> groups) =>
        Act("保存节点组", "node-groups:save", new JsonObject { ["nodeGroups"] = new JsonArray(groups.Select(g => (JsonNode?)g.DeepClone()).ToArray()) });

    public async void CheckAllRisks()
    {
        if (!CanMutate || !Running || RiskBatchRunning) return;
        var all = ProviderNodes.ToList();
        var usable = all.Where(n => n.At("identityAmbiguous").Bool() != true).ToList();
        if (usable.Count == 0) { Fail("没有可检测的订阅节点。"); return; }
        RiskBatchRunning = true;
        RiskProgress = null;
        var skipped = all.Count - usable.Count;
        RiskBatchNote = skipped > 0 ? $"{skipped} 个同名冲突节点无法区分出口，已跳过。" : null;
        Notify();
        try
        {
            await Core.Request("nodes:start-risk-batch", new JsonObject
            {
                ["nodeNames"] = J.Array(usable.Select(n => n.At("name").Str() ?? "")),
                ["forceRefresh"] = true,
            });
        }
        catch (Exception e)
        {
            RiskBatchRunning = false;
            Notify();
            Fail(e.Message);
        }
    }

    public async void CancelRiskBatch()
    {
        try { await Core.Request("nodes:cancel-risk-batch"); } catch (Exception e) { Fail(e.Message); }
    }

    public async void CheckConnectivity()
    {
        if (!CanMutate) return;
        Busy = "检测连通性";
        var generation = networkGeneration;
        Notify();
        try
        {
            var result = await Core.Request("connectivity:check");
            if (!stopped && generation == networkGeneration) Connectivity = result;
            await Refresh();
        }
        catch (Exception e) { Fail(e.Message); }
        finally { Busy = null; Notify(); }
    }

    public async void TestWebsites()
    {
        if (!CanMutate) return;
        Busy = "检测站点";
        var generation = networkGeneration;
        Notify();
        try
        {
            var result = await Core.Request("connectivity:test-website-speeds");
            if (!stopped && generation == networkGeneration) Websites = result;
        }
        catch (Exception e) { Fail(e.Message); }
        finally { Busy = null; Notify(); }
    }

    public async void SetLaunchAtLogin(bool enabled)
    {
        if (PreviewOnly || Busy is not null) return;
        Busy = "保存启动设置";
        Message = null;
        Notify();
        try
        {
            await Task.Run(() => LoginTask.Set(enabled));
            Message = enabled ? "已设置登录 Windows 后启动轻舟。" : "已关闭登录后启动。";
        }
        catch (Exception e) { Fail(e.Message); }
        finally
        {
            try { LaunchAtLogin = await Task.Run(LoginTask.Enabled); } catch { }
            Busy = null;
            Notify();
        }
    }

    async Task RestoreRiskKey()
    {
        try
        {
            if (RiskKeyVault.Load() is { Length: > 0 } saved)
            {
                await Core.Request("native:risk-key", new JsonObject { ["apiKey"] = saved });
                RiskKeyConfigured = true;
                Notify();
            }
        }
        catch { }
    }

    /// Returns an error message, or null when saved.
    public async Task<string?> SaveRiskKey(string value)
    {
        var key = value.Trim();
        if (key.Length == 0 || key.Length > 512 || RiskBatchRunning) return "请输入有效的 ipdata 密钥，检测期间不能修改。";
        try
        {
            RiskKeyVault.Save(key);
            await Core.Request("native:risk-key", new JsonObject { ["apiKey"] = key });
            var routed = Settings.At("vpnDomainRules").Strings().Any(rule =>
                rule.Trim().ToLowerInvariant() is "domain-suffix,ipdata.co" or "domain,api.ipdata.co" or "domain-suffix,api.ipdata.co");
            if (!routed)
            {
                await Core.Request("routing:add-rule", new JsonObject { ["rule"] = "DOMAIN-SUFFIX,ipdata.co" });
                await Refresh();
            }
            RiskKeyConfigured = true;
            Message = "风险密钥已加密保存在本机。";
            Notify();
            return null;
        }
        catch (Exception e) { return e.Message; }
    }

    public async Task<string?> ClearRiskKey()
    {
        if (RiskBatchRunning) return "检测期间不能修改密钥。";
        try
        {
            RiskKeyVault.Remove();
            await Core.Request("native:risk-key", new JsonObject { ["apiKey"] = "" });
            RiskKeyConfigured = false;
            Message = "已移除风险密钥。";
            Notify();
            return null;
        }
        catch (Exception e) { return e.Message; }
    }
}
