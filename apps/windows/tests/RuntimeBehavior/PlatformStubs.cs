using System.Text.Json.Nodes;

// Host-independent harness: no WPF window, native API, real core or network change.
namespace System.Windows.Threading
{
    public sealed class Dispatcher
    {
        public static Dispatcher CurrentDispatcher { get; } = new();
        public bool HasShutdownStarted => false;
        public void InvokeAsync(Action action) => action();
    }

    public sealed class DispatcherTimer
    {
        public static List<DispatcherTimer> Instances { get; } = [];
        public DispatcherTimer() => Instances.Add(this);
        public event EventHandler? Tick;
        public TimeSpan Interval { get; set; }
        public bool IsEnabled { get; private set; }
        public void Start() => IsEnabled = true;
        public void Stop() => IsEnabled = false;
        public void Fire() { if (IsEnabled) Tick?.Invoke(this, EventArgs.Empty); }
    }
}

namespace Qingzhou
{
    public sealed class CoreException(string message) : Exception(message);
    public sealed class CoreClient : ICoreClient
    {
        public event Action<string, JsonNode?>? Event { add { } remove { } }
        public Task<JsonNode?> Request(string channel, JsonObject? payload = null) => throw new InvalidOperationException("A fake core is required.");
        public void Shutdown() => throw new InvalidOperationException("No real core in tests.");
    }
    static class LoginTask
    {
        public static bool Enabled() => false;
        public static void Set(bool enabled) { }
    }
    static class RiskKeyVault
    {
        public static string? Load() => null;
        public static void Save(string value) { }
        public static void Remove() { }
    }
}
