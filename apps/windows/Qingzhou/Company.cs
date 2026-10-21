using System.Diagnostics;
using System.Globalization;
using System.Net.NetworkInformation;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Threading;

namespace Qingzhou;

public enum Phase { Pending, Running, Passed, Failed }

public enum CertState { Pending, SystemTrusted, Remembered, RequiresConfirmation, Changed, Invalid }

public static class CompanyText
{
    public static string Title(this Phase phase) => phase switch
    {
        Phase.Running => "进行中",
        Phase.Passed => "通过",
        Phase.Failed => "失败",
        _ => "待验证",
    };

    public static bool Approved(this CertState state) => state is CertState.SystemTrusted or CertState.Remembered;
    public static bool NeedsConfirmation(this CertState state) => state is CertState.RequiresConfirmation or CertState.Changed;

    public static string Title(this CertState state) => state switch
    {
        CertState.SystemTrusted => "证书已自动核验 · 系统信任",
        CertState.Remembered => "证书已自动核验 · 与已确认网关一致",
        CertState.RequiresConfirmation => "首次遇到此证书 · 需要确认一次",
        CertState.Changed => "网关证书已变化 · 需要重新确认",
        CertState.Invalid => "证书信息无效或已过期",
        _ => "正在自动核验证书",
    };
}

/// Company preferences and public SHA-256 gateway pins; mirrors the macOS UserDefaults keys.
static class CompanyPrefs
{
    static string FilePath => Path.Combine(Paths.Dir, "company.json");

    public static JsonObject Load()
    {
        try { return JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject ?? []; }
        catch { return []; }
    }

    public static void Update(Action<JsonObject> change)
    {
        var all = Load();
        change(all);
        File.WriteAllText(FilePath, all.ToJsonString());
    }

    /// Scoped to the HTTPS host and port; null for anything else.
    public static string? GatewayKey(string? origin)
    {
        if (!Uri.TryCreate(origin?.Trim(), UriKind.Absolute, out var url) || url.Scheme != "https" ||
            url.Host.Length == 0 || url.UserInfo.Length > 0) return null;
        return $"https://{url.Host.ToLowerInvariant()}{(url.IsDefaultPort ? "" : ":" + url.Port)}";
    }

    public static string? Fingerprint(string? raw)
    {
        var value = (raw ?? "").Trim().Replace(":", "").ToUpperInvariant();
        return value.Length == 64 && value.All(Uri.IsHexDigit) ? value : null;
    }

    public static string? RememberedFingerprint(string origin) =>
        GatewayKey(origin) is { } key ? Fingerprint(Load().At("pins").At(key).Str()) : null;

    public static bool IsCurrent(JsonNode? probe)
    {
        var now = DateTimeOffset.Now;
        if (GatewayKey(probe.At("origin").Str()) is null || Fingerprint(probe.At("fingerprint").Str()) is null) return false;
        if (Date(probe.At("validTo").Str()) is not { } expiry || expiry <= now) return false;
        if (probe.At("validFrom").Str() is { } raw && (Date(raw) is not { } start || start > now)) return false;
        return true;
    }

    public static CertState Evaluate(JsonNode? probe)
    {
        if (!IsCurrent(probe)) return CertState.Invalid;
        var fingerprint = Fingerprint(probe.At("fingerprint").Str());
        if (RememberedFingerprint(probe.At("origin").Str()!) is { } previous)
            return previous == fingerprint ? CertState.Remembered : CertState.Changed;
        return probe.At("systemTrusted").Bool() == true && probe.At("nameMatches").Bool() == true
            ? CertState.SystemTrusted : CertState.RequiresConfirmation;
    }

    public static void Remember(JsonNode? probe)
    {
        if (!IsCurrent(probe)) throw new InvalidOperationException("证书信息无效或不在有效期内，请重新检测入口。");
        var key = GatewayKey(probe.At("origin").Str())!;
        var fingerprint = Fingerprint(probe.At("fingerprint").Str())!;
        Update(all =>
        {
            if (all["pins"] is not JsonObject pins) all["pins"] = pins = [];
            pins[key] = fingerprint;
        });
    }

    static DateTimeOffset? Date(string? value) =>
        DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date) ? date : null;
}

/// Company account per gateway, encrypted with DPAPI for the current Windows user.
static class CompanyVault
{
    static string FilePath => Path.Combine(Paths.Dir, "company-credentials.bin");

    static JsonObject Read() => File.Exists(FilePath)
        ? JsonNode.Parse(Encoding.UTF8.GetString(RiskKeyVault.Transform(File.ReadAllBytes(FilePath), protect: false))) as JsonObject ?? []
        : [];

    static void Write(JsonObject all)
    {
        if (all.Count == 0) { File.Delete(FilePath); return; }
        File.WriteAllBytes(FilePath, RiskKeyVault.Transform(Encoding.UTF8.GetBytes(all.ToJsonString()), protect: true));
    }

    public static JsonNode? Load(string key) => Read().At(key)?.DeepClone();

    public static void Save(string key, JsonObject credentials)
    {
        var all = Read();
        all[key] = credentials.DeepClone();
        Write(all);
    }

