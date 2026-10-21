using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using System.Windows.Threading;
using Qingzhou;

PumpContext.Run(Run);

static async Task Run()
{
    var tests = new (string, Func<Task>)[]
    {
        ("窗口、息屏、休眠和省电刷新策略", Policy),
        ("过滤 TUN 和自分配地址，保留虚拟机出口", NetworkFilter),
        ("物理地址、网关和网卡变化识别", NetworkIdentity),
        ("默认路由变化识别，忽略重复通知和 TUN 路由", RouteIdentity),
        ("未连接时不轮询，省电时降低刷新频率", Polling),
        ("最小化与息屏停止刷新，恢复显示立即补读", Visibility),
        ("慢流量请求不重叠、不排队", SingleFlight),
        ("通知突发合并并保留最新网络状态", NetworkBurst),
        ("手动断开后，网络和唤醒通知不直接发起连接", ManualStop),
        ("自动恢复失败时仍接收新网络通知", FailedRecovery),
        ("休眠、省电状态传递和通知失效回退", Power),
        ("切网后丢弃上一网络的检测和流量结果", StaleResults),
        ("退出时停止通知与轮询，迟到结果不再更新界面", Shutdown),
        ("恢复中和失败时不显示已连接", RecoveryLabels),
        ("内核退出时关闭轮询并显示服务结束", CoreExit),
        ("首次读取失败后按可见性重试", BootstrapRetry),
        ("收进托盘保持连接并停止刷新，打开后补读", TrayVisibility),
        ("关闭按钮只隐藏窗口，不退出或断开连接", TrayClose),
        ("从托盘打开保留最大化状态和同一个窗口", TrayMaximized),
        ("托盘退出只执行一次并允许窗口真正关闭", TrayExit),
        ("系统注销允许退出，迟到的打开命令不显示窗口", TraySessionEnding),
        ("反复收起与打开不重复调用退出", TrayRepeated),
        ("托盘区分未读、关闭、连接、恢复和异常", TrayStates),
        ("连接与断开中的角标保留已经确认的蓝帆", TrayOperations),
        ("状态读取失败清除已连接颜色，重新确认后恢复", TrayReadFailure),
        ("迟到的读取失败不覆盖新确认的状态", TrayLateReadFailure),
        ("业务操作失败不清除已确认的连接颜色", TrayBusinessFailure),
    };
    foreach (var (name, test) in tests)
    {
        await test();
        Console.WriteLine($"PASS {name}");
    }
    Console.WriteLine($"{tests.Length} runtime behavior tests passed (fake OS/core; no VPN or system changes).");
}

static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

static Task Policy()
{
    var a = new DesktopActivity();
    Check(a.PollInterval(true, true) == TimeSpan.FromSeconds(2), "visible interval");
    Check((a with { LowPower = true }).PollInterval(true, true) == TimeSpan.FromSeconds(5), "low power interval");
    Check(a.PollInterval(true, false) is null, "stopped must not poll");
    Check((a with { Visible = false }).PollInterval(true, true) is null, "hidden must not poll traffic");
    Check((a with { Sleeping = true }).PollInterval(false, true) is null, "sleep must stop every poll");
    Check((a with { Visible = false }).PollInterval(false, false) == TimeSpan.FromSeconds(30), "unknown hidden retry");
    return Task.CompletedTask;
}

static NetworkAdapterSnapshot Adapter(int index = 1, string name = "Ethernet", string address = "192.0.2.2", string gateway = "192.0.2.1", bool up = true)
    => new(index, $"nic-{index}", name, name, up, false, [address], [gateway]);

static Task NetworkFilter()
{
    var physical = Adapter();
    var tun = Adapter(9, "Meta", "198.18.0.1", "198.18.0.2");
    var original = PhysicalNetworkSnapshot.Capture([physical]);
    var withTun = PhysicalNetworkSnapshot.Capture([tun, physical]);
    Check(original.Signature == withTun.Signature && !withTun.Indices.Contains(9), "TUN caused path change");
    Check(!PhysicalNetworkSnapshot.Capture([tun]).Available, "TUN counted as online");
    Check(!PhysicalNetworkSnapshot.Capture([Adapter(name: "Wintun", address: "10.0.0.8", gateway: "10.0.0.1")]).Available, "VPN adapter counted as online");
    Check(!PhysicalNetworkSnapshot.Capture([Adapter(address: "169.254.1.2")]).Available, "APIPA counted as online");
    Check(!PhysicalNetworkSnapshot.Capture([Adapter(up: false)]).Available, "down adapter counted as online");
    Check(PhysicalNetworkSnapshot.Capture([Adapter(name: "vEthernet")]).Available, "VM default path excluded");
    return Task.CompletedTask;
}

