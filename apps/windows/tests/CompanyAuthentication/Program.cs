using System.Text.Json.Nodes;
using Qingzhou;

const string oldPassword = "fixture-old-password!";
const string newPassword = " fixture-New9!密码 ";
var cases = new (string Name, Action Run)[]
{
    ("login alone stays neutral and a standalone private tunnel keeps its green hull", () =>
    {
        using var f = new Fixture(takeover: false);
        f.Helper.Emit(new JsonObject { ["type"] = "login_success", ["username"] = "fixture" });
        f.Helper.Emit(new JsonObject { ["type"] = "resources", ["resources"] = new JsonObject { ["rows"] = new JsonArray(), ["appCount"] = 0 } });
        Check(f.Company.HasSession && !f.Company.TrayConnected);
        f.Helper.Emit(new JsonObject { ["type"] = "tunnel_ready", ["tunnel"] = new JsonObject { ["port"] = 32123, ["transport"] = "atrust-tcp" } });
        Check(f.Company.TrayConnected);
        f.Company.UpdateRouting(null);
        Check(f.Company.TrayConnected && !f.Company.RoutingKnown);
        f.Helper.Emit(new JsonObject { ["type"] = "tunnel_closed" });
        Check(!f.Company.TrayConnected);
    }),
    ("tray hull follows confirmed private routing and survives business errors", () =>
    {
        using var f = new Fixture();
        Check(!f.Company.TrayConnected);
        f.Company.UpdateRouting(new JsonObject { ["active"] = true });
        Check(f.Company.TrayConnected && f.Company.RoutingKnown);
        f.Company.UpdateRouting(null);
        Check(!f.Company.TrayConnected && !f.Company.RoutingKnown && f.Company.StatusText.Contains("未知"));
        f.Company.UpdateRouting(new JsonObject { ["active"] = true, ["lastError"] = "fixture business check failed" });
        Check(f.Company.TrayConnected && f.Company.RoutingKnown);
        f.Company.UpdateRouting(new JsonObject { ["active"] = false });
        Check(!f.Company.TrayConnected);
    }),
    ("form validation and UTF-16 limits", () =>
    {
        Check(new CompanyPasswordChangeInput(oldPassword, newPassword, newPassword).ValidationMessage(false) is null);
        Check(new CompanyPasswordChangeInput(oldPassword, newPassword, newPassword.Trim()).ValidationMessage(false) == "两次输入的新密码不一致。");
        Check(new CompanyPasswordChangeInput(oldPassword, oldPassword, oldPassword).ValidationMessage(false) == "新密码不能与旧密码相同。");
        Check(new CompanyPasswordChangeInput("", newPassword, newPassword).ValidationMessage(false) is not null);
        var tooLong = string.Concat(Enumerable.Repeat("😀", 65));
        Check(new CompanyPasswordChangeInput(oldPassword, tooLong, tooLong).ValidationMessage(false) == "账号名和密码不能超过 128 个字符。");
        Check(new CompanyPasswordChangeInput(oldPassword, newPassword, newPassword, " ").ValidationMessage(true) == "请填写新账号名。");
        Check(new CompanyPasswordChangeInput(oldPassword, newPassword, newPassword, " fixture-renamed ").ValidationMessage(true) is null);
    }),
    ("confirmed password then secondary authentication", () =>
    {
        using var f = new Fixture();
        Check(f.Company.StatusText == "等待修改接入密码");
        f.Company.AnswerChallenge(Response(), "change-1");
        Check(f.Helper.Commands[^1].At("type").Str() == "challenge_response");
        Check(f.Helper.Commands[^1].At("id").Str() == "change-1");
        Check(f.Helper.Commands[^1].At("newPassword").Str() == newPassword);
        Check(f.Vault.Saves == 0 && !f.Company.HasSession && f.Company.Challenge is null);
        f.Company.ConnectTunnel();
        Check(!f.Helper.Commands.Any(c => c.At("type").Str() == "connect"));
        f.Helper.Emit(Changed());
        Check(f.Vault.Saves == 1 && f.Vault.Stored.At("password").Str() == newPassword && !f.Company.HasSession);
        f.Helper.Emit(Challenge("otp", "code"));
        f.Company.AnswerChallenge(new JsonObject { ["code"] = "123456" }, "otp");
        f.Helper.Emit(new JsonObject { ["type"] = "login_success", ["username"] = "fixture" });
        f.Helper.Emit(new JsonObject { ["type"] = "resources", ["resources"] = new JsonObject { ["rows"] = new JsonArray(), ["appCount"] = 0 } });
        Check(f.Company.HasSession && !f.Company.Working && f.Vault.Saves == 1);
        f.Company.ConnectTunnel();
        Check(f.Helper.Commands[^1].At("type").Str() == "connect");
        Check(!f.Company.Timeline.Any(t => t.Message.Contains(oldPassword) || t.Message.Contains(newPassword)));
        Check(!File.ReadAllText(Path.Combine(Paths.Dir, "company.json")).Contains(newPassword));
    }),
    ("rejected attempt and stale confirmation", () =>
    {
        using var f = new Fixture();
        f.Company.AnswerChallenge(Response(), "change-1");
        f.Helper.Emit(Challenge("change-2", error: "接入密码规则未通过"));
        f.Helper.Emit(Changed());
        Check(f.Vault.Saves == 0 && f.Company.Challenge.At("errorMessage").Str() == "接入密码规则未通过");
        f.Company.AnswerChallenge(Response(), "change-2");
        f.Helper.Emit(Changed("change-2"));
        f.Helper.Emit(new JsonObject { ["type"] = "error", ["stage"] = "login", ["message"] = "验证码不正确" });
        Check(f.Vault.Saves == 1 && f.Vault.Stored.At("password").Str() == newPassword && !f.Company.HasSession);
        using var reopened = f.Reopen();
        Check(reopened.Password == newPassword);
    }),
    ("renamed account and stale form response", () =>
    {
        using var f = new Fixture();
        var challenge = Challenge("change-2"); challenge.At("challenge")!["requireUsername"] = true;
        f.Helper.Emit(challenge);
        var count = f.Helper.Commands.Count;
        f.Company.AnswerChallenge(Response(), "change-1");
        f.Company.AnswerChallenge(Response(), "change-2");
        Check(f.Helper.Commands.Count == count && f.Company.Challenge.At("id").Str() == "change-2");
        var response = Response(); response["newUsername"] = " fixture-renamed ";
        f.Company.AnswerChallenge(response, "change-2"); f.Helper.Emit(Changed("change-2"));
        Check(f.Company.Username == "fixture-renamed" && f.Vault.Stored.At("username").Str() == "fixture-renamed");
    }),
    ("remember disabled before confirmation", () =>
    {
        using var f = new Fixture();
        f.Company.AnswerChallenge(Response(), "change-1");
        f.Company.SetRememberCredentials(false); f.Helper.Emit(Changed());
        f.Helper.Emit(new JsonObject { ["type"] = "login_success" });
        Check(f.Vault.Saves == 0 && f.Vault.Stored is null && f.Company.HasSession);
    }),
    ("cancel before submission sends no password change", () =>
    {
        using var f = new Fixture();
        var count = f.Helper.Commands.Count;
        f.Company.EndTest(); f.Company.AnswerChallenge(Response(), "change-1"); f.Helper.Emit(Changed());
        Check(f.Helper.Commands.Count == count && f.Vault.Saves == 0 && !f.Company.HasSession);
    }),
    ("cancel after submission rejects late events", () =>
    {
        using var f = new Fixture();
        f.Company.AnswerChallenge(Response(), "change-1"); f.Company.EndTest();
        f.Helper.Emit(Changed()); f.Helper.Emit(new JsonObject { ["type"] = "login_success" });
        Check(f.Vault.Saves == 0 && !f.Company.HasSession && f.Company.Password.Length == 0);
        using var reopened = f.Reopen(); Check(reopened.Password.Length == 0);
    }),
    ("unknown result survives restart and is gateway scoped", () =>
    {
        using var f = new Fixture();
        f.Company.AnswerChallenge(Response(), "change-1");
        f.Helper.Emit(new JsonObject { ["type"] = "error", ["stage"] = "login", ["code"] = "password_change_uncertain", ["message"] = "未能确认改密结果" });
        f.Helper.Emit(Changed()); f.Helper.Emit(new JsonObject { ["type"] = "login_success" });
        var loads = f.Vault.Loads;
        using var reopened = f.Reopen();
        Check(reopened.Password.Length == 0 && f.Vault.Loads == loads && f.Vault.Saves == 0);
        using var other = f.Reopen("https://other.example.test"); Check(f.Vault.Loads == loads + 1);
        Check(CompanyPrefs.Load().At("unknownFixture").Str() == "preserved");
    }),
    ("failed credential update keeps old password blocked", () =>
    {
        using var f = new Fixture(); f.Vault.FailSave = true;
        f.Company.AnswerChallenge(Response(), "change-1"); f.Helper.Emit(Changed());
        f.Helper.Emit(new JsonObject { ["type"] = "login_success" }); f.Company.EndTest();
        var loads = f.Vault.Loads;
        using var reopened = f.Reopen();
        Check(!f.Company.HasSavedCredentials && reopened.Password.Length == 0 && f.Vault.Loads == loads);
        Check(f.Vault.Stored.At("password").Str() == oldPassword);
    }),
    ("legacy helper recovery and successful new login", () =>
    {
        using var f = new Fixture();
        f.Helper.Emit(new JsonObject { ["type"] = "error", ["stage"] = "login", ["message"] = "unsupported next authentication service: auth/modifyPwd" });
        Check(f.Company.PasswordChangeRequired && f.Company.ErrorHeading == "需要修改接入密码");
        Check(f.Company.StatusText == "需要修改接入密码" && f.Company.PasswordChangeEntryUrl?.AbsoluteUri == Fixture.Origin + "/");
        f.Helper.Emit(new JsonObject { ["type"] = "login_success" }); Check(!f.Company.HasSession && f.Vault.Saves == 0);
        f.Company.PrepareAfterPasswordChange();
        Check(!f.Company.PasswordChangeRequired && !f.Company.CanLogin && f.Company.Password.Length == 0);
        f.Company.Password = newPassword; f.Company.Login();
        Check(f.Helper.Commands[^1].At("password").Str() == newPassword);
        f.Helper.Emit(new JsonObject { ["type"] = "login_success" });
        Check(f.Company.HasSession && f.Vault.Stored.At("password").Str() == newPassword);
        using var reopened = f.Reopen(); Check(reopened.Password == newPassword);
    }),
    ("ordinary failures do not trigger password recovery", () =>
    {
        foreach (var e in new[] {
            new JsonObject { ["type"] = "error", ["stage"] = "login", ["message"] = "password authentication failed" },
            new JsonObject { ["type"] = "error", ["stage"] = "login", ["message"] = "unsupported next authentication service: auth/other" },
            new JsonObject { ["type"] = "error", ["stage"] = "tunnel", ["code"] = "password_change_required" },
            new JsonObject { ["type"] = "progress", ["stage"] = "login", ["code"] = "password_change_required" } })
        {
            using var f = new Fixture(); f.Helper.Emit(e); Check(!f.Company.PasswordChangeRequired);
        }
    }),
    ("typed recovery and safe entry URLs", () =>
    {
        foreach (var origin in new[] { "http://gateway.example.test", "https://user:fixture@gateway.example.test", "https://gateway.example.test/?ticket=fixture", "https://gateway.example.test/#fixture", "https://gateway.example.test/passport/v1/auth/modifyPwd" })
        {
            using var f = new Fixture(origin, login: false);
            f.Helper.Emit(new JsonObject { ["type"] = "error", ["stage"] = "login", ["code"] = "password_change_required" });
            Check(f.Company.PasswordChangeRequired && f.Company.PasswordChangeEntryUrl is null);
        }
    }),
};
var failed = 0;
foreach (var test in cases)
{
    try { test.Run(); Console.WriteLine($"PASS {test.Name}"); }
    catch (Exception error) { failed++; Console.WriteLine($"FAIL {test.Name}: {error.Message}"); }
}
Console.WriteLine($"{cases.Length} tests, {failed} failures");
return failed == 0 ? 0 : 1;

