using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Microsoft.Win32;

namespace Qingzhou;

public sealed record SiteRow(string Id, string Label, string Result, string Delay, string Detail);
public sealed record RiskRow(string Name, string Ip, string Risk, string Checked, string Detail);

public sealed class DiagnosticsPage : PageBase
{
    readonly Grid view;
    readonly Button check, sites, repair, checkCurrent, checkAll, cancel, key, probeStart, probeStop;
    readonly StackPanel results = new();
    readonly TextBlock siteTitle = Ui.Text("", 15, bold: true), repairNote = Ui.Note();
    readonly ListView siteTable = Ui.Table(SelectionMode.Single, ("站点", "Label", 160), ("结果", "Result", 80), ("延迟", "Delay", 90), ("说明", "Detail", 360));
    readonly TextBox riskSearch = Ui.Input(220);
    readonly TextBlock riskCount = Ui.Text("", 13, secondary: true), progressText = Ui.Note(), stopped = Ui.Warning(), keyText = Ui.Note(), batchNote = Ui.Warning();
    readonly ProgressBar progress = new() { Height = 6, Maximum = 1 };
    readonly ListView riskTable = Ui.Table(SelectionMode.Single,
        ("节点", "Name", 240), ("出口 IP", "Ip", 130), ("风险", "Risk", 75), ("检测时间", "Checked", 140), ("说明", "Detail", 300));
    readonly TextBlock probeText = Ui.Text("", 14, secondary: true, wrap: true);
    readonly TextBlock currentRisk = Ui.Note();
    public override FrameworkElement View => view;

    public DiagnosticsPage(Store store) : base(store)
    {
        check = Ui.Button("检测国内与国外连通性", S.CheckConnectivity, accent: true);
        sites = Ui.Button("当前出口站点测速", S.TestWebsites);
        repair = Ui.Button("修复当前网络", () =>
        {
            if (Confirm("修复当前网络？", "修复会停止当前 VPN 内核并清理系统 DNS 缓存，请在连接异常时使用。"))
                S.Act("网络修复", "network:repair");
        });
        var network = Rows(Ui.Row(check, sites), Ui.Card(results), siteTitle, siteTable, Ui.Row(repair), repairNote);

        riskSearch.TextChanged += (_, _) => Update(false);
        checkCurrent = Ui.Button("检测当前出口", () =>
            S.Act("检测风险", "nodes:check-current-risk", new JsonObject { ["forceRefresh"] = true }));
        checkAll = Ui.Button("全量检测风险", S.CheckAllRisks, accent: true);
        cancel = Ui.Button("取消", S.CancelRiskBatch);
        key = Ui.Button("配置风险密钥", EditKey);
        var risk = Rows(
            Ui.Bar(riskCount, Ui.Field("搜索", riskSearch), checkCurrent, checkAll, cancel),
            currentRisk, Ui.Stack(4, progress, progressText, stopped),
            riskTable,
            Ui.Note("全量检测通过独立入口逐个检测机场节点；当前实际出口单独检测，两类记录分别保留。需要已配置的 ipdata 密钥。"),
            Ui.Row(key, keyText),
            batchNote);

        probeStart = Ui.Button("进入订阅探测模式", () => S.Act("启动订阅探测", "subscription-probe:start"), accent: true);
        probeStop = Ui.Button("结束订阅探测", () => S.Act("结束订阅探测", "subscription-probe:stop"));
        var probe = Ui.Stack(14, probeText, Ui.Row(probeStart, probeStop, Ui.Button("前往节点测速", () => S.Go("节点"))));

        var tabs = new TabControl { Tag = "fill" };
        foreach (var (header, content) in new (string, FrameworkElement)[] { ("网络检测", network), ("节点风险", risk), ("订阅探测", probe) })
        {
            content.Margin = new Thickness(4, 16, 4, 4);
            tabs.Items.Add(new TabItem { Header = header, Content = content });
        }
        view = Layout(Ui.Header("诊断与风险", "连通性、站点表现和风险各自保留真实检测结果"), tabs);
    }

    static TextBlock Check(string title, bool ok)
    {
        var block = Ui.Text((ok ? "✓  " : "✕  ") + title, 14);
        Ui.Tone(block, ok ? "good" : "bad");
        return block;
    }

