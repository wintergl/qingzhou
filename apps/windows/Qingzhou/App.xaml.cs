using System.Globalization;
using System.Windows;
using System.Windows.Markup;

namespace Qingzhou;

public partial class App : Application
{
    Mutex? single;
    EventWaitHandle? activation;
    RegisteredWaitHandle? activationWait;
    Store? store;
    CompanyStore? company;
    TrayService? tray;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Create the event before acquiring the mutex so a second launch during
        // startup can leave a signal for the first window to consume when ready.
        activation = new EventWaitHandle(false, EventResetMode.AutoReset,
            @"Local\Qingzhou.Desktop.Open", out var newActivation);
        // Two shells would start two cores fighting over the same TUN and ports.
        single = new Mutex(true, @"Global\Qingzhou.Desktop", out var first);
        if (!first)
        {
            if (!newActivation) activation.Set();
            else MessageBox.Show("轻舟已在运行，请先打开或退出已有窗口。", "轻舟", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }
        // zh-CN picks the Simplified Chinese glyph variants in composite fonts.
        FrameworkElement.LanguageProperty.OverrideMetadata(typeof(FrameworkElement),
            new FrameworkPropertyMetadata(XmlLanguage.GetLanguage(CultureInfo.GetCultureInfo("zh-CN").IetfLanguageTag)));
        Appearance.Apply(Appearance.Load());
        store = new Store();
        company = new CompanyStore(store);
        var window = new MainWindow(store, company);
        MainWindow = window;
        window.Show();
        try { tray = new TrayService(window, store, company, () => Shutdown()); }
        catch
        {
            MessageBox.Show(window, "系统托盘暂不可用。最小化后仍显示在任务栏，关闭窗口会退出轻舟。",
                "托盘未启用", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        activationWait = ThreadPool.RegisterWaitForSingleObject(activation, (_, _) =>
        {
            if (!Dispatcher.HasShutdownStarted) Dispatcher.InvokeAsync(OpenMainWindow);
        }, null, Timeout.Infinite, executeOnlyOnce: false);
        _ = store.Start(new WindowsRuntimeMonitor(window));
    }

    void OpenMainWindow()
    {
        if (Dispatcher.HasShutdownStarted || tray?.Exiting == true) return;
        if (tray is not null) tray.Restore();
        else
        {
            if (MainWindow.WindowState == WindowState.Minimized) MainWindow.WindowState = WindowState.Normal;
            MainWindow.Show();
            MainWindow.Activate();
        }
    }

    protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
    {
        tray?.AllowSystemShutdown();
        base.OnSessionEnding(e);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        activationWait?.Unregister(null);
        activation?.Dispose();
        tray?.Dispose();
        store?.Stop();
        // The company helper ends with its stdin; then the core removes company routing with mihomo.
        company?.Close();
        // Closing stdin makes the core stop mihomo and restore the network.
        store?.Core.Shutdown();
        single?.Dispose();
        base.OnExit(e);
    }
}