static void Check(bool condition) { if (!condition) throw new InvalidOperationException("Authentication regression assertion failed."); }
static JsonObject Response() => new() { ["oldPassword"] = "fixture-old-password!", ["newPassword"] = " fixture-New9!密码 " };
static JsonObject Changed(string id = "change-1") => new() { ["type"] = "password_changed", ["id"] = id };
static JsonObject Challenge(string id = "change-1", string kind = "password_change", string? error = null) => new()
{
    ["type"] = "challenge", ["challenge"] = new JsonObject { ["id"] = id, ["kind"] = kind, ["title"] = "修改接入密码", ["errorMessage"] = error },
};

sealed class Fixture : IDisposable
{
    public const string Origin = "https://gateway.example.test";
    readonly string dir = Path.Combine(Path.GetTempPath(), "qingzhou-windows-auth-test-" + Guid.NewGuid());
    readonly Store vpn = new();
    public FakeHelper Helper { get; } = new();
    public FakeVault Vault { get; } = new();
    public CompanyStore Company { get; }
    public Fixture(string origin = Origin, bool login = true, bool takeover = true)
    {
        Directory.CreateDirectory(dir); Paths.Dir = dir;
        CompanyPrefs.Update(all => { all["unknownFixture"] = "preserved"; all["origin"] = origin; all["takeoverEnabled"] = takeover; });
        var probe = Probe(origin); if (CompanyPrefs.IsCurrent(probe)) CompanyPrefs.Remember(probe);
        Company = new CompanyStore(vpn, Helper, Vault); Company.Origin = origin; Company.StartOnce();
        Helper.Emit(new JsonObject { ["type"] = "probe", ["probe"] = probe });
        if (login)
        {
            if (!Company.CanLogin) throw new InvalidOperationException("Fixture account was not ready.");
            Company.Login();
            Helper.Emit(new JsonObject { ["type"] = "challenge", ["challenge"] = new JsonObject { ["id"] = "change-1", ["kind"] = "password_change", ["title"] = "修改接入密码" } });
        }
    }
    public ReopenedStore Reopen(string origin = Origin) => new(Vault, origin);
    public void Dispose() { Company.Close(); Directory.Delete(dir, recursive: true); }
    static JsonObject Probe(string origin) => new()
    {
        ["origin"] = origin, ["fingerprint"] = new string('A', 64), ["subject"] = "fixture",
        ["validTo"] = "2099-01-01T00:00:00Z", ["nameMatches"] = true, ["selfSigned"] = true,
        ["methods"] = new JsonArray(new JsonObject { ["loginDomain"] = "local", ["authType"] = "auth/psw", ["authName"] = "接入账号" }),
    };
}

