using System.ComponentModel;
using System.Windows;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace Qingzhou;

public interface ITrayIconProvider : IDisposable
{
    bool IsLightTheme { get; }
    event Action? Changed;
    Drawing.Icon Load(string fileName);
}

/// One notification icon for the application's entire lifetime.
public sealed class TrayService : IDisposable
{
    readonly Window window;
    readonly Store store;
    readonly CompanyStore company;
    readonly ITrayIconProvider icons;
    readonly WindowLifetime lifetime;
    readonly Forms.ToolStripMenuItem status = new() { Enabled = false };
    readonly Forms.ToolStripMenuItem companyStatus = new() { Enabled = false };
    Forms.NotifyIcon? tray;
    Forms.ContextMenuStrip? menu;
    Drawing.Icon? icon;
    string? renderedAsset;
    bool disposed;
    public bool Exiting => lifetime.Exiting;

    public TrayService(Window window, Store store, CompanyStore company, Action shutdown, ITrayIconProvider? icons = null)
    {
        this.window = window;
        this.store = store;
        this.company = company;
        this.icons = icons ?? new TrayIconProvider();
        lifetime = new(new WindowAdapter(window), shutdown);
        try
        {
            menu = new Forms.ContextMenuStrip();
            menu.Items.Add(status);
            menu.Items.Add(companyStatus);
            menu.Items.Add(new Forms.ToolStripSeparator());
            menu.Items.Add("打开轻舟", null, (_, _) => Restore());
            menu.Items.Add("退出轻舟（断开连接）", null, (_, _) => lifetime.Exit());
            tray = new Forms.NotifyIcon { ContextMenuStrip = menu, Text = "轻舟" };
            tray.MouseClick += OnTrayClick;
            OnStoreChanged(false);
            // Install the icon before allowing any close/minimize action to hide the window.
            tray.Visible = true;
            window.StateChanged += OnStateChanged;
            window.Closing += OnClosing;
            store.Changed += OnStoreChanged;
            this.icons.Changed += OnAppearanceChanged;
        }
        catch { Dispose(); throw; }
    }

    public void Restore() => lifetime.Restore();
    public void AllowSystemShutdown() => lifetime.AllowSystemShutdown();

    void OnTrayClick(object? sender, Forms.MouseEventArgs e)
    {
        if (e.Button == Forms.MouseButtons.Left) Restore();
    }

    void OnStateChanged(object? sender, EventArgs e) => lifetime.StateChanged();
    void OnClosing(object? sender, CancelEventArgs e)
    {
        if (lifetime.Exiting) return;
        e.Cancel = true;
        lifetime.CanClose();
    }

    void OnStoreChanged(bool trafficOnly)
    {
        if (disposed || trafficOnly) return;
        status.Text = $"个人：{store.TrayTitle}";
        companyStatus.Text = $"私有网络：{company.StatusText}";
        var text = $"{status.Text}\n{companyStatus.Text}\n蓝帆：个人已连接 · 绿船：私有网络已连接";
        if (tray is not null && tray.Text != text) tray.Text = text;
        var visual = TrayVisual.From(store.TrayState, store.PersonalTrayConnected, company.TrayConnected);
        var asset = visual.AssetName(icons.IsLightTheme);
        if (tray is not null && renderedAsset != asset)
        {
            var replacement = icons.Load(asset);
            try { tray.Icon = replacement; }
            catch { replacement.Dispose(); throw; }
            var previous = icon;
            icon = replacement;
            renderedAsset = asset;
            previous?.Dispose();
        }
    }

    void OnAppearanceChanged()
    {
        if (disposed || window.Dispatcher.HasShutdownStarted) return;
        window.Dispatcher.InvokeAsync(() => { if (!disposed) OnStoreChanged(false); });
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        lifetime.AllowSystemShutdown();
        store.Changed -= OnStoreChanged;
        icons.Changed -= OnAppearanceChanged;
        icons.Dispose();
        window.StateChanged -= OnStateChanged;
        window.Closing -= OnClosing;
        if (tray is not null)
        {
            tray.MouseClick -= OnTrayClick;
            tray.Visible = false;
            tray.Dispose();
        }
        menu?.Dispose();
        status.Dispose();
        companyStatus.Dispose();
        icon?.Dispose();
    }

    sealed class WindowAdapter(Window window) : IDesktopWindow
    {
        public DesktopWindowState State
        {
            get => window.WindowState switch
            {
                WindowState.Minimized => DesktopWindowState.Minimized,
                WindowState.Maximized => DesktopWindowState.Maximized,
                _ => DesktopWindowState.Normal,
            };
            set => window.WindowState = value == DesktopWindowState.Maximized
                ? WindowState.Maximized : WindowState.Normal;
        }
        public bool IsVisible => window.IsVisible;
        // Hide removes the taskbar button without recreating the window/HWND.
        public void Hide() => window.Hide();
        public void Show() => window.Show();
        public void Activate() => window.Activate();
    }
}