    public override void Update(bool trafficOnly)
    {
        if (trafficOnly) return;
        var ready = S.CanMutate;
        check.IsEnabled = sites.IsEnabled = ready;
        repair.IsEnabled = ready && !S.ConnectionProtected;
        repairNote.Text = S.ConnectionProtected
            ? "另一个轻舟实例正在维护 VPN 连接，此处不能修复网络。"
            : "修复会停止当前内核并清理系统 DNS 缓存，请在连接异常时使用。";

        results.Children.Clear();
        if (S.Connectivity is { } result)
        {
            var c = result.At("connectivity");
            var domestic = c.At("domesticOk").Bool() == true;
            var proxy = (c.At("proxyOk").Bool() ?? c.At("foreignOk").Bool()) == true;
            Ui.Add(results, Check($"国内网络{(domestic ? "正常" : "未连通")}", domestic), 10);
            Ui.Add(results, Check($"代理出口{(proxy ? "正常" : "未连通")}", proxy), 10);
            if (c.At("systemDns") is { } dns)
            {
                var ok = dns.At("ok").Bool() == true;
                Ui.Add(results, Check(ok ? "系统 DNS 正常" : "系统 DNS 异常", ok), 10);
            }
            if (c.At("chatgpt") is { } gpt)
            {
                var ok = gpt.At("ok").Bool() == true;
                Ui.Add(results, Check($"ChatGPT · {OverviewPage.ProbeText(gpt)}", ok), 10);
            }
            Ui.Add(results, Ui.Text($"出口 IP：{c.At("externalIp").Str() ?? "未取得"}", 14), 6);
            if (c.At("error").Str() is { } error) Ui.Add(results, Ui.Warning(error), 6);
            if (result.At("nodeRiskError").Str() is { } riskError) Ui.Add(results, Ui.Note(riskError), 0);
        }
        else Ui.Add(results, Ui.Text("点击检测后显示本次结果；内核在运行并不代表这些业务一定可访问。", 14, secondary: true, wrap: true), 0);

        var tests = S.Websites;
        siteTitle.Text = tests is null ? "" : $"测试出口：{tests.At("proxyName").Str()}";
        siteTable.Visibility = siteTitle.Visibility = tests is null ? Visibility.Collapsed : Visibility.Visible;
        Ui.Fill(siteTable, tests.At("results").Items().Select(i => new SiteRow(
            i.At("id").Str() ?? i.At("label").Str() ?? "", i.At("label").Str() ?? "",
            i.At("ok").Bool() == true ? "连通" : "失败", Ui.Ms(i.At("delay").Num()),
            i.At("error").Str() ?? "已返回响应")).ToList(), r => r.Id);

        var live = ready && S.Running && !S.RiskBatchRunning;
        checkCurrent.IsEnabled = live;
        checkAll.IsEnabled = live && S.ProviderNodes.Any();
        cancel.Visibility = S.RiskBatchRunning ? Visibility.Visible : Visibility.Collapsed;
        key.IsEnabled = ready && !S.RiskBatchRunning;
        keyText.Text = S.RiskKeyConfigured ? "密钥已加密保存在本机（Windows 数据保护）" : "尚未配置 ipdata 密钥。";
        riskCount.Text = $"{S.Risks.Count} 条保留记录";
        currentRisk.Text = S.CurrentRisk is { } exitRisk
            ? $"当前实际出口 · {exitRisk.At("ip").Str()} · {RiskLabel(exitRisk)} · {Ui.Date(exitRisk.At("checkedAt").Str())}"
            : "当前出口风险待检测；下方保留的是机场节点风险记录。";
        batchNote.Text = S.RiskBatchNote ?? "";

        var p = S.RiskProgress;
        progress.Visibility = progressText.Visibility = p is null ? Visibility.Collapsed : Visibility.Visible;
        if (p is not null)
        {
            var done = p.At("checked").Num() ?? 0;
            var total = p.At("total").Num() ?? 0;
            progress.Value = done / Math.Max(1, total);
            var state = p.At("finished").Bool() == true
                ? (p.At("error").Str() is not null ? "未完成" : p.At("cancelled").Bool() == true ? "已取消" : "已完成")
                : p.At("nodeName").Str() ?? "准备检测";
            progressText.Text = $"{done:0} / {total:0} · {state}";
        }
        stopped.Text = p.At("stoppedReason").Str() ?? "";

        var query = riskSearch.Text.Trim();
        Ui.Fill(riskTable, S.Risks
            .Where(r => query.Length == 0 || $"{r.At("nodeName").Str()} {r.At("ip").Str()}".Contains(query, StringComparison.OrdinalIgnoreCase))
            .Select(r => new RiskRow(r.At("nodeName").Str() ?? "", r.At("ip").Str() ?? "—", RiskLabel(r),
                Ui.Date(r.At("checkedAt").Str()), r.At("error").Str() ?? string.Join("、", r.At("reasons").Strings())))
            .ToList(), r => r.Name);

        probeText.Text = S.ConnectionProtected
            ? "另一个轻舟实例正在维护 VPN 连接，先在那里结束连接，再进入订阅探测。"
            : "订阅探测会临时切换到直连模式，原有分流会暂停；探测完成后结束即可恢复。";
        probeStart.IsEnabled = probeStop.IsEnabled = ready && !S.ConnectionProtected;
    }

