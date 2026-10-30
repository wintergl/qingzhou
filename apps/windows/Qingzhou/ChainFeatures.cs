using System.Text.Json.Nodes;

namespace Qingzhou;

public sealed partial class Store
{
    public JsonNode? ChainScan { get; private set; }
    public JsonNode? ChainUse { get; private set; }
    public string? ChainReadError { get; private set; }
    public Func<JsonObject?> ReadExitCredential { get; set; } = () => null;
    public Action<JsonObject?> WriteExitCredential { get; set; } = _ => throw new InvalidOperationException("安全存储尚未初始化。");
    long chainRequest;
    long chainUseGeneration;
    public bool StaticExitEnabled => Settings.At("staticExit").At("enabled").Bool() == true;
    public bool StaticExitConfigured => Settings.At("staticExit").At("server").Str() is { Length: > 0 } && Settings.At("staticExit").At("port").Num() > 0;
    public bool ChainUseActive => ChainUse is not null && ChainUse.At("finished").Bool() != true;

    public async Task RefreshChain(string strategy = "balanced", string? subscription = null)
    {
        if (stopped || transportClosed) return;
        var request = ++chainRequest;
        var payload = new JsonObject { ["strategy"] = strategy };
        if (!string.IsNullOrEmpty(subscription)) payload["subscriptionId"] = subscription;
        try
        {
            var result = await Core.Request("chain-scan:get", payload);
            if (stopped || request != chainRequest) return;
            ChainScan = result; ChainReadError = null;
            if (ChainUseActive) ReceiveChainUse(await Core.Request("chain-scan:use-state"));
        }
        catch (Exception e) { if (request == chainRequest) ChainReadError = e.Message; }
        Notify();
    }

    public async Task<string?> SaveStaticExit(JsonObject configuration, string password)
    {
        if (!CanMutate) return "请等待当前操作结束。";
        JsonObject? previous = null;
        var saved = false;
        Busy = "保存 ISP 配置"; Notify();
        try
        {
            previous = await Task.Run(ReadExitCredential);
            var same = new[] { "protocol", "server", "port", "username" }.All(key => JsonNode.DeepEquals(previous.At("configuration").At(key), configuration.At(key)));
            var secret = password.Length == 0 && same ? previous.At("password").Str() ?? "" : password;
            var input = new JsonObject { ["configuration"] = configuration.DeepClone(), ["password"] = secret };
            await Task.Run(() => WriteExitCredential(input)); saved = true;
            await Core.Request("static-exit:configure", input);
            await Refresh();
            Message = "ISP 配置已保存；直连与私有网络规则继续生效。";
            return null;
        }
        catch (Exception e)
        {
            if (saved) { try { await Task.Run(() => WriteExitCredential(previous)); } catch { return "配置未应用，安全存储恢复失败，请重新保存旧配置。"; } }
            return e.Message;
        }
        finally { Busy = null; Notify(); }
    }

    void ReceiveChainUse(JsonNode? state)
    {
        if (state is null || ChainUse is null || state.At("operationId").Str() != ChainUse.At("operationId").Str()) return;
        if (chainUseGeneration != operationGeneration) { ChainUse = null; return; }
        ChainUse = state.DeepClone();
        if (connectionState == VPNTrayState.Disconnecting) return;
        if (state.At("finished").Bool() == true)
        {
            Busy = null; connectionState = null;
            var result = state.At("result");
            if (result.At("connected").Bool() == true) Message = $"已确认 ISP 出口：{result.At("exitIp").Str()}";
            else if (state.At("error").Str() is { } error) Fail(error);
        }
        else Busy = state.At("phase").Str() switch
        {
            "verifying" => "复核所选线路…", "preparing" => "准备 ISP 与 VPN…", "connecting" => "正在连接…", "confirming" => "确认实际出口…", "restoring" => "恢复原连接…", "unknown" => "连接结果待确认…", _ => "处理 ISP 连接…"
        };
        Notify();
    }

    public async Task UseChainRoute(JsonNode row, string scanId, string strategy)
    {
        if (!CanMutate || ConnectionProtected || ChainUseActive) return;
        var id = Guid.NewGuid().ToString();
        var identity = row.At("identityKey").Str();
        var generation = ++operationGeneration;
        chainUseGeneration = generation;
        ChainUse = new JsonObject { ["operationId"] = id, ["identityKey"] = identity, ["nodeName"] = row.At("nodeName").Str(), ["phase"] = "verifying" };
        connectionState = VPNTrayState.Connecting; Busy = "复核所选线路…"; Notify();
        try
        {
            var result = await Core.Request("chain-scan:use", new JsonObject { ["scanId"] = scanId, ["strategy"] = strategy, ["identityKey"] = identity, ["operationId"] = id });
            if (stopped || generation != operationGeneration) return;
            if (result.At("connected").Bool() != true || result.At("operationId").Str() != id || result.At("identityKey").Str() != identity)
                throw new InvalidOperationException("没有收到所选线路的出口确认。");
            ReceiveChainUse(new JsonObject { ["operationId"] = id, ["finished"] = true, ["phase"] = "connected", ["result"] = result?.DeepClone() });
        }
        catch (Exception e)
        {
            if (stopped || generation != operationGeneration) return;
            try
            {
                var state = await Core.Request("chain-scan:use-state");
                if (state.At("operationId").Str() != id) throw new InvalidOperationException();
                ReceiveChainUse(state);
            }
            catch { ReceiveChainUse(new JsonObject { ["operationId"] = id, ["phase"] = "unknown", ["error"] = e.Message }); }
        }
        await Refresh();
    }

    public async Task CancelChainUse()
    {
        if (!ChainUseActive || ChainUse.At("cancelRequested").Bool() == true) return;
        var id = ChainUse.At("operationId").Str();
        try { ReceiveChainUse(await Core.Request("chain-scan:cancel-use", new JsonObject { ["operationId"] = id })); }
        catch (Exception e) { Fail(e.Message); }
    }
}