static Task NetworkIdentity()
{
    var a = Adapter();
    var b = Adapter(2, "Wi-Fi", "192.0.2.3");
    string Signature(params NetworkAdapterSnapshot[] values) => PhysicalNetworkSnapshot.Capture(values).Signature;
    Check(Signature(a, b) == Signature(b, a), "enumeration order changed identity");
    Check(Signature(a) != Signature(a with { Addresses = ["192.0.2.4"] }), "DHCP address change missed");
    Check(Signature(a) != Signature(a with { Gateways = ["192.0.2.5"] }), "gateway change missed");
    Check(Signature(a) != Signature(b), "adapter change missed");
    return Task.CompletedTask;
}

static Task RouteIdentity()
{
    var nic = Adapter();
    var route = new DefaultRouteSnapshot(1, "192.0.2.1", 25);
    string Signature(params DefaultRouteSnapshot[] routes) => PhysicalNetworkSnapshot.Capture([nic], routes).Signature;
    Check(Signature(route) == Signature(route, route), "duplicate physical route changed identity");
    Check(Signature(route) == Signature(route, new(9, "198.18.0.1", 0)), "TUN route changed identity");
    Check(Signature(route) != Signature(route with { Metric = 50 }), "default route metric change missed");
    Check(Signature(route) != Signature(route with { NextHop = "192.0.2.8" }), "next hop change missed");
    Check(Signature(route) != Signature(), "default route removal missed");
    Check(!PhysicalNetworkSnapshot.Capture([nic], []).Available, "missing default route counted as online");
    Check(PhysicalNetworkSnapshot.Capture([nic with { Gateways = [] }], [new(1, "0.0.0.0", 25)]).Available,
        "on-link default route excluded");
    return Task.CompletedTask;
}

static async Task<Fixture> Start(bool running = true, bool nativeEvents = true)
{
    var f = new Fixture(running, nativeEvents);
    await f.Store.Start(f.Monitor);
    return f;
}

static async Task Polling()
{
    using var f = await Start(false);
    Check(!f.Timer.IsEnabled, "idle timer enabled");
    f.Core.Status("running", "ready");
    Check(f.Timer.IsEnabled && f.Timer.Interval.TotalSeconds == 2, "running poll absent");
    f.Monitor.Power(new(LowPower: true));
    Check(f.Timer.Interval.TotalSeconds == 5, "low power not applied");
    f.Core.Status("stopped", "idle");
    Check(!f.Timer.IsEnabled, "stop left timer enabled");
}

static async Task Visibility()
{
    using var f = await Start();
    f.Monitor.Power(new(Visible: false));
    Check(!f.Timer.IsEnabled, "hidden timer still running");
    var count = f.Core.Count("traffic:get-monitor");
    f.Timer.Fire();
    Check(f.Core.Count("traffic:get-monitor") == count, "hidden traffic request");
    f.Monitor.Power(new());
    Check(f.Core.Count("traffic:get-monitor") == count + 1 && f.Timer.IsEnabled, "visibility did not refresh");
    f.Monitor.Power(new(Sleeping: true));
    Check(!f.Timer.IsEnabled, "sleep timer still running");
}

static async Task SingleFlight()
{
    using var f = await Start();
    var hold = f.Core.Hold("traffic:get-monitor");
    f.Timer.Fire();
    f.Timer.Fire();
    f.Monitor.Power(new(Visible: false));
    f.Monitor.Power(new());
    Check(f.Core.Count("traffic:get-monitor") == 1 && !f.Timer.IsEnabled, "overlapping traffic reads");
    hold.SetResult(new JsonObject());
    await Task.Yield();
    Check(f.Timer.IsEnabled, "poll did not resume after reply");
}

static async Task NetworkBurst()
{
    using var f = await Start();
    var hold = f.Core.Hold("native:network-changed");
    f.Monitor.Network(false);
    for (var i = 0; i < 30; i++) f.Monitor.Network(i == 29);
    Check(f.Core.Count("native:network-changed") == 1, "notification burst queued multiple requests");
    f.Core.Handlers.Remove("native:network-changed");
    hold.SetResult(new JsonObject());
    await Task.Yield();
    Check(f.Core.Count("native:network-changed") == 2, "latest notification not sent");
    Check(f.Core.Calls.Last(c => c.Channel == "native:network-changed").Payload.At("available").Bool() == true, "lost newest availability");
}