    async void EditKey()
    {
        var box = new PasswordBox { MinHeight = 32 };
        var remove = new CheckBox { Content = "移除已保存的密钥", Visibility = S.RiskKeyConfigured ? Visibility.Visible : Visibility.Collapsed };
        var body = Ui.Stack(10,
            Ui.Text("输入 ipdata API Key，使用 Windows 数据保护加密保存在本机。保存时会补齐 ipdata 的 VPN 分流规则。", 13, secondary: true, wrap: true),
            box, remove);
        if (!Dialog.Show("风险检测密钥", body, validate: () => remove.IsChecked == true || box.Password.Trim().Length > 0)) return;
        var error = remove.IsChecked == true ? await S.ClearRiskKey() : await S.SaveRiskKey(box.Password);
        if (error is not null) MessageBox.Show(Application.Current.MainWindow, error, "风险检测密钥", MessageBoxButton.OK, MessageBoxImage.Warning);
    }
}

public sealed record ConnRow(string Id, string Target, string Process, string Rule, string Chains, string Bytes);

public sealed class TrafficPage : PageBase
{
    readonly Grid view;
    readonly TextBlock cadence = Ui.Text("", 13, secondary: true);
    readonly TextBlock up = Metric(), down = Metric(), totals = Metric(), active = Metric(), peak = Ui.Text("", 12, secondary: true), error = Ui.Warning();
    readonly Canvas canvas = new() { Height = 170, ClipToBounds = true };
    readonly Polyline upload = Line("AccentFillColorDefaultBrush"), download = Line("SystemFillColorSuccessBrush");
    readonly TextBox filter = Ui.Input(320);
    readonly ListView table = Ui.Table(SelectionMode.Single,
        ("目标", "Target", 240), ("进程", "Process", 130), ("匹配规则", "Rule", 180), ("实际出口", "Chains", 210), ("上传 / 下载", "Bytes", 160));
    public override FrameworkElement View => view;

    public TrafficPage(Store store) : base(store)
    {
        var metrics = new UniformGrid { Columns = 4 };
        foreach (var (label, value) in new[] { ("上传速率", up), ("下载速率", down), ("累计上传 / 下载", totals), ("活跃连接", active) })
        {
            var card = Ui.Card(Ui.Stack(8, Ui.Text(label, 13, secondary: true), value));
            card.Margin = new Thickness(0, 0, label == "活跃连接" ? 0 : 12, 0);
            metrics.Children.Add(card);
        }
        canvas.Children.Add(upload);
        canvas.Children.Add(download);
        canvas.SizeChanged += (_, _) => Draw();
        var upLegend = Ui.Text("━ 上传", 12);
        upLegend.SetResourceReference(TextBlock.ForegroundProperty, "AccentFillColorDefaultBrush");
        var downLegend = Ui.Text("━ 下载", 12);
        downLegend.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorSuccessBrush");
        var chart = Ui.Card(Ui.Stack(8, Ui.Bar(peak, upLegend, downLegend), canvas));
        filter.TextChanged += (_, _) => Update(false);
        view = Layout(
            Ui.Header("流量", "同一内核的实时连接，直接查看流量最终去了哪里"),
            metrics, chart,
            Ui.Bar(cadence, Ui.Field("筛选", filter)),
            table, error);
    }

