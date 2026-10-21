using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace Qingzhou;

public sealed class MainWindow : Window
{
    readonly Store store;
    readonly Dictionary<string, PageBase> pages = [];
    readonly Dictionary<string, ListBoxItem> navItems = [];
    readonly Dictionary<string, TextBlock> counts = [];
    readonly ListBox nav = new() { BorderThickness = new Thickness(0), Background = Brushes.Transparent };
    readonly ContentControl host = new();
    readonly Ellipse dot = new() { Width = 8, Height = 8, Margin = new Thickness(0, 0, 8, 0) };
    readonly TextBlock statusText = Ui.Text("读取现有连接…", 14, bold: true);
    readonly TextBlock proxyText = Ui.Text("保留当前订阅与设置", 12, secondary: true);
    readonly Border statusBar = new() { Padding = new Thickness(24, 10, 24, 10), BorderThickness = new Thickness(0, 1, 0, 0) };
    readonly TextBlock statusBarText = Ui.Text("", 13);
    readonly ProgressBar busyBar = new() { IsIndeterminate = true, Width = 100, Height = 4, Margin = new Thickness(0, 0, 12, 0) };
    readonly Button dismiss;
    PageBase? current;
    bool showingError;

    public MainWindow(Store store, CompanyStore company)
    {
        this.store = store;
        Title = "轻舟";
        Width = 1200;
        Height = 800;
        MinWidth = 1000;
        MinHeight = 660;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        // YaHei UI carries Segoe-style Latin glyphs, so mixed text keeps one baseline.
        FontFamily = new FontFamily("Microsoft YaHei UI, Segoe UI");
        FontSize = 14;
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        SetResourceReference(BackgroundProperty, "ApplicationBackgroundBrush");

        pages["总览"] = new OverviewPage(store);
        pages["私有网络"] = new CompanyPage(store, company);
        pages["订阅"] = new SubscriptionsPage(store);
        pages["节点"] = new NodesPage(store);
        pages["节点组"] = new GroupsPage(store);
        pages["分流规则"] = new RoutingPage(store);
        pages["诊断与风险"] = new DiagnosticsPage(store);
        pages["流量"] = new TrafficPage(store);
        pages["日志"] = new LogsPage(store);
        pages["设置"] = new SettingsPage(store);

        dismiss = Ui.Button("✕", () => { store.Message = null; UpdateChrome(); });
        dismiss.Padding = new Thickness(8, 2, 8, 2);
        dismiss.MinHeight = 24;

        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(232) });
        root.ColumnDefinitions.Add(new ColumnDefinition());
        var sidebar = Sidebar();
        root.Children.Add(sidebar);

        var main = new DockPanel();
        statusBar.SetResourceReference(Border.BackgroundProperty, "CardBackgroundFillColorDefaultBrush");
        statusBar.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
        var statusDock = new DockPanel();
        DockPanel.SetDock(dismiss, Dock.Right);
        statusDock.Children.Add(dismiss);
        statusDock.Children.Add(Ui.Row(busyBar, statusBarText));
        statusBar.Child = statusDock;
        DockPanel.SetDock(statusBar, Dock.Bottom);
        main.Children.Add(statusBar);
        main.Children.Add(host);
        Grid.SetColumn(main, 1);
        root.Children.Add(main);
        Content = root;

        store.ShowError = ShowError;
        store.Changed += trafficOnly =>
        {
            if (!trafficOnly) UpdateChrome();
            current?.Update(trafficOnly);
        };
        store.Navigate += Show;
        Show("总览");
        UpdateChrome();
    }

    FrameworkElement Sidebar()
    {
        var border = new Border { BorderThickness = new Thickness(0, 0, 1, 0) };
        border.SetResourceReference(Border.BackgroundProperty, "CardBackgroundFillColorDefaultBrush");
        border.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition());
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var icon = new Image { Width = 40, Height = 40, Margin = new Thickness(0, 0, 12, 0) };
        try { icon.Source = new BitmapImage(new Uri("pack://application:,,,/Assets/qingzhou.png")); } catch { }
        var brand = Ui.Row(icon, Ui.Stack(2, Ui.Text("轻舟", 20, bold: true), Ui.Text("智能分流", 12, secondary: true)));
        brand.Margin = new Thickness(20, 22, 20, 18);
        grid.Children.Add(brand);

        Section("VPN");
        foreach (var name in new[] { "总览", "私有网络", "订阅", "节点", "节点组", "分流规则" }) Item(name);
        Section("监控");
        foreach (var name in new[] { "诊断与风险", "流量", "日志" }) Item(name);
        Section("应用");
        Item("设置");
        nav.Margin = new Thickness(10, 0, 10, 0);
        nav.SelectionChanged += (_, _) =>
        {
            if (nav.SelectedItem is ListBoxItem { Tag: string page } && pages[page] != current) Show(page);
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(nav, ScrollBarVisibility.Disabled);
        Grid.SetRow(nav, 1);
        grid.Children.Add(nav);

        var footer = Ui.Stack(6, Ui.Row(dot, statusText), proxyText);
        footer.Margin = new Thickness(22, 12, 22, 20);
        Grid.SetRow(footer, 2);
        grid.Children.Add(footer);
        border.Child = grid;
        return border;
    }

    void Section(string title)
    {
        var label = Ui.Text(title, 12, secondary: true);
        nav.Items.Add(new ListBoxItem { Content = label, IsEnabled = false, Focusable = false, Margin = new Thickness(0, 10, 0, 0) });
    }

    void Item(string name)
    {
        var count = Ui.Text("", 12, secondary: true);
        var dock = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(count, Dock.Right);
        dock.Children.Add(count);
        dock.Children.Add(Ui.Text(name, 15));
        var item = new ListBoxItem { Content = dock, Tag = name, MinHeight = 38, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        nav.Items.Add(item);
        navItems[name] = item;
        counts[name] = count;
    }

    void Show(string name)
    {
        if (!pages.TryGetValue(name, out var page)) return;
        if (page != current)
        {
            current?.Hidden();
            current = page;
            host.Content = page.View;
            page.Update(false);
            page.Shown();
        }
        if (nav.SelectedItem != navItems[name]) nav.SelectedItem = navItems[name];
    }

    void UpdateChrome()
    {
        var status = store.Status;
        dot.SetResourceReference(Shape.FillProperty, store.Connected ? "SystemFillColorSuccessBrush" : "TextFillColorTertiaryBrush");
        statusText.Text = $"VPN {store.ConnectionLabel}";
        proxyText.Text = status is null ? "保留当前订阅与设置" : store.DisplaySelectedProxy;
        var settings = store.Settings;
        counts["订阅"].Text = status is null ? "" : status.At("subscription").At("entries").Items().Count().ToString();
        counts["节点"].Text = status is null ? "" : $"{status.At("subscription").At("nodeCount").Num() ?? 0:0}";
        counts["节点组"].Text = status is null ? "" : store.Groups.Count.ToString();
        counts["分流规则"].Text = status is null ? "" : (settings.At("vpnDomainRules").Items().Count() + settings.At("directDomainRules").Items().Count()).ToString();

        if (store.Busy is { } busy)
        {
            statusBar.Visibility = Visibility.Visible;
            busyBar.Visibility = Visibility.Visible;
            dismiss.Visibility = Visibility.Collapsed;
            statusBarText.Text = busy;
        }
        else if (store.Message is { } message)
        {
            statusBar.Visibility = Visibility.Visible;
            busyBar.Visibility = Visibility.Collapsed;
            dismiss.Visibility = Visibility.Visible;
            statusBarText.Text = "✓  " + message;
        }
        else statusBar.Visibility = Visibility.Collapsed;
    }

    void ShowError(string message)
    {
        // Background polling can fail repeatedly; one dialog at a time.
        if (showingError) return;
        showingError = true;
        try { MessageBox.Show(this, message, "操作未完成", MessageBoxButton.OK, MessageBoxImage.Warning); }
        finally { showingError = false; }
    }
}