static async Task ManualStop()
{
    using var f = await Start();
    f.Core.Handlers["vpn:stop"] = _ => { f.Core.Status("stopped", "idle"); return Task.FromResult<JsonNode?>(new JsonObject()); };
    f.Store.ConnectOrDisconnect();
    Check(f.Core.Count("vpn:stop") == 1, "disconnect not sent");
    f.Monitor.Network(false);
    f.Monitor.Network(true);
    f.Monitor.Power(new(Sleeping: true));
    f.Monitor.Power(new());
    Check(f.Core.Count("vpn:start") == 0, "late OS event directly restarted VPN");
    Check(f.Core.Count("native:startup-connect") == 1, "startup repeated");
    Check(!f.Store.Connected, "manual stop still connected");
}

static async Task FailedRecovery()
{
    using var f = await Start(false);
    f.Core.Status("stopped", "failed");
    f.Monitor.Network(true);
    Check(f.Core.Count("native:network-changed") == 1, "failed recovery ignored network change");
    f.Store.RetryRecovery();
    Check(f.Core.Count("vpn:retry-recovery") == 1 && f.Core.Count("native:network-changed") == 1, "retry did not use the explicit recovery channel");
    f.Store.ConnectOrDisconnect();
    Check(f.Core.Count("vpn:stop") == 1 && f.Core.Count("vpn:start") == 0, "disconnect while recovering sent start");
}

static async Task Power()
{
    using var f = await Start(nativeEvents: false);
    Check(f.Core.Calls.First(c => c.Channel == "native:runtime-environment").Payload.At("networkEvents").Bool() == false, "disabled watchdog fallback");
    var hold = f.Core.Hold("native:runtime-environment");
    f.Monitor.Power(new(LowPower: true, Sleeping: true));
    f.Monitor.Power(new(LowPower: true));
    f.Core.Handlers.Remove("native:runtime-environment");
    hold.SetResult(JsonValue.Create(true));
    await Task.Yield();
    var last = f.Core.Calls.Last(c => c.Channel == "native:runtime-environment").Payload;
    Check(last.At("sleeping").Bool() == false && last.At("lowPower").Bool() == true, "wake or battery saver state lost");
}

static async Task StaleResults()
{
    using var f = await Start();
    var check = f.Core.Hold("connectivity:check");
    f.Store.CheckConnectivity();
    f.Monitor.Network(true);
    check.SetResult(new JsonObject { ["oldNetwork"] = true });
    await Task.Yield();
    Check(f.Store.Connectivity is null, "stale connectivity displayed");
    var sites = f.Core.Hold("connectivity:test-website-speeds");
    f.Store.TestWebsites();
    f.Monitor.Network(false);
    sites.SetResult(new JsonObject { ["oldNetwork"] = true });
    await Task.Yield();
    Check(f.Store.Websites is null, "stale website test displayed");
    var traffic = f.Core.Hold("traffic:get-monitor");
    f.Timer.Fire();
    f.Monitor.Network(true);
    traffic.SetResult(new JsonObject { ["oldNetwork"] = true });
    await Task.Yield();
    Check(f.Store.Traffic is null, "stale traffic displayed");
}

static async Task Shutdown()
{
    using var f = await Start();
    var hold = f.Core.Hold("traffic:get-monitor");
    f.Timer.Fire();
    f.Store.Stop();
    var count = f.Core.Calls.Count;
    var updates = 0;
    f.Store.Changed += _ => updates++;
    f.Monitor.Network(true);
    f.Monitor.Power(new());
    f.Core.Status("running", "ready");
    hold.SetResult(new JsonObject());
    await Task.Yield();
    Check(!f.Timer.IsEnabled && f.Monitor.Disposed, "shutdown did not stop OS monitor");
    Check(updates == 0 && f.Core.Calls.Count == count, "late result or OS event updated stopped app");
}

static async Task RecoveryLabels()
{
    using var f = await Start();
    Check(f.Store.Connected, "healthy core not connected");
    foreach (var state in new[] { "waiting-network", "recovering", "failed", "helper-update-required" })
    {
        f.Core.Status("running", state);
        Check(!f.Store.Connected && f.Store.ConnectionLabel != "已连接" && f.Store.RecoveryMessage.Length > 0, $"misleading UI for {state}");
    }
}

