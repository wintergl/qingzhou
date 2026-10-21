using System.ComponentModel;
using Drawing = System.Drawing;

// Only WPF/WinForms/native icon boundaries are replaced. No real UI or VPN runs.
namespace System.Windows
{
    public enum WindowState { Normal, Minimized, Maximized }
    public sealed class Window
    {
        WindowState state;
        CancelEventArgs? closing;
        public WindowState WindowState
        {
            get => state;
            set { if (state != value) { state = value; StateChanged?.Invoke(this, EventArgs.Empty); } }
        }
        public bool IsVisible { get; private set; } = true;
        public TestDispatcher Dispatcher { get; } = new();
        public int Activations { get; private set; }
        public event EventHandler? StateChanged;
        public event CancelEventHandler? Closing;
        public int Subscribers => (StateChanged?.GetInvocationList().Length ?? 0) + (Closing?.GetInvocationList().Length ?? 0);
        public void Hide()
        {
            if (closing is { Cancel: false }) throw new InvalidOperationException("Cancel close before hiding.");
            IsVisible = false;
        }
        public void Show() => IsVisible = true;
        public bool Activate() { Activations++; return true; }
        public bool TryClose()
        {
            closing = new();
            try { Closing?.Invoke(this, closing); return !closing.Cancel; }
            finally { closing = null; }
        }
    }
    public sealed class TestDispatcher
    {
        public bool HasShutdownStarted => false;
        public void InvokeAsync(Action action) => action();
    }
}

namespace System.Drawing
{
    public sealed class Icon : IDisposable, ICloneable
    {
        public static List<Icon> Instances { get; } = [];
        public bool Disposed { get; private set; }
        public string? AssetName { get; }
        public Icon(string? assetName = null) { AssetName = assetName; Instances.Add(this); }
        public static Icon? ExtractAssociatedIcon(string path) => new();
        public object Clone() => new Icon();
        public void Dispose() => Disposed = true;
    }
    public static class SystemIcons { public static Icon Application => new(); }
}

namespace System.Windows.Forms
{
    public enum MouseButtons { Left, Right }
    public sealed class MouseEventArgs(MouseButtons button) : EventArgs { public MouseButtons Button => button; }
    public sealed class NotifyIcon : IDisposable
    {
        public static List<NotifyIcon> Instances { get; } = [];
        public static bool FailVisibility { get; set; }
        bool visible;
        public NotifyIcon() => Instances.Add(this);
        public bool Disposed { get; private set; }
        public Drawing.Icon? Icon { get; set; }
        public ContextMenuStrip? ContextMenuStrip { get; set; }
        public string Text { get; set; } = "";
        public bool Visible
        {
            get => visible;
            set { if (value && FailVisibility) throw new InvalidOperationException("Fixture tray unavailable"); visible = value; }
        }
        public event EventHandler<MouseEventArgs>? MouseClick;
        public void Click(MouseButtons button) => MouseClick?.Invoke(this, new(button));
        public void Dispose() => Disposed = true;
    }
    public class ToolStripMenuItem : IDisposable
    {
        public string Text { get; set; } = "";
        public bool Enabled { get; set; } = true;
        public bool Disposed { get; private set; }
        public event EventHandler? Click;
        public void PerformClick() => Click?.Invoke(this, EventArgs.Empty);
        public void Dispose() => Disposed = true;
    }
    public sealed class ToolStripSeparator : ToolStripMenuItem;
    public sealed class MenuItems : List<ToolStripMenuItem>
    {
        public void Add(string text, object? image, EventHandler onClick)
        {
            var item = new ToolStripMenuItem { Text = text };
            item.Click += onClick;
            Add(item);
        }
    }
    public sealed class ContextMenuStrip : IDisposable
    {
        public static List<ContextMenuStrip> Instances { get; } = [];
        public ContextMenuStrip() => Instances.Add(this);
        public MenuItems Items { get; } = [];
        public bool Disposed { get; private set; }
        public void Dispose() { Disposed = true; foreach (var item in Items) item.Dispose(); }
    }
}

namespace Qingzhou
{
    public sealed class Store
    {
        public string ConnectionLabel { get; set; } = "已连接";
        public string TrayTitle { get; set; } = "VPN 已开启";
        public VPNTrayState TrayState { get; set; } = VPNTrayState.Connected;
        public bool PersonalTrayConnected { get; set; } = true;
        public event Action<bool>? Changed;
        public int Subscribers => Changed?.GetInvocationList().Length ?? 0;
        public void Notify(bool trafficOnly = false) => Changed?.Invoke(trafficOnly);
    }
    public sealed class CompanyStore
    {
        public string StatusText { get; set; } = "私有网络未连接";
        public bool TrayConnected { get; set; }
    }
    public sealed class TrayIconProvider : ITrayIconProvider
    {
        public bool IsLightTheme { get; private set; } = true;
        public bool Disposed { get; private set; }
        public event Action? Changed;
        public int Subscribers => Changed?.GetInvocationList().Length ?? 0;
        public Drawing.Icon Load(string fileName) => new(fileName);
        public void SetLight(bool value) { IsLightTheme = value; Changed?.Invoke(); }
        public void Dispose() => Disposed = true;
    }
}