    static TextBlock Metric() => Ui.Text("—", 22, bold: true);

    static Polyline Line(string brush)
    {
        var line = new Polyline { StrokeThickness = 2, StrokeLineJoin = PenLineJoin.Round };
        line.SetResourceReference(Shape.StrokeProperty, brush);
        return line;
    }

    public override void Update(bool trafficOnly)
    {
        var t = S.Traffic;
        cadence.Text = !S.Activity.CanRefresh ? "窗口恢复显示后更新" : !S.Running ? "连接后显示实时流量"
            : S.Activity.LowPower ? "省电模式 · 每 5 秒更新" : "每 2 秒更新";
        var snapshot = t.At("snapshot");
        up.Text = $"{Ui.Bytes(t.At("rates").At("upload").Num() ?? 0)}/s";
        down.Text = $"{Ui.Bytes(t.At("rates").At("download").Num() ?? 0)}/s";
        totals.Text = $"{Ui.Bytes(snapshot.At("uploadTotal").Num() ?? 0)} / {Ui.Bytes(snapshot.At("downloadTotal").Num() ?? 0)}";
        active.Text = $"{snapshot.At("connectionCount").Num() ?? 0:0}";
        var query = filter.Text.Trim();
        var rows = snapshot.At("connections").Items().Select(c =>
        {
            var host = c.At("host").Str();
            var target = string.IsNullOrEmpty(host) ? c.At("destination").Str() ?? "" : host;
            var chains = string.Join(" → ", c.At("chains").Strings());
            return new ConnRow(c.At("id").Str() ?? target, target, c.At("process").Str() ?? "—",
                $"{c.At("rule").Str()} {c.At("rulePayload").Str()}".Trim(), chains,
                $"{Ui.Bytes(c.At("upload").Num() ?? 0)} / {Ui.Bytes(c.At("download").Num() ?? 0)}");
        }).Where(r => query.Length == 0 || $"{r.Target} {r.Process} {r.Chains}".Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
        Ui.Fill(table, rows, r => r.Id);
        error.Text = t.At("error").Str() ?? "";
        Draw();
    }

    void Draw()
    {
        var samples = S.Traffic.At("samples").Items().TakeLast(90).ToList();
        double width = canvas.ActualWidth, height = canvas.ActualHeight;
        if (width <= 0 || height <= 0) return;
        static double Up(JsonNode s) => s.At("upload").Num() ?? 0;
        static double Down(JsonNode s) => s.At("download").Num() ?? 0;
        var max = Math.Max(1024, samples.Count == 0 ? 0 : samples.Max(s => Math.Max(Up(s), Down(s))));
        PointCollection Points(Func<JsonNode, double> value) => new(samples.Select((s, i) =>
            new Point(samples.Count < 2 ? 0 : i * width / (samples.Count - 1), height - 2 - value(s) / max * (height - 4))));
        upload.Points = Points(Up);
        download.Points = Points(Down);
        peak.Text = $"峰值 {Ui.Bytes(max)}/s";
    }
}

public sealed class LogsPage : PageBase
{
    readonly Grid view;
    readonly ComboBox kind = new() { Width = 150, MinHeight = 32 };
    readonly TextBox query = Ui.Input(280);
    readonly CheckBox follow = new() { Content = "跟随更新", IsChecked = true, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBox text = new()
    {
        IsReadOnly = true,
        Tag = "fill",
        FontFamily = new FontFamily("Cascadia Mono, Consolas, Microsoft YaHei UI"),
        FontSize = 12.5,
        TextWrapping = TextWrapping.NoWrap,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        VerticalContentAlignment = VerticalAlignment.Top,
        Padding = new Thickness(12),
    };
    readonly TextBlock count = Ui.Text("", 13, secondary: true), failure = Ui.Warning();
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(2) };
    List<string> lines = [];
    bool reading, shown, readAgain;
    public override FrameworkElement View => view;

