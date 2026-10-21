namespace Qingzhou;

public enum VPNTrayState { Loading, Disconnected, Connected, Connecting, Disconnecting, Error, Unknown }
public enum TrayBadge { None, Progress, Error, Unknown }

/// Matches macOS StatusBarIconState: blue sails and green hull are independent.
public readonly record struct TrayVisual(bool PersonalConnected, bool CompanyConnected, TrayBadge Badge)
{
    public static TrayVisual From(VPNTrayState state, bool personalConnected, bool companyConnected) =>
        new(personalConnected, companyConnected, state switch
        {
            VPNTrayState.Connecting or VPNTrayState.Disconnecting => TrayBadge.Progress,
            VPNTrayState.Error => TrayBadge.Error,
            VPNTrayState.Loading or VPNTrayState.Unknown => TrayBadge.Unknown,
            _ => TrayBadge.None,
        });

    public string AssetName(bool light) =>
        $"{(light ? "light" : "dark")}-{(PersonalConnected ? "on" : "off")}-{(CompanyConnected ? "on" : "off")}-{Badge.ToString().ToLowerInvariant()}.ico";
}
