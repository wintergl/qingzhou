using Qingzhou;
using System.Windows;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

var cases = new (string, Action)[]
{
    ("关闭、最小化和点击打开同一窗口，图标保持常驻", () =>
    {
        using var f = new Fixture();
        Check(!f.Window.TryClose() && !f.Window.IsVisible && f.Icon.Visible && f.Exits == 0);
        f.Icon.Click(Forms.MouseButtons.Right);
        Check(!f.Window.IsVisible);
        f.Icon.Click(Forms.MouseButtons.Left);
        Check(f.Window.IsVisible && f.Window.Activations == 1);
        f.Window.WindowState = WindowState.Maximized;
        f.Window.WindowState = WindowState.Minimized;
        Check(!f.Window.IsVisible && f.Icon.Visible);
        f.Open();
        Check(f.Window.IsVisible && f.Window.WindowState == WindowState.Maximized);
    }),
    ("一千次收起恢复只创建一个图标，不执行退出", () =>
    {
        using var f = new Fixture();
        for (var i = 0; i < 1000; i++) { f.Window.TryClose(); f.Service.Restore(); }
        Check(Forms.NotifyIcon.Instances.Count == 1 && Forms.ContextMenuStrip.Instances.Count == 1
            && Drawing.Icon.Instances.Count == 1 && f.Exits == 0 && f.Window.Activations == 1000);
        Check(f.Store.Subscribers == 1 && f.Window.Subscribers == 2);
    }),
    ("托盘显示连接状态，流量刷新不创建额外资源", () =>
    {
        using var f = new Fixture();
        f.Store.TrayTitle = "网络恢复中…";
        f.Store.TrayState = VPNTrayState.Connecting;
        f.Store.PersonalTrayConnected = false;
        f.Store.Notify();
        Check(f.Icon.Text.Contains("恢复中") && f.Icon.Text.Contains(f.Menu.Items[0].Text));
        Check(f.Icon.Icon!.AssetName == "light-off-off-progress.ico");
        var count = Drawing.Icon.Instances.Count;
        f.Store.TrayTitle = "等待网络恢复…";
        f.Store.Notify(true);
        Check(f.Icon.Text.Contains("恢复中") && Forms.NotifyIcon.Instances.Count == 1 && Drawing.Icon.Instances.Count == count);
    }),
    ("菜单退出允许关闭并拒绝迟到的打开事件", () =>
    {
        using var f = new Fixture();
        f.Window.TryClose();
        f.Quit(); f.Quit(); f.Open(); f.Icon.Click(Forms.MouseButtons.Left);
        Check(f.Exits == 1 && f.Window.TryClose() && !f.Window.IsVisible && f.Service.Exiting);
    }),
    ("释放图标、菜单与事件订阅，重复释放安全", () =>
    {
        using var f = new Fixture();
        f.Service.Dispose(); f.Service.Dispose();
        Check(!f.Icon.Visible && f.Icon.Disposed && f.Menu.Disposed && Drawing.Icon.Instances.All(i => i.Disposed));
        Check(f.Menu.Items.All(i => i.Disposed) && f.Store.Subscribers == 0 && f.Window.Subscribers == 0);
        Check(f.Provider.Disposed && f.Provider.Subscribers == 0);
        f.Store.Notify();
        f.Window.WindowState = WindowState.Minimized;
        Check(f.Window.IsVisible && f.Window.TryClose());
    }),
    ("托盘创建失败释放已分配资源，保留可关闭的窗口", () =>
    {
        Forms.NotifyIcon.FailVisibility = true;
        var window = new Window(); var store = new Store(); var company = new CompanyStore();
        try { using var service = new TrayService(window, store, company, () => { }); throw new Exception("Expected tray failure"); }
        catch (InvalidOperationException e) when (e.Message == "Fixture tray unavailable") { }
        Check(window.IsVisible && window.TryClose() && window.Subscribers == 0 && store.Subscribers == 0);
        Check(Forms.NotifyIcon.Instances.All(i => i.Disposed) && Forms.ContextMenuStrip.Instances.All(m => m.Disposed)
            && Drawing.Icon.Instances.All(i => i.Disposed));
    }),
    ("蓝帆与绿船独立变化，初始和恢复状态使用不同角标", () =>
    {
        using var f = new Fixture();
        foreach (var personal in new[] { false, true })
            foreach (var company in new[] { false, true })
            {
                f.Store.PersonalTrayConnected = personal;
                f.Company.TrayConnected = company;
                f.Store.TrayState = personal ? VPNTrayState.Connected : VPNTrayState.Disconnected;
                f.Store.Notify();
                Check(f.Icon.Icon!.AssetName == $"light-{(personal ? "on" : "off")}-{(company ? "on" : "off")}-none.ico");
            }
        foreach (var (state, badge) in new[] { (VPNTrayState.Loading, "unknown"), (VPNTrayState.Unknown, "unknown"),
            (VPNTrayState.Connecting, "progress"), (VPNTrayState.Disconnecting, "progress"), (VPNTrayState.Error, "error") })
        {
            f.Store.TrayState = state;
            f.Store.Notify();
            Check(f.Icon.Icon!.AssetName!.EndsWith($"-{badge}.ico"));
        }
    }),
    ("系统任务栏主题变化更换图标并释放旧图标", () =>
    {
        using var f = new Fixture();
        var old = f.Icon.Icon!;
        f.Provider.SetLight(false);
        Check(old.Disposed && f.Icon.Icon!.AssetName == "dark-on-off-none.ico");
        var count = Drawing.Icon.Instances.Count;
        f.Provider.SetLight(false);
        Check(Drawing.Icon.Instances.Count == count);
    }),
    ("一千次状态变色始终只持有一个图标资源", () =>
    {
        using var f = new Fixture();
        for (var i = 0; i < 1000; i++)
        {
            f.Store.PersonalTrayConnected = i % 2 == 0;
            f.Company.TrayConnected = i % 3 == 0;
            f.Store.Notify();
            Check(Drawing.Icon.Instances.Count(icon => !icon.Disposed) == 1);
        }
        Check(Forms.NotifyIcon.Instances.Count == 1 && f.Exits == 0);
    }),
};
foreach (var (name, run) in cases)
{
    Forms.NotifyIcon.Instances.Clear(); Forms.ContextMenuStrip.Instances.Clear(); Drawing.Icon.Instances.Clear();
    Forms.NotifyIcon.FailVisibility = false;
    run();
    Console.WriteLine($"PASS {name}");
}
Console.WriteLine($"{cases.Length} tray adapter tests passed (fake WPF/WinForms; no native UI or VPN).");

static void Check(bool value) { if (!value) throw new Exception("Tray behavior assertion failed"); }

sealed class Fixture : IDisposable
{
    public Window Window { get; } = new();
    public Store Store { get; } = new();
    public CompanyStore Company { get; } = new();
    public TrayIconProvider Provider { get; } = new();
    public TrayService Service { get; }
    public int Exits { get; private set; }
    public Forms.NotifyIcon Icon => Forms.NotifyIcon.Instances.Single();
    public Forms.ContextMenuStrip Menu => Icon.ContextMenuStrip!;
    public Fixture() => Service = new(Window, Store, Company, () => Exits++, Provider);
    public void Open() => Menu.Items.Single(i => i.Text == "打开轻舟").PerformClick();
    public void Quit() => Menu.Items.Single(i => i.Text.StartsWith("退出轻舟")).PerformClick();
    public void Dispose() => Service.Dispose();
}
