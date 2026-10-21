using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Qingzhou;

/// Event-driven OS integration; recovery decisions stay in the shared Rust core.
public sealed class WindowsRuntimeMonitor : IRuntimeMonitor
{
    readonly Window window;
    readonly Dispatcher dispatcher;
    readonly DispatcherTimer debounce;
    readonly RouteCallback routeCallback;
    readonly WlanCallback wlanCallback;
    readonly List<IntPtr> powerHandles = [];
    HwndSource? source;
    IntPtr routeHandle, wlanHandle;
    PhysicalNetworkSnapshot? network;
    DesktopActivity? activity;
    bool started, disposed, addressSubscribed, availabilitySubscribed;
    bool forceNetworkChange, sleeping, displayOn = true, lowPower;
    public bool NetworkEventsAvailable { get; private set; }
    public event Action<bool?>? NetworkChanged;
    public event Action<DesktopActivity>? ActivityChanged;

    public WindowsRuntimeMonitor(Window window)
    {
        this.window = window;
        dispatcher = window.Dispatcher;
        debounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        debounce.Tick += (_, _) => FlushNetworkChange();
        routeCallback = OnRouteChange;
        wlanCallback = OnWlanChange;
    }

    public void Start()
    {
        if (started || disposed) return;
        started = true;
        network = ReadNetwork();
        window.StateChanged += OnWindowChanged;
        window.IsVisibleChanged += OnVisibilityChanged;
        var hwnd = new WindowInteropHelper(window).Handle;
        source = HwndSource.FromHwnd(hwnd);
        source?.AddHook(WindowMessage);
        ReadPowerStatus();
        RegisterPower(hwnd, new Guid("E00958C0-C213-4ACE-AC77-FECCED2EEEA5")); // Battery saver
        RegisterPower(hwnd, new Guid("2B84C20E-AD23-4DDF-93DB-05FFBD7EFCA5")); // Session display
        RegisterPower(hwnd, new Guid("5D3E9A59-E9D5-4B00-A6BD-FF34FF516548")); // AC/DC
        try
        {
            NetworkChange.NetworkAddressChanged += OnAddressChanged;
            addressSubscribed = true;
            NetworkChange.NetworkAvailabilityChanged += OnAvailabilityChanged;
            availabilitySubscribed = true;
            NetworkEventsAvailable = NotifyRouteChange2(2, routeCallback, IntPtr.Zero, false, out routeHandle) == 0;
        }
        catch (Exception e) when (e is NetworkInformationException or DllNotFoundException or EntryPointNotFoundException) { }
        // A Wi-Fi switch can keep exactly the same IP and gateway. ACM events
        // cover that case without reading SSIDs, profiles or scanning for networks.
        try
        {
            if (WlanOpenHandle(2, IntPtr.Zero, out _, out wlanHandle) == 0)
                WlanRegisterNotification(wlanHandle, 0x8, true, wlanCallback, IntPtr.Zero, IntPtr.Zero, out _);
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { }
        PublishActivity();
    }

    void OnAddressChanged(object? sender, EventArgs e) => QueueNetworkChange(false);
    void OnAvailabilityChanged(object? sender, NetworkAvailabilityEventArgs e) => QueueNetworkChange(false);

    void QueueNetworkChange(bool force)
    {
        Dispatch(() =>
        {
            forceNetworkChange |= force;
            // Keep a fixed 250 ms batch window so an event storm cannot postpone
            // reporting an outage indefinitely.
            if (!debounce.IsEnabled) debounce.Start();
        });
    }

    void FlushNetworkChange()
    {
        debounce.Stop();
        if (disposed) return;
        var forced = forceNetworkChange;
        forceNetworkChange = false;
        var next = ReadNetwork();
        if (next is null) { NetworkChanged?.Invoke(null); return; }
        var changed = network?.Signature != next.Signature;
        network = next;
        if (changed || forced) NetworkChanged?.Invoke(next.Available);
    }

    static PhysicalNetworkSnapshot? ReadNetwork()
    {
        try
        {
            var adapters = new List<NetworkAdapterSnapshot>();
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                var properties = nic.GetIPProperties();
                if (!nic.Supports(NetworkInterfaceComponent.IPv4)) continue;
                adapters.Add(new(properties.GetIPv4Properties().Index, nic.Id, nic.Name, nic.Description,
                    nic.OperationalStatus == OperationalStatus.Up,
                    nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel,
                    properties.UnicastAddresses.Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
                        .Select(a => a.Address.ToString()).ToArray(),
                    properties.GatewayAddresses.Select(g => g.Address.ToString()).ToArray()));
            }
            return PhysicalNetworkSnapshot.Capture(adapters, ReadDefaultRoutes());
        }
        catch (NetworkInformationException) { return null; }
    }

    static List<DefaultRouteSnapshot> ReadDefaultRoutes()
    {
        var result = new List<DefaultRouteSnapshot>();
        if (GetIpForwardTable2(2, out var table) != 0) throw new NetworkInformationException();
        try
        {
            var count = Marshal.ReadInt32(table);
            for (var i = 0; i < count; i++)
            {
                var row = IntPtr.Add(table, 8 + i * 104);
                if (Marshal.ReadByte(row, 40) != 0) continue;
                var address = new byte[4];
                Marshal.Copy(IntPtr.Add(row, 48), address, 0, 4);
                result.Add(new(Marshal.ReadInt32(row, 8), new System.Net.IPAddress(address).ToString(),
                    unchecked((uint)Marshal.ReadInt32(row, 84))));
            }
        }
        finally { FreeMibTable(table); }
        return result;
    }