static async Task CoreExit()
{
    using var f = await Start();
    f.Core.Emit("core:disconnected", JsonValue.Create("test exit"));
    Check(!f.Timer.IsEnabled && !f.Store.CanMutate && !f.Store.Connected, "core exit left live status");
    Check(f.Store.ConnectionLabel == "服务已结束", "core exit label");
}

static async Task BootstrapRetry()
{
    using var f = new Fixture(false, true);
    f.Core.Handlers["native:bootstrap"] = _ => Task.FromException<JsonNode?>(new Exception("test temporary failure"));
    await f.Store.Start(f.Monitor);
    Check(f.Timer.IsEnabled && f.Timer.Interval.TotalSeconds == 5, "failed bootstrap not retried");
    f.Monitor.Power(new(Visible: false));
    Check(f.Timer.Interval.TotalSeconds == 30, "hidden bootstrap retry too frequent");
    f.Monitor.Power(new(Sleeping: true));
    Check(!f.Timer.IsEnabled, "bootstrap retried during sleep");
    f.Core.Handlers.Remove("native:bootstrap");
    f.Monitor.Power(new());
    Check(f.Store.Status is not null && f.Core.Count("native:startup-connect") == 1, "bootstrap retry lost startup intent");
}

static async Task TrayVisibility()
{
    using var f = await Start();
    var exits = 0;
    var window = new FakeWindow(v => f.Monitor.Power(new(Visible: v)));
    var lifetime = new WindowLifetime(window, () => exits++);
    window.State = DesktopWindowState.Minimized;
    lifetime.StateChanged();
    Check(!window.IsVisible && !f.Timer.IsEnabled, "tray hide left window or polling visible");
    Check(f.Store.Connected && exits == 0 && f.Core.Count("vpn:stop") == 0, "minimize disconnected VPN");
    var reads = f.Core.Count("traffic:get-monitor");
    lifetime.Restore();
    await Task.Yield();
    Check(window.IsVisible && window.State == DesktopWindowState.Normal && window.Activations == 1,
        "tray open did not show and activate the window");
    Check(f.Timer.IsEnabled && f.Core.Count("traffic:get-monitor") == reads + 1, "tray restore did not resume polling");
}

static Task TrayClose()
{
    var window = new FakeWindow();
    var exits = 0;
    var lifetime = new WindowLifetime(window, () => exits++);
    Check(!lifetime.CanClose() && !window.IsVisible && exits == 0, "close button terminated the app");
    lifetime.Restore();
    Check(window.IsVisible && !lifetime.Exiting, "closed window could not be reopened");
    return Task.CompletedTask;
}

static Task TrayMaximized()
{
    var window = new FakeWindow { State = DesktopWindowState.Maximized };
    var lifetime = new WindowLifetime(window, () => throw new Exception("Unexpected shutdown"));
    window.State = DesktopWindowState.Minimized;
    lifetime.StateChanged();
    lifetime.Restore();
    Check(window.IsVisible && window.State == DesktopWindowState.Maximized, "restore lost maximized state");
    lifetime.CanClose();
    lifetime.Restore();
    Check(window.State == DesktopWindowState.Maximized, "close-to-tray lost maximized state");
    return Task.CompletedTask;
}

static Task TrayExit()
{
    var window = new FakeWindow();
    var exits = 0;
    WindowLifetime? lifetime = null;
    lifetime = new(window, () => { Check(lifetime!.CanClose(), "exit was intercepted as tray hide"); exits++; });
    lifetime.CanClose();
    lifetime.Exit();
    lifetime.Exit();
    lifetime.Restore();
    Check(exits == 1 && lifetime.Exiting && !window.IsVisible, "exit repeated or late open revived the app");
    return Task.CompletedTask;
}

static Task TraySessionEnding()
{
    var window = new FakeWindow();
    var exits = 0;
    var lifetime = new WindowLifetime(window, () => exits++);
    lifetime.CanClose();
    lifetime.AllowSystemShutdown();
    Check(lifetime.CanClose(), "tray policy blocked Windows logoff");
    lifetime.Restore();
    lifetime.StateChanged();
    lifetime.Exit();
    Check(exits == 0 && !window.IsVisible, "late callback interfered with system shutdown");
    return Task.CompletedTask;
}