    public LogsPage(Store store) : base(store)
    {
        kind.Items.Add(new ComboBoxItem { Content = "应用", Tag = "app" });
        kind.Items.Add(new ComboBoxItem { Content = "Mihomo 内核", Tag = "mihomo" });
        kind.SelectedIndex = 0;
        kind.SelectionChanged += (_, _) => { lines = []; Render(); Read(); };
        query.TextChanged += (_, _) => Render();
        follow.Click += (_, _) => { Schedule(); if (follow.IsChecked == true) Read(); };
        timer.Tick += (_, _) => { timer.Stop(); Read(); };
        view = Layout(
            Ui.Header("日志", "读取应用与内核日志，诊断导出自动脱敏"),
            Ui.Bar(follow, Ui.Field("来源", kind), Ui.Field("搜索", query)),
            text,
            Ui.Bar(count,
                Ui.Button("复制当前显示", () => { try { Clipboard.SetText(text.Text); } catch { } }),
                Ui.Button("清空显示", () => { follow.IsChecked = false; Schedule(); lines = []; Render(); }),
                Ui.Button("导出脱敏诊断", Export)),
            failure);
    }

    public override void Shown()
    {
        shown = true;
        Read();
        Schedule();
    }

    public override void Hidden() { shown = false; timer.Stop(); }

    public override void Update(bool trafficOnly) { if (!trafficOnly) Schedule(); }

    void Schedule()
    {
        if (!shown || !S.Activity.CanRefresh || follow.IsChecked != true || reading)
        { timer.Stop(); return; }
        timer.Interval = S.Activity.RefreshInterval;
        if (!timer.IsEnabled) timer.Start();
    }

    async void Read()
    {
        if (!shown || !S.Activity.CanRefresh) return;
        if (reading) { readAgain = true; return; }
        reading = true;
        timer.Stop();
        try
        {
            var source = (kind.SelectedItem as ComboBoxItem)?.Tag as string ?? "app";
            var result = await S.Core.Request("logs:get", new JsonObject { ["kind"] = source });
            if (!shown || !S.Activity.CanRefresh || source != ((kind.SelectedItem as ComboBoxItem)?.Tag as string ?? "app")) return;
            lines = result.Strings().ToList();
            failure.Text = "";
            Render();
        }
        catch (Exception e) { failure.Text = e.Message; }
        finally
        {
            reading = false;
            if (readAgain) { readAgain = false; Read(); }
            Schedule();
        }
    }

    void Render()
    {
        var q = query.Text.Trim();
        var visible = string.Join("\n", lines.Where(l => q.Length == 0 || l.Contains(q, StringComparison.OrdinalIgnoreCase)));
        if (text.Text != visible)
        {
            text.Text = visible;
            if (follow.IsChecked == true) text.ScrollToEnd();
        }
        count.Text = $"最近 {lines.Count} 行";
    }

    async void Export()
    {
        try
        {
            var content = (await S.Core.Request("logs:export-redacted", new JsonObject { ["includeMihomoSummary"] = true })).Str() ?? "";
            var dialog = new SaveFileDialog { FileName = "轻舟-诊断.txt", Filter = "文本文件 (*.txt)|*.txt" };
            if (dialog.ShowDialog(Application.Current.MainWindow) == true)
                File.WriteAllText(dialog.FileName, content, new UTF8Encoding(true));
        }
        catch (Exception e) { failure.Text = e.Message; }
    }
}

public sealed class SettingsPage : PageBase
{
    readonly ScrollViewer view;
    readonly ComboBox appearance = new() { Width = 160, MinHeight = 32 };
    readonly Dictionary<string, (CheckBox Box, bool Default)> network = [], compat = [];
    readonly CheckBox login = new() { Content = "登录 Windows 后启动轻舟（以管理员身份，无需再次确认）" };
    readonly TextBlock dataDir = Ui.Text("", 13, secondary: true, wrap: true);
    public override FrameworkElement View => view;

