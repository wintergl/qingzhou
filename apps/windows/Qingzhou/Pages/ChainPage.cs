using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace Qingzhou;

public sealed record ChainTableRow(JsonNode Data, string Name, string Status, string Score, string Response, string Download, string Checked, string Detail);

public sealed class ChainPage : PageBase
{
    readonly Grid view;
    readonly TextBlock note = Ui.Warning(), summary = Ui.Note(), current = Ui.Note(), detail = Ui.Note();
    readonly ComboBox strategy = new() { Width = 130 }, subscription = new() { Width = 180 }, interval = new() { Width = 100 };
    readonly CheckBox automatic = new() { Content = "日常自动刷新", VerticalAlignment = VerticalAlignment.Center };
    readonly ListView table = Ui.Table(SelectionMode.Single, ("线路", "Name", 205), ("状态", "Status", 90), ("综合", "Score", 70), ("响应", "Response", 90), ("下载", "Download", 110), ("测量时间", "Checked", 135));
    readonly Button quick, full, continuous, pause, use, retest, cancel;
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(2) };
    bool visible, working, updating;
    string? fingerprint, subscriptionFingerprint;
    string Strategy => (strategy.SelectedItem as ComboBoxItem)?.Tag as string ?? "balanced";
    string? Subscription => (subscription.SelectedItem as ComboBoxItem)?.Tag as string;
    ChainTableRow? Selected => table.SelectedItem as ChainTableRow;
    public override FrameworkElement View => view;

    public ChainPage(Store store) : base(store)
    {
        foreach (var (title, tag) in new[] { ("综合", "balanced"), ("下载", "download"), ("响应", "latency") }) strategy.Items.Add(new ComboBoxItem { Content = title, Tag = tag });
        strategy.SelectedIndex = 0;
        foreach (var minutes in new[] { 10, 30, 60 }) interval.Items.Add(new ComboBoxItem { Content = $"{minutes} 分钟", Tag = minutes });
        interval.SelectedIndex = 1;
        quick = Ui.Button("先找可用线路", () => Start("quick"), true);
        full = Ui.Button("全面比较", () => Start("full"));
        continuous = Ui.Button("持续测试", () => Start("continuous"));
        pause = Ui.Button("暂停测试", () => Run(async () => { await S.Core.Request("chain-scan:cancel"); }));
        use = Ui.Button("使用这条线路", () => { if (Selected is { } row) Run(() => S.UseChainRoute(row.Data, S.ChainScan.At("id").Str() ?? "", Strategy)); }, true);
        retest = Ui.Button("重新检测所选", () =>
        {
            if (Selected is not { } row) return;
            if (S.ChainScan.At("running").Bool() == true) Run(async () => { await S.Core.Request("chain-scan:prioritize", new JsonObject { ["identityKey"] = row.Data.At("identityKey").Str() }); });
            else Start("accumulate", row.Data.At("identityKey").Str());
        });
        cancel = Ui.Button("取消连接", async () => await S.CancelChainUse());
        table.SelectionChanged += (_, _) => UpdateControls();
        strategy.SelectionChanged += (_, _) => { fingerprint = null; if (visible) _ = Refresh(); };
        subscription.SelectionChanged += (_, _) => { fingerprint = null; if (visible && !updating) _ = Refresh(); };
        automatic.Click += (_, _) => ConfigureAutomatic();
        interval.SelectionChanged += (_, _) => { if (!updating && visible) ConfigureAutomatic(); };
        timer.Tick += async (_, _) => { if (visible && S.Activity.CanRefresh && !working) await Refresh(); };
        view = Layout(
            Ui.Header("ISP 线路", "先找可用线路，再按需要比较；使用前确认实际出口"),
            Ui.Card(Ui.Stack(10, current, Ui.Row(Ui.Button("配置静态 ISP", () => StaticExitEditor.Show(S)), Ui.Button("刷新", () => _ = Refresh()), Ui.Button("测试历史", ShowHistory)), summary)),
            Ui.Row(subscription, strategy, automatic, interval),
            Ui.Row(quick, full, continuous, pause), note, table, detail, Ui.Row(use, retest, cancel));
    }

    public override void Shown() { visible = true; timer.Start(); _ = Refresh(); }
    public override void Hidden() { visible = false; timer.Stop(); }
    async Task Refresh() { await S.RefreshChain(Strategy, Subscription); if (visible) Update(false); }
    async void Run(Func<Task> action)
    {
        if (working) return;
        working = true; note.Text = ""; UpdateControls();
        try { await action(); }
        catch (Exception e) { note.Text = e.Message; }
        finally { working = false; await Refresh(); UpdateControls(); }
    }
    void Start(string mode, string? identity = null) => Run(async () =>
    {
        var payload = new JsonObject { ["mode"] = mode };
        if (identity is not null) { payload["identityKeys"] = J.Array(new[] { identity }); payload["forceRetest"] = true; }
        else if (Subscription is { Length: > 0 } id) payload["subscriptionId"] = id;
        await S.Core.Request("chain-scan:start", payload);
    });
    void ConfigureAutomatic() => Run(async () =>
    {
        await S.Core.Request("chain-scan:auto-configure", new JsonObject { ["enabled"] = automatic.IsChecked == true, ["intervalMinutes"] = (interval.SelectedItem as ComboBoxItem)?.Tag as int? ?? 30 });
    });

    public override void Update(bool trafficOnly)
    {
        if (trafficOnly) return;
        updating = true;
        try
        {
            var subscriptions = S.Status.At("subscription").At("entries");
            var signature = subscriptions?.ToJsonString();
            if (signature != subscriptionFingerprint)
            {
                var selected = Subscription; subscription.Items.Clear();
                subscription.Items.Add(new ComboBoxItem { Content = "全部订阅", Tag = "" });
                foreach (var entry in subscriptions.Items().Where(e => e.At("enabled").Bool() != false)) subscription.Items.Add(new ComboBoxItem { Content = entry.At("name").Str(), Tag = entry.At("id").Str() });
                subscription.SelectedItem = subscription.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string?)i.Tag == selected) ?? subscription.Items[0];
                subscriptionFingerprint = signature;
            }
            var state = S.ChainScan;
            var scope = state.At("view");
            var next = state?.ToJsonString() + Subscription + Strategy;
            if (next != fingerprint)
            {
                var identity = Selected?.Data.At("identityKey").Str();
                var results = string.IsNullOrEmpty(Subscription) ? state.At("results") : scope.At("subscriptionId").Str() == Subscription ? scope.At("results") : null;
                var rows = results.Items().Select(Row).ToList(); table.ItemsSource = rows;
                table.SelectedItem = rows.FirstOrDefault(r => r.Data.At("identityKey").Str() == identity)
                    ?? rows.FirstOrDefault(r => r.Data.At("identityKey").Str() == (scope.At("recommendedIdentityKey").Str() ?? state.At("recommendedIdentityKey").Str()));
                fingerprint = next;
            }
            automatic.IsChecked = state.At("autoRefresh").At("enabled").Bool() == true;
            var minutes = state.At("autoRefresh").At("intervalMinutes").Num();
            if (minutes is not null) interval.SelectedItem = interval.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (int)i.Tag == minutes.Value) ?? interval.Items[1];
            var routine = state.At("routine");
            current.Text = S.ChainUseActive ? $"正在处理：{S.ChainUse.At("nodeName").Str()} · {S.Busy}" : S.StaticExitEnabled ? $"ISP 已开启 · 机场前置 {S.Settings.At("selectedProxy").Str()}" : "ISP 当前关闭；可独立测试，不改变现有连接。";
            summary.Text = $"完成 {state.At("completed").Num() ?? 0:0}/{state.At("total").Num() ?? 0:0} · {scope.At("recommendationSummary").Str() ?? state.At("recommendationSummary").Str() ?? "尚无比较结果"}\n" +
                $"当前线路：{routine.At("currentNodeName").Str() ?? "待确认"} · 连接复核 {Clock(routine.At("verification").At("checkedAt").Str())} · 性能测量 {Clock(routine.At("performanceTestedAt").Str())}";
            if (S.ChainReadError is { } error) note.Text = $"读取失败，保留上次结果：{error}";
            else if (state.At("error").Str() is { } failed) note.Text = failed;
            UpdateControls();
        }
        finally { updating = false; }
    }
    void UpdateControls()
    {
        var running = S.ChainScan.At("running").Bool() == true;
        quick.IsEnabled = full.IsEnabled = continuous.IsEnabled = !working && S.CanMutate && S.StaticExitConfigured && !running;
        pause.IsEnabled = !working && running;
        use.IsEnabled = !working && S.CanMutate && !S.ConnectionProtected && S.ChainReadError is null && Selected?.Data.At("status").Str() == "available" && Selected.Data.At("connectionEligible").Bool() != false;
        retest.IsEnabled = !working && S.CanMutate && Selected is not null;
        cancel.IsEnabled = S.ChainUseActive && S.ChainUse.At("cancelRequested").Bool() != true;
        automatic.IsEnabled = interval.IsEnabled = !working && S.CanMutate && S.StaticExitConfigured;
        detail.Text = Selected is { } row ? $"{row.Name} · {row.Detail}\n短样本不代表长期带宽；其他环境或超过 24 小时的成绩需要重新确认。" : "选择线路查看检测证据。全面比较约每条 1 MiB；持续测试可随时暂停。";
    }
    static ChainTableRow Row(JsonNode data) => new(data, data.At("nodeName").Str() ?? "—",
        data.At("status").Str() switch { "available" => data.At("requiresRefresh").Bool() == true ? "待刷新" : "通过", "unstable" => "部分通过", "testing" => "检测中", _ => "未通过" },
        Number(data, "balancedScore", "0.0"), Number(data, "latencyMs", "0", " ms"), Number(data, "downloadMbps", "0.00", " Mbps"), Clock(data.At("testedAt").Str()),
        $"出口 {data.At("exitIp").Str() ?? "待确认"} · 成功 {data.At("latencySuccesses").Num() ?? 0:0}/{data.At("latencyAttempts").Num() ?? 0:0} · 波动 {Number(data, "jitterMs", "0", " ms")} · {data.At("comparisonReason").Str()}");
    static string Number(JsonNode node, string key, string format, string unit = "") => node.At(key).Num() is { } number ? number.ToString(format) + unit : "—";
    static string Clock(string? stamp) => DateTimeOffset.TryParse(stamp, out var value) ? value.ToLocalTime().ToString("MM-dd HH:mm") : "待确认";
    async void ShowHistory()
    {
        try
        {
            var records = new StackPanel(); string? before = null;
            var more = Ui.Button("加载更早记录", () => { });
            async Task Load()
            {
                more.IsEnabled = false;
                try
                {
                    var request = new JsonObject { ["limit"] = 50 }; if (before is not null) request["before"] = before;
                    var page = await S.Core.Request("chain-scan:history", request);
                    foreach (var record in page.At("records").Items())
                    {
                        var row = Row(record.At("observation")!);
                        Ui.Add(records, Ui.Text($"{row.Name} · {row.Checked} · {row.Status}\n响应 {row.Response} · 下载 {row.Download} · 综合 {row.Score} · {(record.At("sameEnvironment").Bool() == true ? "当前环境" : "其他环境")}", 12, wrap: true), 12);
                    }
                    before = page.At("nextBefore").Str(); more.IsEnabled = page.At("hasMore").Bool() == true;
                }
                catch (Exception e) { Ui.Add(records, Ui.Warning(e.Message), 10); more.IsEnabled = true; }
            }
            more.Click += async (_, _) => await Load(); await Load();
            Dialog.Show("ISP 测试历史", Ui.Stack(12, new ScrollViewer { Content = records, Height = 350 }, more), "关闭", width: 700);
        }
        catch (Exception e) { note.Text = e.Message; }
    }
}