static Task TrayRepeated()
{
    var window = new FakeWindow();
    var exits = 0;
    var lifetime = new WindowLifetime(window, () => exits++);
    for (var i = 0; i < 1000; i++)
    {
        window.State = DesktopWindowState.Minimized;
        lifetime.StateChanged();
        Check(!window.IsVisible, "minimized window remained visible");
        lifetime.Restore();
    }
    Check(exits == 0 && window.Activations == 1000 && window.IsVisible, "repeated tray cycles changed lifetime");
    return Task.CompletedTask;
}

static async Task TrayStates()
{
    using (var unread = new Fixture(false, true))
        Check(unread.Store.TrayState == VPNTrayState.Loading && !unread.Store.PersonalTrayConnected, "unread state coloured sails");
    using var f = await Start(false);
    Check(f.Store.TrayState == VPNTrayState.Disconnected && !f.Store.PersonalTrayConnected, "stopped state");
    foreach (var (runtime, recovery, state, connected) in new[]
    {
        ("running", "ready", VPNTrayState.Connected, true),
        ("running", "idle", VPNTrayState.Connected, true),
        ("running", "waiting-network", VPNTrayState.Connecting, false),
        ("running", "recovering", VPNTrayState.Connecting, false),
        ("running", "failed", VPNTrayState.Error, false),
        ("running", "helper-update-required", VPNTrayState.Error, false),
        ("error", "idle", VPNTrayState.Error, false),
    })
    {
        f.Core.Status(runtime, recovery);
        Check(f.Store.TrayState == state && f.Store.PersonalTrayConnected == connected, $"tray mismatch: {runtime}/{recovery}");
    }
    f.Core.Emit("core:disconnected", JsonValue.Create("fixture closed"));
    Check(f.Store.TrayState == VPNTrayState.Unknown && !f.Store.PersonalTrayConnected, "closed core retained blue sails");
}

static async Task TrayOperations()
{
    using var f = await Start(false);
    var start = f.Core.Hold("vpn:start");
    f.Store.Act("连接 VPN", "vpn:start");
    Check(f.Store.TrayState == VPNTrayState.Connecting && !f.Store.PersonalTrayConnected, "start not pending");
    f.Core.Status("running", "ready");
    Check(f.Store.TrayState == VPNTrayState.Connecting && f.Store.PersonalTrayConnected, "confirmed connection lost during operation");
    start.SetResult(new JsonObject());
    await Until(() => f.Store.Busy is null);
    var stop = f.Core.Hold("vpn:stop");
    f.Store.Act("断开 VPN", "vpn:stop");
    Check(f.Store.TrayState == VPNTrayState.Disconnecting && f.Store.PersonalTrayConnected, "disconnect removed confirmed blue too early");
    f.Core.Status("stopped", "idle");
    stop.SetResult(new JsonObject());
    await Until(() => f.Store.Busy is null);
    Check(f.Store.TrayState == VPNTrayState.Disconnected && !f.Store.PersonalTrayConnected, "disconnect retained blue");
}

static async Task TrayReadFailure()
{
    using var f = await Start();
    var invalidated = false;
    f.Store.OnCompanyRouting = state => invalidated = state is null;
    f.Core.Handlers["traffic:get-monitor"] = _ => Task.FromException<JsonNode?>(new CoreException("fixture read failure"));
    f.Timer.Fire();
    await Until(() => !f.Store.StatusKnown);
    Check(f.Store.TrayState == VPNTrayState.Unknown && !f.Store.PersonalTrayConnected && !f.Store.CanMutate && invalidated,
        "unconfirmed state retained connection colours");
    Check(f.Timer.Interval.TotalSeconds == 5, "unknown state did not retry confirmation");
    f.Core.Handlers.Remove("traffic:get-monitor");
    f.Timer.Fire();
    await Until(() => f.Store.StatusKnown);
    Check(f.Store.PersonalTrayConnected && f.Core.Count("vpn:start") == 0, "reconfirmation did not restore colour safely");
}

static async Task TrayLateReadFailure()
{
    using var f = await Start();
    var old = f.Core.Hold("traffic:get-monitor");
    f.Timer.Fire();
    await f.Store.Refresh();
    old.SetException(new CoreException("fixture stale read"));
    await Task.Delay(20);
    Check(f.Store.StatusKnown && f.Store.PersonalTrayConnected, "late failure invalidated fresh confirmation");
}

static async Task TrayBusinessFailure()
{
    using var f = await Start();
    f.Core.Handlers["subscription:update"] = _ => Task.FromException<JsonNode?>(new CoreException("fixture subscription failure"));
    f.Store.Act("更新订阅", "subscription:update");
    await Until(() => f.Store.Busy is null);
    Check(f.Store.StatusKnown && f.Store.PersonalTrayConnected && f.Store.TrayState == VPNTrayState.Connected,
        "business failure replaced connection status");
}