    public static void Remove(string key)
    {
        var all = Read();
        if (all.Remove(key)) Write(all);
    }
}

interface ICompanyCredentialVault
{
    JsonNode? Load(string key);
    void Save(string key, JsonObject credentials);
    void Remove(string key);
}

sealed class CompanyCredentialVault : ICompanyCredentialVault
{
    public JsonNode? Load(string key) => CompanyVault.Load(key);
    public void Save(string key, JsonObject credentials) => CompanyVault.Save(key, credentials);
    public void Remove(string key) => CompanyVault.Remove(key);
}

interface ICompanyHelper
{
    int? ProcessId { get; }
    void Start(JsonObject command, Action<JsonNode> onEvent, Action<int> onExit);
    void Send(JsonObject command);
    void Stop();
}

/// Credentials go to the helper over its stdin pipe only: never arguments or environment.
sealed class CompanyHelper : ICompanyHelper
{
    Process? process;
    StreamWriter? input;

    public int? ProcessId
    {
        get
        {
            try { return process is { HasExited: false } p ? p.Id : null; }
            catch { return null; }
        }
    }

    /// Callbacks arrive on a background thread, events strictly before the exit.
    public void Start(JsonObject command, Action<JsonNode> onEvent, Action<int> onExit)
    {
        Stop();
        var path = Path.Combine(AppContext.BaseDirectory, "company-account-helper.exe");
        if (!File.Exists(path)) throw new InvalidOperationException("应用中缺少私有网络认证内核，请重新构建 Windows 包。");
        var info = new ProcessStartInfo(path)
        {
            WorkingDirectory = AppContext.BaseDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
        };
        // Do not inherit an unrelated certificate pin from a terminal session.
        info.Environment.Remove("SPLITVPN_ATRUST_CERT_SHA256");
        var child = Process.Start(info) ?? throw new InvalidOperationException("无法启动私有网络认证内核。");
        process = child;
        input = child.StandardInput;
        new Thread(() =>
        {
            try
            {
                string? line;
                while ((line = child.StandardOutput.ReadLine()) is not null)
                {
                    JsonNode? message = null;
                    try { message = JsonNode.Parse(line); } catch { }
                    onEvent(message.At("type").Str() is not null ? message! : new JsonObject
                    {
                        ["type"] = "error", ["stage"] = "local", ["message"] = "认证内核返回了无法识别的消息。",
                    });
                }
            }
            catch { }
            var status = -1;
            try { child.WaitForExit(); status = child.ExitCode; } catch { }
            onExit(status);
        }) { IsBackground = true, Name = "company-helper" }.Start();
        try { Send(command); }
        catch { Stop(); throw; }
    }

    public void Send(JsonObject command)
    {
        if (input is null || ProcessId is null) throw new InvalidOperationException("测试会话已结束，请重新登录。");
        input.Write(command.ToJsonString());
        input.Write('\n');
        input.Flush();
    }

    /// Closing stdin ends the helper; kill it if it is still running.
    public void Stop()
    {
        try { input?.Close(); } catch { }
        input = null;
        try { if (process is { HasExited: false } p) p.Kill(); } catch { }
        process = null;
    }
}

/// Company login, tunnel and routing state; mirrors CompanyStore on macOS.
public sealed class CompanyStore
{
    static readonly string[] Steps = ["probe", "login", "resources", "tunnel", "business", "routing"];
    readonly Store vpn;
    readonly ICompanyHelper helper;
    readonly ICompanyCredentialVault credentialVault;
    readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    Guid? currentRun;
    bool started;
    JsonObject? draft;
    string? pendingPasswordChangeID;
    string? pendingPasswordChangeUsername;
    JsonObject? pendingPasswordChangeCredentials;
    bool passwordChangedDuringLogin;
    bool requiresNewPassword;
    string origin = "";

    public bool BusinessVerified { get; private set; }
    public JsonNode? TunnelProof { get; private set; }
    public JsonNode? Routing { get; private set; }
    public bool RoutingKnown { get; private set; } = true;
    public string Target { get; set; } = "";
    public bool TakeoverEnabled { get; private set; }
    public bool RememberCredentials { get; private set; }
    public bool HasSavedCredentials { get; private set; }
    public string? CredentialMessage { get; private set; }
    public string Username { get; set; } = "";
    public string Password { get; set; } = "";
    public string SelectedDomain { get; set; } = "local";
    public CertState Certificate { get; private set; } = CertState.Pending;
    public JsonNode? Probe { get; private set; }
    public JsonNode? Resources { get; private set; }
    public Dictionary<string, Phase> Phases { get; } = Steps.ToDictionary(s => s, _ => Phase.Pending);
    public List<(DateTime Time, string Message)> Timeline { get; } = [];
    public string? ErrorMessage { get; private set; }
    public string? ErrorStage { get; private set; }
    public bool PasswordChangeRequired { get; private set; }
    public const string PasswordChangeGuidance = "接入网关要求先修改密码。请更新轻舟，或在官方 aTrust 完成修改并断开私有网络连接，再回轻舟输入新密码登录。";
    public string? AuthenticatedUsername { get; private set; }
    public bool Working { get; private set; }
    public bool HasSession { get; private set; }
    public JsonNode? Challenge { get; private set; }
    public event Action<JsonNode>? ChallengeRequested;