    void OnRouteChange(IntPtr context, IntPtr row, int notificationType)
    {
        if (row == IntPtr.Zero || disposed) return;
        // x64 MIB_IPFORWARD_ROW2: InterfaceIndex at 8, DestinationPrefix.PrefixLength at 40.
        // Only physical default-route events count. TUN route churn must not start a recovery loop.
        if (Marshal.ReadByte(row, 40) != 0) return;
        var index = Marshal.ReadInt32(row, 8);
        // Compare the final table after batching. Identical notifications or a
        // delete/add pair that restores the same route must not restart recovery.
        Dispatch(() => { if (network?.Indices.Contains(index) == true) QueueNetworkChange(false); });
    }

    void OnWlanChange(ref WlanNotification notification, IntPtr context)
    {
        if (notification.Source == 0x8 && notification.Code is 10 or 21)
            QueueNetworkChange(true); // connection_complete / disconnected
    }

    void OnWindowChanged(object? sender, EventArgs e) => PublishActivity();
    void OnVisibilityChanged(object sender, DependencyPropertyChangedEventArgs e) => PublishActivity();

    void ReadPowerStatus()
    {
        if (GetSystemPowerStatus(out var status)) lowPower = status.SystemStatusFlag == 1;
    }

    void PublishActivity()
    {
        if (disposed) return;
        var next = new DesktopActivity(window.IsVisible && window.WindowState != WindowState.Minimized && displayOn, lowPower, sleeping);
        if (activity == next) return;
        activity = next;
        ActivityChanged?.Invoke(next);
    }

    IntPtr WindowMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (disposed || message != 0x218) return IntPtr.Zero; // WM_POWERBROADCAST
        switch (wParam.ToInt32())
        {
            case 0x4: // PBT_APMSUSPEND
                sleeping = true;
                break;
            case 0x7: // PBT_APMRESUMESUSPEND
            case 0x12: // PBT_APMRESUMEAUTOMATIC
                sleeping = false;
                ReadPowerStatus();
                QueueNetworkChange(true);
                break;
            case 0xA: // PBT_APMPOWERSTATUSCHANGE
                ReadPowerStatus();
                break;
            case 0x8013: // PBT_POWERSETTINGCHANGE
                if (lParam == IntPtr.Zero || Marshal.ReadInt32(lParam, 16) != 4) break;
                var setting = Marshal.PtrToStructure<Guid>(lParam);
                var value = Marshal.ReadInt32(lParam, 20);
                if (setting == new Guid("E00958C0-C213-4ACE-AC77-FECCED2EEEA5")) lowPower = value == 1;
                else if (setting == new Guid("2B84C20E-AD23-4DDF-93DB-05FFBD7EFCA5")) displayOn = value != 0;
                else ReadPowerStatus();
                break;
        }
        PublishActivity();
        return IntPtr.Zero;
    }

    void RegisterPower(IntPtr hwnd, Guid setting)
    {
        var handle = RegisterPowerSettingNotification(hwnd, ref setting, 0);
        if (handle != IntPtr.Zero) powerHandles.Add(handle);
    }

    void Dispatch(Action action)
    {
        if (disposed || dispatcher.HasShutdownStarted) return;
        dispatcher.InvokeAsync(() => { if (!disposed) action(); });
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        debounce.Stop();
        if (addressSubscribed) NetworkChange.NetworkAddressChanged -= OnAddressChanged;
        if (availabilitySubscribed) NetworkChange.NetworkAvailabilityChanged -= OnAvailabilityChanged;
        window.StateChanged -= OnWindowChanged;
        window.IsVisibleChanged -= OnVisibilityChanged;
        source?.RemoveHook(WindowMessage);
        foreach (var handle in powerHandles) UnregisterPowerSettingNotification(handle);
        powerHandles.Clear();
        if (routeHandle != IntPtr.Zero) CancelMibChangeNotify2(routeHandle);
        if (wlanHandle != IntPtr.Zero) WlanCloseHandle(wlanHandle, IntPtr.Zero);
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate void RouteCallback(IntPtr context, IntPtr row, int notificationType);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate void WlanCallback(ref WlanNotification notification, IntPtr context);
    [StructLayout(LayoutKind.Sequential)]
    struct WlanNotification { public uint Source, Code; public Guid Interface; public uint Size; public IntPtr Data; }
    [StructLayout(LayoutKind.Sequential)]
    struct PowerStatus { public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag; public uint BatteryLifeTime, BatteryFullLifeTime; }

    [DllImport("iphlpapi.dll")]
    static extern uint GetIpForwardTable2(ushort family, out IntPtr table);
    [DllImport("iphlpapi.dll")]
    static extern void FreeMibTable(IntPtr memory);
    [DllImport("iphlpapi.dll")]
    static extern uint NotifyRouteChange2(ushort family, RouteCallback callback, IntPtr context, [MarshalAs(UnmanagedType.U1)] bool initialNotification, out IntPtr handle);
    [DllImport("iphlpapi.dll")]
    static extern uint CancelMibChangeNotify2(IntPtr handle);
    [DllImport("wlanapi.dll")]
    static extern uint WlanOpenHandle(uint version, IntPtr reserved, out uint negotiated, out IntPtr handle);
    [DllImport("wlanapi.dll")]
    static extern uint WlanRegisterNotification(IntPtr handle, uint source, [MarshalAs(UnmanagedType.Bool)] bool ignoreDuplicate, WlanCallback callback, IntPtr context, IntPtr reserved, out uint previousSource);
    [DllImport("wlanapi.dll")]
    static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);
    [DllImport("user32.dll")]
    static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid setting, uint flags);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool UnregisterPowerSettingNotification(IntPtr handle);
    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetSystemPowerStatus(out PowerStatus status);
}
