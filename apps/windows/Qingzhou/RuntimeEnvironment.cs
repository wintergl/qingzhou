using System.Net;
using System.Net.Sockets;
using System.Text.Json.Nodes;

namespace Qingzhou;

public interface ICoreClient
{
    event Action<string, JsonNode?>? Event;
    Task<JsonNode?> Request(string channel, JsonObject? payload = null);
    void Shutdown();
}

public interface IRuntimeMonitor : IDisposable
{
    event Action<bool?>? NetworkChanged;
    event Action<DesktopActivity>? ActivityChanged;
    bool NetworkEventsAvailable { get; }
    void Start();
}

public sealed record DesktopActivity(bool Visible = true, bool LowPower = false, bool Sleeping = false)
{
    public bool CanRefresh => Visible && !Sleeping;
    public TimeSpan RefreshInterval => TimeSpan.FromSeconds(LowPower ? 5 : 2);

    public TimeSpan? PollInterval(bool known, bool running)
    {
        if (Sleeping) return null;
        if (!known) return TimeSpan.FromSeconds(Visible ? 5 : 30);
        return running && CanRefresh ? RefreshInterval : null;
    }
}

// Only local interface identity is retained in memory. No SSID or address is logged.
public sealed record NetworkAdapterSnapshot(int Index, string Id, string Name, string Description,
    bool Up, bool Tunnel, IReadOnlyList<string> Addresses, IReadOnlyList<string> Gateways);

public sealed record DefaultRouteSnapshot(int InterfaceIndex, string NextHop, uint Metric);

public sealed record PhysicalNetworkSnapshot(string Signature, bool Available, IReadOnlySet<int> Indices)
{
    public static PhysicalNetworkSnapshot Capture(IEnumerable<NetworkAdapterSnapshot> adapters,
        IEnumerable<DefaultRouteSnapshot>? routes = null)
    {
        var physical = adapters.Where(IsPhysical).ToList();
        var indices = physical.Select(a => a.Index).ToHashSet();
        var defaults = routes?.Where(r => indices.Contains(r.InterfaceIndex)).ToList();
        var paths = physical.Where(a => a.Up && a.Addresses.Any(IsUsableAddress))
            .Where(a => defaults is null ? a.Gateways.Any(IsUsableAddress) : defaults.Any(r => r.InterfaceIndex == a.Index))
            .Select(a => $"{a.Id}:{string.Join(',', a.Addresses.Where(IsUsableAddress).Order())}:{string.Join(',', a.Gateways.Where(IsUsableAddress).Order())}")
            .Order().ToArray();
        var routeSignature = string.Join('|', (defaults ?? [])
            .Select(r => $"{r.InterfaceIndex}:{r.NextHop}:{r.Metric}").Distinct().Order());
        return new($"{string.Join('|', paths)};{routeSignature}", paths.Length > 0, indices);
    }

    static bool IsPhysical(NetworkAdapterSnapshot adapter)
    {
        if (adapter.Tunnel || adapter.Addresses.Any(IsTunAddress)) return false;
        // Keep ordinary Ethernet (including VM host adapters) usable. Exclude VPN
        // adapters even when Windows reports their type as Ethernet.
        var name = $"{adapter.Name} {adapter.Description}";
        return !new[] { "mihomo", "wintun", "wireguard", "tailscale", "tap-windows", "clash", "sing-box" }
            .Any(word => name.Contains(word, StringComparison.OrdinalIgnoreCase))
            && !adapter.Name.Equals("Meta", StringComparison.OrdinalIgnoreCase);
    }

    static bool IsTunAddress(string address) => IPAddress.TryParse(address, out var ip)
        && ip.AddressFamily == AddressFamily.InterNetwork && ip.GetAddressBytes() is var bytes
        && bytes[0] == 198 && bytes[1] is 18 or 19;

    static bool IsUsableAddress(string address)
    {
        if (!IPAddress.TryParse(address, out var ip) || ip.AddressFamily != AddressFamily.InterNetwork
            || IPAddress.IsLoopback(ip) || IsTunAddress(address)) return false;
        var bytes = ip.GetAddressBytes();
        return bytes[0] != 0 && bytes[0] < 224 && !(bytes[0] == 169 && bytes[1] == 254);
    }
}