    public bool RoutingActive => Routing.At("active").Bool() == true;
    public bool RoutingRecovering => Routing.At("recovering").Bool() == true;
    public bool ConnectionEnabled => TunnelProof is not null || RoutingActive || RoutingRecovering;
    public bool ConnectionReady => TakeoverEnabled ? RoutingActive : TunnelProof is not null;
    public bool TrayConnected => (!TakeoverEnabled || RoutingKnown) && (TunnelProof is not null || RoutingActive);
    public string StatusText =>
        TakeoverEnabled && ConnectionEnabled && !RoutingKnown ? "私有网络分流状态未知" :
        RoutingRecovering ? "私有网络分流恢复中" :
        RoutingActive ? "私有网络已连接" :
        TunnelProof is not null ? (TakeoverEnabled ? "私有网络隧道已连接 · 分流未接入" : "私有网络隧道已连接 · 未接管") :
        Phases["tunnel"] == Phase.Running ? "正在连接私有网络" :
        HasSession ? "已登录 · 未连接" :
        Challenge.At("kind").Str() == "password_change" ? "等待修改接入密码" :
        PasswordChangeRequired ? "需要修改接入密码" :
        Working ? "正在准备私有网络连接" : "私有网络未连接";

    public string Origin
    {
        get => origin;
        set
        {
            if (value == origin) return;
            origin = value;
            StopSession();
            HasSavedCredentials = false; CredentialMessage = null; Username = ""; Password = "";
            Probe = null;
            Certificate = CertState.Pending;
            Phases["probe"] = Phase.Pending;
            ResetAccountResults();
            requiresNewPassword = CompanyPrefs.GatewayKey(origin) is { } key && CompanyPrefs.Load().At("passwordChangePending").At(key).Bool() == true;
            ErrorMessage = null;
            Changed();
        }
    }

    public CompanyStore(Store vpn) : this(vpn, new CompanyHelper(), new CompanyCredentialVault()) { }

    internal CompanyStore(Store vpn, ICompanyHelper helper, ICompanyCredentialVault credentialVault)
    {
        this.vpn = vpn;
        this.helper = helper;
        this.credentialVault = credentialVault;
        var prefs = CompanyPrefs.Load();
        TakeoverEnabled = prefs.At("takeoverEnabled").Bool() ?? true;
        RememberCredentials = prefs.At("rememberCredentials").Bool() ?? true;
        vpn.OnCompanyRouting = UpdateRouting;
    }

    void Changed() => vpn.Notify();

    static void SavePref(string key, bool value)
    {
        try { CompanyPrefs.Update(all => all[key] = value); } catch { }
    }

    public void UpdateRouting(JsonNode? state)
    {
        if (state is not JsonObject) { RoutingKnown = false; Changed(); return; }
        RoutingKnown = true;
        var previous = Routing;
        Routing = state;
        var active = state.At("active").Bool() == true;
        var lastError = state.At("lastError").Str();
        BusinessVerified = HasSession && TakeoverEnabled && state.At("verified").Bool() == true;
        if (BusinessVerified) { Phases["routing"] = Phase.Passed; Phases["business"] = Phase.Passed; }
        else if (state.At("recovering").Bool() == true)
        {
            Phases["routing"] = Phase.Running; Phases["business"] = Phase.Pending;
            if (previous.At("lastError").Str() != lastError && lastError is not null) Append(lastError);
        }
        else if (lastError is not null)
        {
            if (previous.At("lastError").Str() != lastError) Fail(active ? "business" : "routing", lastError);
        }
        else if (active) { Phases["routing"] = Phase.Passed; Phases["business"] = Phase.Pending; }
        else if (TunnelProof is not null) Phases["routing"] = Phase.Pending;
        if (active && lastError is null && ErrorStage is "routing" or "business") { ErrorStage = null; ErrorMessage = null; }
        if ((state.At("recoveryCount").Num() ?? 0) > (previous.At("recoveryCount").Num() ?? 0))
            Append("现有 VPN 配置更新后，私有网络分流已恢复；私有网络隧道与登录会话继续使用。");
        Changed();
    }

    public IEnumerable<JsonNode> PasswordMethods =>
        Probe.At("methods").Items().Where(m => m.At("authType").Str() == "auth/psw");

    public bool ConfirmedCertificate =>
        Probe is not null && Certificate.Approved() && CompanyPrefs.IsCurrent(Probe) &&
        CompanyPrefs.GatewayKey(origin) is { } key && key == CompanyPrefs.GatewayKey(Probe.At("origin").Str());

    public string? PreviousFingerprint => CompanyPrefs.RememberedFingerprint(origin);

    public bool CanLogin =>
        !Working && Probe is not null && ConfirmedCertificate && Username.Trim().Length > 0 && Password.Length > 0 &&
        PasswordMethods.Any(m => m.At("loginDomain").Str() == SelectedDomain);

