namespace Qingzhou;

public enum DesktopWindowState { Normal, Minimized, Maximized }

public interface IDesktopWindow
{
    DesktopWindowState State { get; set; }
    bool IsVisible { get; }
    void Show();
    void Hide();
    void Activate();
}

/// Window visibility is independent of the core's connection lifetime.
public sealed class WindowLifetime(IDesktopWindow window, Action shutdown)
{
    DesktopWindowState restoreState = window.State == DesktopWindowState.Maximized
        ? DesktopWindowState.Maximized : DesktopWindowState.Normal;
    public bool Exiting { get; private set; }

    public void StateChanged()
    {
        if (Exiting) return;
        if (window.State == DesktopWindowState.Minimized) Hide();
        else restoreState = window.State;
    }

    /// False cancels window closure and keeps the same instance in the tray.
    public bool CanClose()
    {
        if (Exiting) return true;
        if (window.State != DesktopWindowState.Minimized) restoreState = window.State;
        Hide();
        return false;
    }

    void Hide() { if (window.IsVisible) window.Hide(); }

    public void Restore()
    {
        if (Exiting) return;
        window.State = restoreState;
        window.Show();
        window.Activate();
    }

    public void Exit()
    {
        if (Exiting) return;
        Exiting = true;
        shutdown();
    }

    // Windows logoff/shutdown must not be treated as a request to hide.
    public void AllowSystemShutdown() => Exiting = true;
}