public static class StaticExitEditor
{
    public static void Show(Store store)
    {
        var configuration = store.Settings.At("staticExit");
        var enabled = new CheckBox { Content = "经机场连接静态 ISP", IsChecked = configuration.At("enabled").Bool() == true };
        var protocol = new ComboBox { Width = 280 };
        foreach (var name in new[] { "socks5", "http", "https" }) protocol.Items.Add(name);
        TextBox server = Ui.Input(), port = Ui.Input(), username = Ui.Input(), expected = Ui.Input();
        var password = new PasswordBox { Width = 280, MinHeight = 32 };
        var paste = new PasswordBox { Width = 380, MinHeight = 32 };
        var note = Ui.Warning();
        void Fill(JsonNode? value)
        {
            protocol.SelectedItem = value.At("protocol").Str() ?? "socks5"; server.Text = value.At("server").Str() ?? "";
            port.Text = value.At("port").Num() is > 0 ? value.At("port").Num()!.Value.ToString("0") : "";
            username.Text = value.At("username").Str() ?? ""; expected.Text = value.At("expectedIp").Str() ?? "";
        }
        Fill(configuration);
        var parse = Ui.Button("解析粘贴内容", async () =>
        {
            try { var value = await store.Core.Request("static-exit:parse", new JsonObject { ["line"] = paste.Password }); Fill(value.At("configuration")); password.Password = value.At("password").Str() ?? ""; paste.Clear(); note.Text = "已解析，请核对协议后保存。"; }
            catch (Exception e) { note.Text = e.Message; }
        });
        var test = Ui.Button("测试已保存出口", async () =>
        {
            try { var value = await store.Core.Request("static-exit:test"); note.Text = $"实际出口 {value.At("ip").Str()} · {(value.At("matchesExpected").Bool() == true ? "与预期一致" : value.At("matchesExpected").Bool() == false ? "与预期不一致" : "未填写预期 IP")} · {value.At("elapsedMs").Num():0} ms"; }
            catch (Exception e) { note.Text = e.Message; }
        });
        var body = Ui.Stack(12, enabled, Ui.Note("只替换原本走代理的流量；直连和私有网络规则继续生效。代理出口仅支持 TCP。"), Ui.Field("粘贴出口", paste), parse,
            Ui.Field("协议", protocol), Ui.Field("服务器", server), Ui.Field("端口", port), Ui.Field("用户名", username), Ui.Field("密码", password), Ui.Field("预期 IP（选填）", expected),
            Ui.Note("密码留空只沿用相同服务器、端口、协议与用户名的已存密码；更换出口请重新填写。密码由 Windows 当前用户加密保存。"), test, note);
        Dialog.Show("静态 ISP 出口", new ScrollViewer { Content = body, MaxHeight = 560, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, "保存并应用", width: 650, submit: async () =>
        {
            if (!int.TryParse(string.IsNullOrWhiteSpace(port.Text) ? "0" : port.Text, out var number) || number is < 0 or > 65535) { note.Text = "请输入有效端口。"; return false; }
            var value = new JsonObject { ["enabled"] = enabled.IsChecked == true, ["protocol"] = protocol.SelectedItem as string, ["server"] = server.Text.Trim(), ["port"] = number, ["username"] = username.Text.Trim(), ["expectedIp"] = expected.Text.Trim() };
            note.Text = await store.SaveStaticExit(value, password.Password) ?? "";
            return note.Text.Length == 0;
        });
        password.Clear(); paste.Clear();
    }
}