    public string ErrorHeading => PasswordChangeRequired ? "需要修改接入密码" : ErrorStage switch
    {
        "probe" => "入口检测失败",
        "login" => "账号认证未通过",
        "resources" => "授权资源获取失败",
        "tunnel" => "私有网络隧道连接未完成",
        "business" => "内网访问未通过",
        "routing" => "私有网络分流未完成",
        _ => "连接未完成",
    };

    public void StartOnce()
    {
        if (started) return;
        started = true;
        try
        {
            var config = JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "company-config.json")));
            if (config.At("origin").Str() is { } configured)
            {
                Origin = configured;
                SelectedDomain = config.At("loginDomain").Str() ?? "local";
                Target = config.At("target").Str() ?? Target;
            }
        }
        catch { }
        // Saved accounts are keyed by entry, so the entry must survive a restart.
        if (origin.Trim().Length == 0 && CompanyPrefs.Load().At("origin").Str() is { Length: > 0 } saved)
            Origin = saved;
        if (Target.Length == 0 && CompanyPrefs.Load().At("target").Str() is { } savedTarget)
            Target = savedTarget;
        LoadCredentials();
        if (origin.Trim().Length > 0) DetectEntry();
        Changed();
    }

    void LoadCredentials()
    {
        if (!RememberCredentials || requiresNewPassword || HasSession || Working || CompanyPrefs.GatewayKey(origin) is not { } key) return;
        try
        {
            var saved = credentialVault.Load(key);
            HasSavedCredentials = saved is not null;
            if (saved is null) return;
            Username = saved.At("username").Str() ?? "";
            Password = saved.At("password").Str() ?? "";
            var domain = saved.At("domain").Str() ?? "local";
            if (Probe is null || PasswordMethods.Any(m => m.At("loginDomain").Str() == domain)) SelectedDomain = domain;
            CredentialMessage = "已读取本机保存的接入账号。";
        }
        catch (Exception e) { CredentialMessage = e.Message; }
    }

    public void SetRememberCredentials(bool value)
    {
        RememberCredentials = value;
        SavePref("rememberCredentials", value);
        if (!value) { draft = null; pendingPasswordChangeCredentials = null; ForgetCredentials(clearFields: false); }
        Changed();
    }

    public void ForgetCredentials(bool clearFields = true)
    {
        if (CompanyPrefs.GatewayKey(origin) is not { } key) { HasSavedCredentials = false; Changed(); return; }
        try
        {
            credentialVault.Remove(key);
            HasSavedCredentials = false; CredentialMessage = "已移除保存的接入账号。";
            if (clearFields && !HasSession) { Username = ""; Password = ""; }
        }
        catch (Exception e) { CredentialMessage = e.Message; }
        Changed();
    }

    public async void SetTakeover(bool value)
    {
        if (Working || value == TakeoverEnabled) { Changed(); return; }
        var previous = TakeoverEnabled;
        TakeoverEnabled = value; BusinessVerified = false;
        if (value)
        {
            SavePref("takeoverEnabled", true);
            if (TunnelProof is not null) ConnectTunnel();
        }
        else if (TunnelProof is not null || RoutingActive || RoutingRecovering)
        {
            Working = true;
            Changed();
            try
            {
                var state = await vpn.Core.Request("native:company-remove");
                UpdateRouting(state); Working = false;
                SavePref("takeoverEnabled", false);
                Phases["routing"] = Phase.Pending; Phases["business"] = Phase.Pending;
                Append("已关闭授权资源接管，账号与私有网络隧道继续保留。");
            }
            catch (Exception e) { TakeoverEnabled = previous; Fail("routing", e.Message); }
        }
        else SavePref("takeoverEnabled", false);
        Changed();
    }

    public void DetectEntry()
    {
        StopSession();
        ResetAccountResults();
        Probe = null;
        Certificate = CertState.Pending;
        ErrorMessage = null;
        ErrorStage = null;
        Timeline.Clear();
        Phases["probe"] = Phase.Running;
        Launch(new JsonObject { ["type"] = "probe", ["origin"] = origin.Trim() });
    }

    void AcceptProbe(JsonNode info)
    {
        Probe = info;
        if (CompanyPrefs.GatewayKey(origin) is not { } entry || entry != CompanyPrefs.GatewayKey(info.At("origin").Str()))
        {
            Certificate = CertState.Invalid; Phases["probe"] = Phase.Failed; return;
        }
        Certificate = CompanyPrefs.Evaluate(info);
        if (Certificate == CertState.SystemTrusted) try { CompanyPrefs.Remember(info); } catch { }
        Phases["probe"] = Certificate.Approved() ? Phase.Passed : Certificate == CertState.Invalid ? Phase.Failed : Phase.Pending;
    }

    public void ConfirmGatewayCertificate()
    {
        if (Working || HasSession || !Certificate.NeedsConfirmation() || Probe is null ||
            CompanyPrefs.GatewayKey(origin) != CompanyPrefs.GatewayKey(Probe.At("origin").Str())) return;
        try
        {
            CompanyPrefs.Remember(Probe);
            Certificate = CertState.Remembered; Phases["probe"] = Phase.Passed;
            Append("接入网关证书已记住，后续自动核验，不再重复确认。");
        }
        catch (Exception e)
        {
            Certificate = CertState.Invalid; Phases["probe"] = Phase.Failed;
            ErrorStage = "probe"; ErrorMessage = e.Message;
        }
        Changed();
    }

    public async void Login()
    {
        if (!CanLogin || Probe is not { } probe) return;
        StopSession();
        ResetAccountResults();
        ErrorMessage = null;
        ErrorStage = null;
        Phases["login"] = Phase.Running;
        var probeOrigin = probe.At("origin").Str()!;
        var command = new JsonObject
        {
            ["type"] = "login", ["origin"] = probeOrigin, ["username"] = Username, ["password"] = Password,
            ["domain"] = SelectedDomain, ["fingerprint"] = probe.At("fingerprint").Str(),
        };
        draft = RememberCredentials
            ? new JsonObject { ["origin"] = probeOrigin, ["domain"] = SelectedDomain, ["username"] = Username, ["password"] = Password }
            : null;
        Password = "";
        Working = true;
        var id = Guid.NewGuid();
        currentRun = id;
        Changed();
        try
        {
            var context = await vpn.Core.Request("native:company-context");
            if (currentRun != id) return;
            // Bind the tunnel to the physical NIC, never the mihomo TUN.
            var name = context.At("interfaceName").Str() ?? await Task.Run(() => PhysicalInterface(context.At("address").Str()));
            if (currentRun != id) return;
            if (string.IsNullOrEmpty(name)) { Fail("login", "尚未确认接入网关的底层网络入口，请稍后重试。"); return; }
            command["interfaceName"] = name;
            Launch(command);
        }
        catch (Exception e) { if (currentRun == id) Fail("login", e.Message); }
    }

    /// The Windows friendly name, which Go's net.InterfaceByName also uses.
    static string? PhysicalInterface(string? address) => address is null ? null :
        NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(n => n.OperationalStatus == OperationalStatus.Up &&
            n.GetIPProperties().UnicastAddresses.Any(a => a.Address.ToString() == address))?.Name;

    public void ConnectTunnel()
    {
        if (!HasSession || Resources is null || Working) return;
        ErrorMessage = null; ErrorStage = null;
        if (TunnelProof is not null)
        {
            if (TakeoverEnabled && !RoutingActive) ApplyRouting();
            Changed();
            return;
        }
        Working = true; Phases["tunnel"] = Phase.Running;
        try { helper.Send(new JsonObject { ["type"] = "connect" }); }
        catch (Exception e) { Fail("tunnel", e.Message); }
        Changed();
    }

    async void ApplyRouting()
    {
        if (TunnelProof is not { } proof || Resources is not { } resources || helper.ProcessId is not { } helperPid)
        {
            Fail("routing", "私有网络接入服务未就绪。"); return;
        }
        Working = true; BusinessVerified = false;
        Phases["routing"] = Phase.Running; Phases["business"] = Phase.Pending;
        var run = currentRun;
        Changed();
        try
        {
            var payload = new JsonObject
            {
                ["port"] = proof.At("port").Num(), ["helperPid"] = helperPid, ["rows"] = resources.At("rows")?.DeepClone() ?? new JsonArray(),
            };
            var installed = await vpn.Core.Request("native:company-apply", payload);
            if (currentRun != run || !HasSession) { try { await vpn.Core.Request("native:company-remove"); } catch { } return; }
            UpdateRouting(installed); Working = false;
            Append("私有网络已连接，授权资源已接入私有网络分流。");
        }
        catch (Exception e) { if (currentRun == run) Fail("routing", e.Message); }
        Changed();
    }

    public async void VerifyBusiness()
    {
        if (!HasSession || TunnelProof is null || Working || Target.Trim().Length == 0) return;
        // Remembered locally only; the shipped app carries no default address.
        try { CompanyPrefs.Update(all => all["target"] = Target.Trim()); } catch { }
        BusinessVerified = false;
        Working = true; ErrorMessage = null; ErrorStage = null;
        Phases["business"] = Phase.Running;
        var run = currentRun;
        Changed();
        try
        {
            if (TakeoverEnabled)
            {
                var checkedState = await vpn.Core.Request("native:company-verify", new JsonObject { ["target"] = Target });
                if (currentRun != run || !HasSession) return;
                UpdateRouting(checkedState); Working = false;
                Append("现有私有网络连接验证通过，隧道继续保持。");
            }
            else helper.Send(new JsonObject { ["type"] = "verify", ["target"] = Target });
        }
        catch (Exception e) { if (currentRun == run) Fail("business", e.Message); }
        Changed();
    }

    public async void VerifyInternet()
    {
        if (Working) return;
        Working = true;
        Changed();
        try
        {
            var state = await vpn.Core.Request("native:company-internet-check");
            UpdateRouting(state);
            Append(state.At("internet").At("result").At("ok").Bool() == true
                ? "GPT 网络检测通过。" : "GPT 网络检测未通过，请检查当前外网节点；私有网络连接继续保持。");
        }
        catch (Exception e) { Append($"外网检测未完成：{e.Message}。私有网络连接继续保持。"); }
        finally { Working = false; Changed(); }
    }

    public async void DisconnectTunnel()
    {
        if (!ConnectionEnabled || Working) return;
        Working = true; ErrorMessage = null; ErrorStage = null;
        var run = currentRun;
        Changed();
        try
        {
            var removed = await vpn.Core.Request("native:company-remove");
            if (currentRun != run) return;
            UpdateRouting(removed);
            if (helper.ProcessId is not null) helper.Send(new JsonObject { ["type"] = "disconnect" });
            else TunnelClosed();
        }
        catch (Exception e) { if (currentRun == run) Fail("routing", e.Message); }
        Changed();
    }

    public void RefreshResources()
    {
        if (!HasSession || Working) return;
        ErrorMessage = null;
        ErrorStage = null;
        Working = true;
        Phases["resources"] = Phase.Running;
        try { helper.Send(new JsonObject { ["type"] = "refresh_resources" }); }
        catch (Exception e) { Fail("resources", e.Message); }
        Changed();
    }

    public void AnswerChallenge(JsonObject response, string? challengeId = null)
    {
        if (Challenge is null || challengeId is not null && Challenge.At("id").Str() != challengeId) return;
        if (Challenge.At("kind").Str() == "password_change")
        {
            var oldPassword = response.At("oldPassword").Str();
            var newPassword = response.At("newPassword").Str();
            var account = response.At("newUsername").Str()?.Trim() ?? Username;
            var input = new CompanyPasswordChangeInput(oldPassword ?? "", newPassword ?? "", newPassword ?? "", response.At("newUsername").Str() ?? "");
            if (input.ValidationMessage(Challenge.At("requireUsername").Bool() == true) is not null || string.IsNullOrEmpty(account)) return;
            pendingPasswordChangeID = Challenge.At("id").Str();
            pendingPasswordChangeUsername = account;
            pendingPasswordChangeCredentials = RememberCredentials
                ? new JsonObject { ["origin"] = Probe.At("origin").Str(), ["domain"] = SelectedDomain, ["username"] = account, ["password"] = newPassword }
                : null;
            MarkPasswordChangePending(true);
        }
        response["type"] = "challenge_response";
        response["id"] = Challenge.At("id").Str();
        Challenge = null;
        try { helper.Send(response); Append("验证信息已提交，等待接入服务响应…"); }
        catch (Exception e) { Fail("login", e.Message); }
        Changed();
    }

    void MarkPasswordChangePending(bool pending)
    {
        requiresNewPassword = pending;
        if (CompanyPrefs.GatewayKey(origin) is not { } key) return;
        try
        {
            CompanyPrefs.Update(all =>
            {
                if (all["passwordChangePending"] is not JsonObject entries) all["passwordChangePending"] = entries = [];
                if (pending) entries[key] = true; else entries.Remove(key);
            });
        }
        catch { }
    }

    void SaveCredentials(JsonObject saved, bool changedPassword = false)
    {
        if (!RememberCredentials || CompanyPrefs.GatewayKey(saved.At("origin").Str()) is not { } key) return;
        try
        {
            credentialVault.Save(key, saved);
            if (CompanyPrefs.GatewayKey(origin) == key)
            {
                HasSavedCredentials = true;
                if (changedPassword) MarkPasswordChangePending(false);
                CredentialMessage = changedPassword ? "接入密码已修改，新密码已加密保存在本机。" : "账号与密码已加密保存在本机。";
            }
        }
        catch (Exception error)
        {
            if (changedPassword) { MarkPasswordChangePending(true); HasSavedCredentials = false; }
            CredentialMessage = error.Message;
        }
    }

    public Uri? PasswordChangeEntryUrl
    {
        get
        {
            if (!PasswordChangeRequired || !Uri.TryCreate(Probe.At("origin").Str(), UriKind.Absolute, out var url) ||
                url.Scheme != "https" || url.UserInfo.Length > 0 || url.Query.Length > 0 || url.Fragment.Length > 0 ||
                url.AbsolutePath != "/") return null;
            return url;
        }
    }

    public void PrepareAfterPasswordChange()
    {
        if (Working || !PasswordChangeRequired) return;
        StopSession(); ResetAccountResults(); Password = "";
        ErrorMessage = null; ErrorStage = null;
        CredentialMessage = "请输入修改后的新密码，确认登录成功后再保存。";
        Changed();
    }

    public async void EndTest()
    {
        var wasWorking = Working;
        if (RoutingActive)
        {
            Working = true; BusinessVerified = false;
            Changed();
            try
            {
                await vpn.Core.Request("native:company-remove");
                StopSession();
                Append("私有网络分流已移除，会话已结束。现有外网 VPN 保持运行。");
                LoadCredentials();
            }
            catch (Exception e) { Fail("routing", e.Message); }
        }
        else
        {
            StopSession();
            foreach (var key in new[] { "probe", "login", "resources" })
                if (Phases[key] == Phase.Running) Phases[key] = Phase.Pending;
            Append(wasWorking ? "已取消本次连接。" : "私有网络会话已结束，现有外网 VPN 保持运行。");
            if (!wasWorking) LoadCredentials();
        }
        Changed();
    }

    public void Close()
    {
        Password = "";
        StopSession();
    }

    public void CopyDiagnostics()
    {
        var lines = new List<string> { $"轻舟 {typeof(App).Assembly.GetName().Version?.ToString(3)} 私有网络连接诊断", $"入口：{Probe.At("origin").Str() ?? origin}" };
        if (Probe is not null)
        {
            lines.Add($"证书 SHA-256：{Probe.At("fingerprint").Str()}");
            lines.Add($"证书核验：{Certificate.Title()}");
            lines.Add($"认证方式：{string.Join(", ", Probe.At("methods").Items().Select(m => $"{m.At("authName").Str()} / {m.At("loginDomain").Str()}"))}");
        }
        foreach (var (key, name) in new[] { ("probe", "入口检测"), ("login", "账号登录"), ("resources", "授权资源") })
            lines.Add($"{name}：{Phases[key].Title()}");
        if (Resources is not null)
            lines.Add($"应用数量：{Resources.At("appCount").Num() ?? 0:0}，地址规则：{Resources.At("rows").Items().Count()}");
        if (Routing is not null)
        {
            lines.Add($"系统分流：{(RoutingActive ? "已接入" : RoutingRecovering ? "正在恢复" : "未接入")}，自动恢复次数：{Routing.At("recoveryCount").Num() ?? 0:0}");
            if (Routing.At("lastError").Str() is { } error) lines.Add($"私有网络访问：{error}");
            if (Routing.At("internet") is { } internet)
                lines.Add($"GPT 网络：{(internet.At("result").At("ok").Bool() == true ? "可达" : "不可达")}，检测时间：{internet.At("checkedAt").Str()}");
        }
        lines.AddRange(Timeline.Select(t => $"{t.Time:HH:mm:ss} {t.Message}"));
        try { Clipboard.SetText(string.Join("\n", lines)); } catch { }
    }

    void Launch(JsonObject command)
    {
        var id = Guid.NewGuid();
        currentRun = id;
        Working = true;
        try
        {
            helper.Start(command,
                e => dispatcher.InvokeAsync(() => { if (currentRun == id) Receive(e); }),
                status => dispatcher.InvokeAsync(() =>
                {
                    if (currentRun != id) return;
                    HasSession = false;
                    TunnelProof = null;
                    BusinessVerified = false;
                    if (Working)
                        Fail(Phases["tunnel"] == Phase.Running ? "tunnel" : Phases["login"] == Phase.Running ? "login" : "probe",
                            status == 0 ? "私有网络连接服务已结束，请重新登录。" : $"私有网络连接服务意外结束（{status}），请重试。");
                    Changed();
                }));
        }
        catch (Exception e) { Fail(Phases["login"] == Phase.Running ? "login" : "probe", e.Message); }
        Changed();
    }

    void Receive(JsonNode e)
    {
        switch (e.At("type").Str())
        {
            case "progress":
                if (e.At("stage").Str() is { } stage && Phases.ContainsKey(stage)) Phases[stage] = Phase.Running;
                if (e.At("message").Str() is { } message) Append(message);
                break;
            case "probe":
                if (e.At("probe") is not { } info) return;
                AcceptProbe(info);
                if (!PasswordMethods.Any(m => m.At("loginDomain").Str() == SelectedDomain))
                    SelectedDomain = PasswordMethods.FirstOrDefault().At("loginDomain").Str() ?? "";
                Working = false;
                Append($"入口检测成功，发现 {info.At("methods").Items().Count()} 种认证方式。");
                Append(Certificate.Title());
                if (Username.Length == 0 && Password.Length == 0) LoadCredentials();
                break;
            case "login_success":
                if (!passwordChangedDuringLogin) MarkPasswordChangePending(false);
                PasswordChangeRequired = false;
                AuthenticatedUsername = e.At("username").Str();
                Phases["login"] = Phase.Passed;
                HasSession = true;
                Append("接入账号认证成功。");
                if (Probe.At("origin").Str() is { } entry)
                    try { CompanyPrefs.Update(all => all["origin"] = entry); } catch { }
                if (draft is { } saved) SaveCredentials(saved);
                draft = null;
                break;
            case "password_changed":
                if (pendingPasswordChangeID is null || e.At("id").Str() != pendingPasswordChangeID) return;
                var updated = pendingPasswordChangeCredentials;
                Username = pendingPasswordChangeUsername ?? Username;
                pendingPasswordChangeID = null; pendingPasswordChangeUsername = null; pendingPasswordChangeCredentials = null;
                draft = null; passwordChangedDuringLogin = true; MarkPasswordChangePending(true);
                CredentialMessage = "接入密码已修改；下次登录请使用新密码。";
                Append("接入密码已修改，正在继续认证…");
                if (updated is not null) SaveCredentials(updated, changedPassword: true);
                break;
            case "resources":
                if (e.At("resources") is not { } result) return;
                Resources = result;
                Phases["resources"] = Phase.Passed;
                Working = false;
                Append($"授权资源获取成功：{result.At("appCount").Num() ?? 0:0} 个应用，{result.At("rows").Items().Count()} 条地址规则。");
                break;
            case "challenge":
                pendingPasswordChangeID = null; pendingPasswordChangeUsername = null; pendingPasswordChangeCredentials = null;
                Challenge = e.At("challenge");
                if (Challenge is not null)
                {
                    Append($"接入服务要求完成{Challenge.At("title").Str()}。");
                    ChallengeRequested?.Invoke(Challenge);
                }
                break;
            case "tunnel_ready":
                if (e.At("tunnel") is not { } proof || proof.At("port").Num() is not (>= 1 and <= 65535) ||
                    proof.At("transport").Str() != "atrust-tcp")
                {
                    Fail("tunnel", "未取得有效的私有网络隧道连接信息。"); break;
                }
                TunnelProof = proof;
                Phases["tunnel"] = Phase.Passed; Phases["business"] = Phase.Pending;
                if (!TakeoverEnabled)
                {
                    Phases["routing"] = Phase.Pending;
                    BusinessVerified = false; Working = false;
                    Append("私有网络隧道已连接；资源接管已关闭，可随时开启。");
                    break;
                }
                ApplyRouting();
                break;
            case "tunnel_verified":
                if (e.At("tunnel") is not { } verified || verified.At("port").Num() != TunnelProof.At("port").Num() ||
                    !(verified.At("sent").Num() > 0) || !(verified.At("received").Num() > 0) ||
                    verified.At("httpStatus").Num() is not (>= 200 and < 400) || verified.At("transport").Str() != "atrust-tcp")
                {
                    Fail("business", "未取得有效的私有网络隧道访问证据。"); break;
                }
                TunnelProof = verified; Phases["business"] = Phase.Passed; Working = false;
                Append("指定业务经现有私有网络隧道验证通过，连接继续保持。");
                break;
            case "tunnel_closed":
                TunnelClosed();
                break;
            case "error":
                if (e.At("stage").Str() == "login" && (e.At("code").Str() == "password_change_required" ||
                    e.At("code").Str() is null && e.At("message").Str() == "unsupported next authentication service: auth/modifyPwd"))
                {
                    StopSession(); ResetAccountResults(); MarkPasswordChangePending(true); Password = "";
                    CredentialMessage = null; PasswordChangeRequired = true;
                    Fail("login", PasswordChangeGuidance);
                    return;
                }
                if (e.At("stage").Str() == "login" && e.At("code").Str() == "password_change_uncertain")
                {
                    StopSession(); ResetAccountResults(); MarkPasswordChangePending(true); Password = "";
                    CredentialMessage = "改密结果待确认，已暂停读取旧密码。请先尝试使用新密码登录。";
                }
                Fail(e.At("stage").Str() ?? "local", e.At("message").Str() ?? "连接验证失败。");
                break;
        }
        Changed();
    }

    void TunnelClosed()
    {
        TunnelProof = null; Routing = null; BusinessVerified = false;
        Phases["tunnel"] = Phase.Pending; Phases["business"] = Phase.Pending;
        Phases["routing"] = Phase.Pending; Working = false;
        Append("本次私有网络隧道已关闭，原有 VPN 保持运行。");
    }

    void Fail(string stage, string message)
    {
        if (Phases.ContainsKey(stage)) Phases[stage] = Phase.Failed;
        if (stage == "tunnel") Phases["business"] = Phase.Failed;
        ErrorStage = stage;
        ErrorMessage = message;
        Working = false;
        Challenge = null;
        if (stage == "login") { draft = null; pendingPasswordChangeID = null; pendingPasswordChangeUsername = null; pendingPasswordChangeCredentials = null; }
        if (stage == "tunnel") TunnelProof = null;
        if (stage is "tunnel" or "business" or "routing") BusinessVerified = false;
        Append(message);
        Changed();
    }

    void StopSession()
    {
        currentRun = null;
        draft = null;
        pendingPasswordChangeID = null; pendingPasswordChangeUsername = null; pendingPasswordChangeCredentials = null; passwordChangedDuringLogin = false;
        helper.Stop();
        Working = false;
        HasSession = false;
        Challenge = null;
        TunnelProof = null; BusinessVerified = false;
        Phases["tunnel"] = Phase.Pending; Phases["business"] = Phase.Pending; Phases["routing"] = Phase.Pending;
        Routing = null;
    }

    void ResetAccountResults()
    {
        PasswordChangeRequired = false;
        AuthenticatedUsername = null;
        Resources = null;
        Phases["login"] = Phase.Pending;
        Phases["resources"] = Phase.Pending;
    }

    void Append(string message)
    {
        Timeline.Add((DateTime.Now, message));
        if (Timeline.Count > 80) Timeline.RemoveRange(0, Timeline.Count - 80);
    }
}