static async Task Until(Func<bool> done)
{
    for (var i = 0; i < 1000; i++)
    {
        if (done()) return;
        await Task.Delay(5);
    }
    throw new Exception("Fake state transition timed out");
}

sealed class FakeWindow(Action<bool>? visibility = null) : IDesktopWindow
{
    public DesktopWindowState State { get; set; }
    public bool IsVisible { get; private set; } = true;
    public int Activations { get; private set; }
    public void Show() { IsVisible = true; visibility?.Invoke(true); }
    public void Hide() { IsVisible = false; visibility?.Invoke(false); }
    public void Activate() => Activations++;
}

sealed class Fixture(bool running, bool nativeEvents) : IDisposable
{
    public FakeCore Core { get; } = new(running);
    public FakeMonitor Monitor { get; } = new(nativeEvents);
    Store? store;
    public Store Store => store ??= new(Core);
    public DispatcherTimer Timer => DispatcherTimer.Instances.Last();
    public void Dispose() => Store.Stop();
}

sealed class FakeMonitor(bool nativeEvents) : IRuntimeMonitor
{
    public bool NetworkEventsAvailable => nativeEvents;
    public bool Disposed { get; private set; }
    public event Action<bool?>? NetworkChanged;
    public event Action<DesktopActivity>? ActivityChanged;
    public void Start() => Power(new());
    public void Power(DesktopActivity activity) => ActivityChanged?.Invoke(activity);
    public void Network(bool? available) => NetworkChanged?.Invoke(available);
    public void Dispose() => Disposed = true;
}

sealed class FakeCore(bool running) : ICoreClient
{
    public List<(string Channel, JsonObject? Payload)> Calls { get; } = [];
    public Dictionary<string, Func<JsonObject?, Task<JsonNode?>>> Handlers { get; } = [];
    public event Action<string, JsonNode?>? Event;
    string state = running ? "running" : "stopped", recovery = running ? "ready" : "idle";
    JsonObject Runtime() => new() { ["state"] = state, ["networkRecovery"] = new JsonObject { ["state"] = recovery } };
    public Task<JsonNode?> Request(string channel, JsonObject? payload = null)
    {
        Calls.Add((channel, payload?.DeepClone() as JsonObject));
        if (Handlers.TryGetValue(channel, out var handler)) return handler(payload);
        JsonNode result = channel switch
        {
            "native:bootstrap" => new JsonObject
            {
                ["status"] = new JsonObject { ["mihomo"] = Runtime(), ["settings"] = new JsonObject { ["selectedProxy"] = "DIRECT" } },
                ["previewOnly"] = false, ["ownsRuntime"] = true,
            },
            "native:startup-connect" => new JsonObject { ["mihomo"] = Runtime(), ["startupOutcome"] = "not-requested" },
            _ => new JsonObject(),
        };
        return Task.FromResult<JsonNode?>(result);
    }
    public int Count(string channel) => Calls.Count(c => c.Channel == channel);
    public TaskCompletionSource<JsonNode?> Hold(string channel)
    {
        var hold = new TaskCompletionSource<JsonNode?>(TaskCreationOptions.RunContinuationsAsynchronously);
        Handlers[channel] = _ => hold.Task;
        return hold;
    }
    public void Status(string nextState, string nextRecovery)
    { state = nextState; recovery = nextRecovery; Emit("vpn:status", Runtime()); }
    public void Emit(string name, JsonNode? data) => Event?.Invoke(name, data);
    public void Shutdown() { }
}

sealed class PumpContext : SynchronizationContext
{
    readonly BlockingCollection<(SendOrPostCallback Callback, object? State)> queue = new();
    public override void Post(SendOrPostCallback callback, object? state) => queue.Add((callback, state));
    public static void Run(Func<Task> action)
    {
        var previous = Current;
        var context = new PumpContext();
        SetSynchronizationContext(context);
        try
        {
            var task = action();
            while (!task.IsCompleted)
            {
                if (!context.queue.TryTake(out var item, TimeSpan.FromSeconds(10))) throw new TimeoutException("Test stalled.");
                item.Callback(item.State);
            }
            task.GetAwaiter().GetResult();
        }
        finally { SetSynchronizationContext(previous); }
    }
}