sealed class ReopenedStore : IDisposable
{
    public CompanyStore Company { get; }
    public string Password => Company.Password;
    public ReopenedStore(FakeVault vault, string origin)
    {
        Company = new CompanyStore(new Store(), new FakeHelper(), vault); Company.Origin = origin; Company.StartOnce();
    }
    public void Dispose() => Company.Close();
}

sealed class FakeHelper : ICompanyHelper
{
    public int? ProcessId { get; private set; }
    public List<JsonObject> Commands { get; } = [];
    Action<JsonNode>? callback;
    public void Start(JsonObject command, Action<JsonNode> onEvent, Action<int> onExit) { ProcessId = 10000; Commands.Add((JsonObject)command.DeepClone()); callback = onEvent; }
    public void Send(JsonObject command) => Commands.Add((JsonObject)command.DeepClone());
    public void Stop() => ProcessId = null;
    public void Emit(JsonNode e) => callback?.Invoke(e); // Includes intentionally late callbacks after Stop.
}

sealed class FakeVault : ICompanyCredentialVault
{
    public JsonObject? Stored { get; private set; } = new() { ["origin"] = Fixture.Origin, ["domain"] = "local", ["username"] = "fixture", ["password"] = "fixture-old-password!" };
    public int Loads, Saves;
    public bool FailSave;
    public JsonNode? Load(string key) { Loads++; return key == Fixture.Origin ? Stored?.DeepClone() : null; }
    public void Save(string key, JsonObject credentials) { Saves++; if (FailSave) throw new InvalidOperationException("Fixture vault unavailable."); Stored = (JsonObject)credentials.DeepClone(); }
    public void Remove(string key) => Stored = null;
}
