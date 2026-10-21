using System.Text.Json.Nodes;

// Only the OS boundary is replaced. CompanyStore, preferences and input
// validation are compiled from production source; no real VPN or DPAPI runs.
namespace System.Windows
{
    static class Clipboard { public static void SetText(string text) { } }
}

namespace System.Windows.Threading
{
    sealed class Dispatcher
    {
        public static Dispatcher CurrentDispatcher { get; } = new();
        public void InvokeAsync(Action action) => action();
    }
}

namespace Qingzhou
{
    sealed class App { }
    static class Paths { public static string Dir { get; set; } = ""; }
    static class RiskKeyVault
    {
        public static byte[] Transform(byte[] data, bool protect) => throw new InvalidOperationException("Tests must use the injected credential vault.");
    }
    public sealed class Store
    {
        public TestCore Core { get; } = new();
        public Action<JsonNode?>? OnCompanyRouting;
        public void Notify() { }
    }
    public sealed class TestCore
    {
        public List<string> Channels { get; } = [];
        public Task<JsonNode?> Request(string channel, JsonObject? payload = null)
        {
            Channels.Add(channel);
            if (channel != "native:company-context") throw new InvalidOperationException("Unexpected network request in authentication test.");
            return Task.FromResult<JsonNode?>(new JsonObject { ["interfaceName"] = "fixture-interface" });
        }
    }
}