    public SettingsPage(Store store) : base(store)
    {
        foreach (var (label, value) in new[] { ("浅色", "light"), ("深色", "dark"), ("跟随系统", "system") })
            appearance.Items.Add(new ComboBoxItem { Content = label, Tag = value });
        var saved = Appearance.Load();
        appearance.SelectedItem = appearance.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == saved) ?? appearance.Items[2];
        appearance.SelectionChanged += (_, _) =>
        {
            if (appearance.SelectedItem is not ComboBoxItem { Tag: string value }) return;
            Appearance.Save(value);
            Appearance.Apply(value);
        };

        foreach (var (key, label, fallback) in new[] { ("tun", "TUN 系统分流", true), ("ipv6", "IPv6", false), ("lanDirect", "局域网直连", true), ("tailscaleDirect", "Tailscale 直连", true) })
        {
            var box = new CheckBox { Content = label };
            box.Click += (_, _) => S.Act("保存网络设置", "native:preferences", new JsonObject { [key] = box.IsChecked == true });
            network[key] = (box, fallback);
        }
        foreach (var (key, label) in new[] { ("mailMasterDirect", "邮箱大师优先直连"), ("mailMasterProxy8081", "邮箱大师 8081 端口兼容"), ("wechatImageSendFallback", "微信直连优先与代理回退") })
        {
            var box = new CheckBox { Content = label };
            box.Click += (_, _) => S.Act("保存兼容设置", "routing:update",
                new JsonObject { ["specialCompatibilityRules"] = new JsonObject { [key] = box.IsChecked == true } });
            compat[key] = (box, true);
        }
        login.Click += (_, _) => S.SetLaunchAtLogin(login.IsChecked == true);

        var body = Ui.Stack(16,
            Ui.Header("设置", "沿用现有配置，网络调整经校验后在线应用"),
            Section("界面外观", Ui.Field("显示模式", appearance)),
            Section("网络", network.Values.Select(v => (UIElement)v.Box).ToArray()),
            Section("静态 ISP 出口", Ui.Note("机场 → 静态 ISP → 网站；保留直连与私有网络。"), Ui.Button("配置静态 ISP", () => StaticExitEditor.Show(S)), Ui.Button("比较 ISP 线路", () => S.Go("ISP 线路"))),
            Section("兼容规则", compat.Values.Select(v => (UIElement)v.Box)
                .Append(Ui.Text("邮箱大师全部连接优先直连，包括海外邮箱；自定义代理和私有网络规则仍优先。关闭后恢复常规分流。8081 端口兼容只保留原始连接目标。", 11, secondary: true, wrap: true))
                .Append(Ui.Text("国内连接按直连规则处理；其余微信连接优先直连，直连检测失败后回退到代理。启用静态 ISP 时回退到该出口。自定义分流规则优先。", 11, secondary: true, wrap: true)).ToArray()),
            Section("启动与数据", login, dataDir, Ui.Row(
                Ui.Button("打开数据目录", OpenData),
                Ui.Button("重新读取当前配置", async () => await S.Refresh()))));
        body.Margin = new Thickness(28, 24, 28, 20);
        body.MaxWidth = 760;
        body.HorizontalAlignment = HorizontalAlignment.Left;
        view = Scroll(body);
    }

    static Border Section(string title, params UIElement[] items) =>
        Ui.Card(Ui.Stack(12, [Ui.Text(title, 16, bold: true), .. items]), 18);

    void OpenData()
    {
        if (S.DataDir.Length == 0 || !Directory.Exists(S.DataDir)) return;
        var info = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
        info.ArgumentList.Add(S.DataDir);
        try { Process.Start(info); } catch { }
    }

    public override void Update(bool trafficOnly)
    {
        if (trafficOnly) return;
        var settings = S.Settings;
        foreach (var (key, (box, fallback)) in network)
        {
            box.IsChecked = settings.At(key).Bool() ?? fallback;
            box.IsEnabled = S.CanMutate;
        }
        foreach (var (key, (box, fallback)) in compat)
        {
            box.IsChecked = settings.At("specialCompatibilityRules").At(key).Bool() ?? fallback;
            box.IsEnabled = S.CanMutate;
        }
        login.IsChecked = S.LaunchAtLogin;
        login.IsEnabled = !S.PreviewOnly && S.Busy is null;
        dataDir.Text = S.DataDir.Length == 0 ? "数据目录：读取中…" : $"数据目录：{S.DataDir}";
    }
}
