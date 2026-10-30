using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace Qingzhou;

public sealed class OverviewPage : PageBase
{
    readonly ScrollViewer view;
    readonly TextBlock title, subtitle, pill = Ui.Text("", 13, bold: true);
    readonly TextBlock modeValue, modeNote, proxyValue, loginValue;
    readonly TextBlock domestic = Ui.Text(), foreign = Ui.Text(), dns = Ui.Text(), chatgpt = Ui.Text(), ip = Ui.Text(), risk = Ui.Text(), connNote = Ui.Note();
    readonly StackPanel sites = new();
    readonly TextBlock connTiming = Ui.Note(), siteTiming = Ui.Note();
    readonly TextBlock counts = Ui.Text("", 12, secondary: true);
    readonly Button connect, check, websites, update, retry;
    readonly TextBlock recoveryNote = Ui.Warning();
    readonly FrameworkElement recovery;
    public override FrameworkElement View => view;

    public OverviewPage(Store store) : base(store)
    {
        var header = Ui.Header("网络总览", "选择节点后连接 VPN", out title, out subtitle);
        connect = Ui.Button("连接 VPN", S.ConnectOrDisconnect, accent: true);
        connect.MinWidth = 110;
        var top = Ui.Card(Ui.Bar(Ui.Stack(12, pill, connect), header), 26);
        top.CornerRadius = new CornerRadius(22);
        top.SetResourceReference(Border.BackgroundProperty, "BrandHero");
        top.BorderThickness = new Thickness(0);
        title.SetResourceReference(TextBlock.ForegroundProperty, "BrandHeroText");
        subtitle.SetResourceReference(TextBlock.ForegroundProperty, "BrandHeroMuted");
        retry = Ui.Button("重试连接", S.RetryRecovery);
        recovery = Ui.Card(Ui.Stack(10, recoveryNote, retry));
        recovery.Visibility = Visibility.Collapsed;

        var cards = new UniformGrid { Columns = 3 };
        cards.Children.Add(Summary("分流模式", out modeValue, out modeNote, ""));
        cards.Children.Add(Summary("当前出口", out proxyValue, out _, "在节点页切换具体节点"));
        cards.Children.Add(Summary("启动设置", out loginValue, out _, "登录 Windows 后启动轻舟", last: true));

        update = Ui.Button("更新订阅", () => S.Act("更新订阅", "subscription:update"));
        var actions = Ui.Row(
            Ui.Button("切换节点", () => S.Go("节点"), accent: true),
            Ui.Button("节点组", () => S.Go("节点组")),
            Ui.Button("ISP 线路", () => S.Go("ISP 线路")),
            update,
            Ui.Button("分流规则", () => S.Go("分流规则")),
            Ui.Button("流量监控", () => S.Go("流量")));

        check = Ui.Button("检测", S.CheckConnectivity);
        var connectivity = Ui.Card(Ui.Stack(12,
            Ui.Bar(check, Ui.Text("连接检测", 16, bold: true)),
            Line("国内网络", domestic), Line("代理出口", foreign), Line("系统 DNS", dns), Line("ChatGPT", chatgpt), Line("出口 IP", ip), Line("出口风险", risk),
            connNote, connTiming), 18);
        websites = Ui.Button("检测", S.TestWebsites);
        var siteCard = Ui.Card(Ui.Stack(12,
            Ui.Bar(websites, Ui.Text("站点测速", 16, bold: true)),
            sites,
            siteTiming), 18);
        var pair = new Grid();
        pair.ColumnDefinitions.Add(new ColumnDefinition());
        pair.ColumnDefinitions.Add(new ColumnDefinition());
        connectivity.Margin = new Thickness(0, 0, 7, 0);
        siteCard.Margin = new Thickness(7, 0, 0, 0);
        Grid.SetColumn(siteCard, 1);
        pair.Children.Add(connectivity);
        pair.Children.Add(siteCard);

        var body = Ui.Stack(20, top, recovery, cards, actions, Ui.Text("网络质量", 16, bold: true), pair, Ui.Bar(Link("管理订阅", () => S.Go("订阅")), counts));
        body.Margin = new Thickness(28, 24, 28, 20);
        view = Scroll(body);
    }

    static Border Summary(string label, out TextBlock value, out TextBlock note, string noteText, bool last = false)
    {
        value = Ui.Text("—", 18, bold: true);
        note = Ui.Text(noteText, 12, secondary: true);
        var card = Ui.Card(Ui.Stack(6, Ui.Text(label, 13, secondary: true), value, note));
        card.Margin = new Thickness(0, 0, last ? 0 : 12, 0);
        return card;
    }

    static DockPanel Line(string label, TextBlock value)
    {
        value.FontWeight = FontWeights.SemiBold;
        return Ui.Bar(value, Ui.Text(label, 14, secondary: true));
    }

    static Button Link(string text, Action click)
    {
        var button = Ui.Button(text, click);
        button.HorizontalAlignment = HorizontalAlignment.Left;
        return button;
    }

    public override void Update(bool trafficOnly)
    {
        if (trafficOnly) return;
        var loaded = S.Status is not null;
        var settings = S.Settings;
        title.Text = !loaded ? "读取当前网络…" : S.Connected ? "智能分流中" : "网络总览";
        subtitle.Text = S.Recovering ? S.RecoveryMessage : S.Connected ? $"内核已运行 · {Uptime(S.Status.At("mihomo").At("startedAt").Str())}" : "选择节点后连接 VPN";
        pill.Text = $"{(S.Connected ? "●" : "○")} {S.ConnectionLabel}";
        pill.SetResourceReference(TextBlock.ForegroundProperty, "BrandHeroMuted");
        connect.Content = S.ConnectionProtected ? "验证连接" : (S.CanDisconnect || S.ConnectionRequested) ? "断开 VPN" : "连接 VPN";
        foreach (var button in new[] { check, websites, update }) button.IsEnabled = S.CanMutate;
        connect.IsEnabled = S.CanControlConnection;
        recovery.Visibility = S.Recovering || S.LatestRecovery is not null ? Visibility.Visible : Visibility.Collapsed;
        recoveryNote.Text = string.Join("\n", new[] { S.RecoveryMessage, S.LatestRecoveryMessage }.Where(value => value.Length > 0));
        retry.Visibility = S.RecoveryState == "failed" ? Visibility.Visible : Visibility.Collapsed;
        retry.IsEnabled = S.CanMutate;

        modeValue.Text = !loaded ? "—" : settings.At("unknownTraffic").Str() == "vpn" ? "默认 VPN" : "默认直连";
        modeNote.Text = settings.At("tun").Bool() == true ? "系统 TUN 分流" : "系统 TUN 未开启";
        proxyValue.Text = loaded ? S.DisplaySelectedProxy : "—";
        proxyValue.ToolTip = proxyValue.Text;
        loginValue.Text = S.LaunchAtLogin ? "登录后启动" : "未开启";

        var c = S.Connectivity.At("connectivity");
        domestic.Text = Check(c.At("domesticOk").Bool(), c.At("latency").At("domesticMs").Num());
        foreign.Text = Check(c.At("proxyOk").Bool() ?? c.At("foreignOk").Bool(), c.At("latency").At("foreignMs").Num());
        dns.Text = ProbeText(c.At("systemDns"));
        chatgpt.Text = ProbeText(c.At("chatgpt"));
        ip.Text = c.At("externalIp").Str() ?? "尚未读取";
        risk.Text = S.CurrentRisk is null ? "待检测" : $"{RiskLabel(S.CurrentRisk)} · {Ui.Date(S.CurrentRisk.At("checkedAt").Str())}";
        connNote.Text = S.Diagnostics.At("connectivity").At("error").Str() ?? c.At("error").Str()
            ?? (S.CurrentRisk is { } r ? $"风险记录：{Ui.Date(r.At("checkedAt").Str())}" : "检测包含系统 DNS 与 ChatGPT 网络响应。");

        connTiming.Text = S.DiagnosticTiming("connectivity");
        siteTiming.Text = S.DiagnosticTiming("websites");
        check.Content = S.Diagnostics.At("connectivity").At("state").Str() == "running" ? "检测中…" : "立即检测";
        websites.Content = S.Diagnostics.At("websites").At("state").Str() == "running" ? "检测中…" : "立即检测";
        check.IsEnabled = S.CanMutate && S.Diagnostics.At("connectivity").At("state").Str() != "running";
        websites.IsEnabled = S.CanMutate && S.Diagnostics.At("websites").At("state").Str() != "running";
        sites.Children.Clear();
        var results = S.Websites.At("results").Items().Take(3).ToList();
        if (results.Count == 0)
        {
            Ui.Add(sites, Ui.Text("Google · ChatGPT · Claude", 15, bold: true), 8);
            Ui.Add(sites, Ui.Text("连接后自动检测站点响应，结果在此显示。", 13, secondary: true, wrap: true), 0);
        }
        foreach (var item in results)
        {
            var value = Ui.Text(item.At("ok").Bool() == true ? (item.At("delay").Num() is { } d ? $"{d:0} ms" : "连通") : item.At("failureReason").Str() == "restricted" ? $"访问受限 · {item.At("httpStatus").Num():0}" : item.At("failureReason").Str() == "timeout" ? "响应超时" : "未连通");
            Ui.Add(sites, Line(item.At("label").Str() ?? "", value), 10);
        }
        if (S.Diagnostics.At("websites").At("error").Str() is { } siteError)
            Ui.Add(sites, Ui.Warning(siteError), 6);

        var status = S.Status;
        string N(double? n) => n is { } v ? $"{v:0}" : "—";
        counts.Text = $"{N(status.At("subscription").At("entries").Items().Count())} 订阅    " +
            $"{N(status.At("subscription").At("nodeCount").Num())} 节点    {S.Favorites.Count} 收藏    " +
            $"{S.Groups.Count} 节点组    {N(settings.At("vpnDomainRules").Items().Count())} 分流规则";
    }

    public static string ProbeText(JsonNode? probe)
    {
        if (probe is null) return "尚未检测";
        if (probe.At("ok").Bool() == true) return "正常";
        var status = probe.At("httpStatus").Num();
        if (probe.At("failureReason").Str() == "restricted" || status is 403 or 429 or 451)
            return status is { } code ? $"访问受限 · {code:0}" : "访问受限";
        return probe.At("failureReason").Str() == "timeout" ? "响应超时" : "未连通";
    }
    static string Check(bool? ok, double? ms) => ok switch
    {
        null => "尚未检测",
        true => ms is { } v ? $"正常 · {v:0} ms" : "正常",
        false => "未连通",
    };

    static string Uptime(string? value)
    {
        if (!DateTimeOffset.TryParse(value, out var start)) return "时长暂不可读取";
        var minutes = Math.Max(0, (int)(DateTimeOffset.Now - start).TotalMinutes);
        return minutes < 60 ? $"{minutes} 分钟" : $"{minutes / 60} 小时 {minutes % 60} 分钟";
    }
}

public sealed record SubRow(string Id, string Name, string Host, string State, string Nodes, string Updated, string Mode);

public sealed class SubscriptionsPage : PageBase
{
    readonly Grid view;
    readonly ListView table = Ui.Table(SelectionMode.Single,
        ("订阅", "Name", 220), ("地址", "Host", 190), ("状态", "State", 80), ("节点", "Nodes", 60),
        ("最近更新", "Updated", 150), ("更新方式", "Mode", 140));
    readonly TextBlock summary = Ui.Text("", 13, secondary: true), error = Ui.Warning();
    readonly StackPanel actions;
    readonly Button add, updateAll, toggle, updateOne;
    public override FrameworkElement View => view;

    public SubscriptionsPage(Store store) : base(store)
    {
        add = Ui.Button("添加订阅", () => Edit(null), accent: true);
        updateAll = Ui.Button("更新全部启用订阅", () => S.Act("更新订阅", "subscription:update"));
        toggle = Ui.Button("停用", () =>
        {
            if (Selected() is { } e)
                S.Act("调整订阅", "subscription:set-enabled", new JsonObject { ["id"] = e.At("id").Str(), ["enabled"] = e.At("enabled").Bool() != true });
        });
        updateOne = Ui.Button("更新此订阅", () =>
        {
            if (Selected() is { } e) S.Act("更新订阅", "subscription:update", new JsonObject { ["id"] = e.At("id").Str() });
        });
        Button schedule = null!;
        schedule = Ui.Button("自动更新 ▾", () =>
        {
            schedule.ContextMenu!.PlacementTarget = schedule;
            schedule.ContextMenu.Placement = PlacementMode.Bottom;
            schedule.ContextMenu.IsOpen = true;
        });
        var menu = new ContextMenu();
        foreach (var (label, minutes) in new (string, int?)[] { ("每天更新", 1440), ("每小时更新", 60), ("每 5 分钟更新", 5), ("仅手动更新", null) })
        {
            var item = new MenuItem { Header = label };
            item.Click += (_, _) =>
            {
                if (Selected() is { } e)
                    S.Act("保存更新方式", "subscription:configure-update",
                        new JsonObject { ["id"] = e.At("id").Str(), ["intervalMinutes"] = minutes is { } m ? JsonValue.Create(m) : null });
            };
            menu.Items.Add(item);
        }
        schedule.ContextMenu = menu;
        var delete = Ui.Button("删除", () =>
        {
            if (Selected() is { } e && Confirm("删除这条订阅？", "这条订阅的节点将停止参与连接，其他订阅会保留。"))
                S.Act("删除订阅", "subscription:delete", new JsonObject { ["id"] = e.At("id").Str() });
        });
        actions = Ui.Row(Ui.Button("编辑", () => Edit(Selected())), toggle, updateOne, schedule, delete);
        table.SelectionChanged += (_, _) => UpdateSelection();
        table.MouseDoubleClick += (_, _) => { if (Selected() is { } e && S.CanMutate) Edit(e); };
        view = Layout(
            Ui.Header("订阅", "沿用已保存的订阅与节点，更新失败时保留上次可用内容"),
            Ui.Bar(summary, add, updateAll),
            table, actions, error,
            Ui.Note("用量和到期日仅在订阅服务提供这些信息时显示。"));
    }

    IEnumerable<JsonNode> Entries => S.Status.At("subscription").At("entries").Items();

    JsonNode? Selected() => table.SelectedItem is SubRow row ? Entries.FirstOrDefault(e => e.At("id").Str() == row.Id) : null;

    public override void Update(bool trafficOnly)
    {
        if (trafficOnly) return;
        var rows = Entries.Select(e =>
        {
            var url = e.At("url").Str() ?? "";
            var host = Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Host.Length > 0 ? uri.Host : "已保存的订阅";
            var enabled = e.At("enabled").Bool() == true;
            var state = enabled ? (e.At("status").Str() == "ready" ? "可用" : "待更新") : "已停用";
            var mode = e.At("updateIntervalMinutes").Num() is { } m ? $"每 {m:0} 分钟" : "手动 / 默认设置";
            return new SubRow(e.At("id").Str() ?? "", e.At("name").Str() ?? "", host, state,
                $"{e.At("nodeCount").Num() ?? 0:0}", Ui.Date(e.At("updatedAt").Str()), mode);
        }).ToList();
        Ui.Fill(table, rows, r => r.Id);
        summary.Text = $"{rows.Count} 条订阅 · {S.Status.At("subscription").At("nodeCount").Num() ?? 0:0} 个节点";
        add.IsEnabled = updateAll.IsEnabled = S.CanMutate;
        UpdateSelection();
    }

    void UpdateSelection()
    {
        var entry = Selected();
        actions.IsEnabled = entry is not null && S.CanMutate;
        var enabled = entry.At("enabled").Bool() == true;
        toggle.Content = enabled ? "停用" : "启用";
        updateOne.IsEnabled = enabled;
        error.Text = entry is null ? "选择一条订阅进行管理" : entry.At("lastError").Str() ?? "";
        Ui.Tone(error, entry is null ? "muted" : "warn");
    }

    void Edit(JsonNode? entry)
    {
        var name = new TextBox { Text = entry.At("name").Str() ?? "", MinHeight = 32 };
        var url = new TextBox { Text = entry.At("url").Str() ?? "", MinHeight = 32 };
        var hint = Ui.Text("订阅链接只保存在本机，更新时交给 VPN 核心读取。", 13, secondary: true, wrap: true);
        var body = Ui.Stack(10, Ui.Text("名称", 13, secondary: true), name, Ui.Text("订阅 URL", 13, secondary: true), url, hint);
        bool Valid()
        {
            var ok = Uri.TryCreate(url.Text.Trim(), UriKind.Absolute, out var uri) && uri.Host.Length > 0;
            if (!ok) { hint.Text = "请输入完整的订阅 URL（以 http:// 或 https:// 开头）。"; Ui.Tone(hint, "warn"); }
            return ok;
        }
        if (!Dialog.Show(entry is null ? "添加订阅" : "编辑订阅", body, validate: Valid)) return;
        S.Act("保存订阅", "native:save-subscription", new JsonObject
        {
            ["name"] = name.Text.Trim(),
            ["url"] = url.Text.Trim(),
            ["id"] = entry.At("id").Str() ?? "",
        });
    }
}

public sealed record NodeRow(string Id, string Mark, string Name, string Meta, string Location, string Risk, string Latency, string LatencyLabel, string CheckedAt, string Source, string Fav);

public sealed class NodesPage : PageBase
{
    readonly Grid view;
    readonly TextBlock subtitle, count = Ui.Text("", 13, secondary: true), batch = Ui.Text("", 13, secondary: true);
    readonly TextBox search = Ui.Input(200);
    readonly ComboBox subscription = new() { Width = 142, MinHeight = 32 };
    readonly ComboBox qualityFilter = new() { Width = 110, MinHeight = 30, ItemsSource = new[] { "全部状态", "可用", "异常", "待测" }, SelectedIndex = 0 };
    readonly ComboBox order = new() { Width = 120, MinHeight = 30, ItemsSource = new[] { "默认排序", "延迟优先", "先看异常" }, SelectedIndex = 0 };
    readonly CheckBox favoritesOnly = new() { Content = "仅收藏", VerticalAlignment = VerticalAlignment.Center };
    readonly ListView table = Ui.Table(SelectionMode.Extended,
        ("", "Mark", 22), ("节点 / 订阅", "Name", 260), ("连接质量", "Latency", 116), ("最近测速", "CheckedAt", 96),
        ("位置", "Location", 102), ("IP 风险", "Risk", 74), ("收藏", "Fav", 38));
    readonly Button select, favorite, speedSelected, speedAll, recommended, udp, cancel;
    readonly Dictionary<string, JsonNode> byId = [];
    List<JsonNode> filtered = [];
    bool syncing;
    public override FrameworkElement View => view;

    public NodesPage(Store store) : base(store)
    {
        if (table.View is GridView columns) {
            columns.Columns[1].DisplayMemberBinding = null; columns.Columns[1].CellTemplate = TwoLine("Name", "Meta");
            columns.Columns[2].DisplayMemberBinding = null; columns.Columns[2].CellTemplate = TwoLine("Latency", "LatencyLabel");
            columns.Columns[3].DisplayMemberBinding = null; columns.Columns[3].CellTemplate = TwoLine("CheckedAt", "Source");
        }
        qualityFilter.SelectionChanged += (_, _) => Update(false);
        order.SelectionChanged += (_, _) => Update(false);
        search.TextChanged += (_, _) => Update(false);
        subscription.SelectionChanged += (_, _) => { if (!syncing) Update(false); };
        favoritesOnly.Click += (_, _) => Update(false);
        table.SelectionChanged += (_, _) => UpdateButtons();
        table.MouseDoubleClick += (_, e) =>
        {
            if (e.ChangedButton == MouseButton.Left && SelectedNodes() is [var node] && S.CanMutate) S.Select(node);
        };
        select = Ui.Button("设为当前出口", () => { if (SelectedNodes() is [var node]) S.Select(node); }, accent: true);
        favorite = Ui.Button("收藏", () => { if (SelectedNodes() is [var node]) S.ToggleFavorite(node); });
        speedSelected = Ui.Button("测速所选", () => Speed(SelectedNodes()));
        speedAll = Ui.Button("测速列表", () => Speed(filtered));
        recommended = Ui.Button("多站点复测", () =>
        {
            if (SelectedNodes() is [var node] && node.At("identityKey").Str() is { } key)
                S.Act("推荐测速", "nodes:test-recommended", new JsonObject { ["identityKey"] = key });
        });
        udp = Ui.Button("UDP 探测", () =>
            S.Act("启动 UDP 探测", "nodes:start-udp-batch", new JsonObject { ["nodeNames"] = Names(SelectedNodes()) }));
        cancel = Ui.Button("取消测速", S.CancelNodeSpeed);
        view = Layout(
            Ui.Header("节点", "", out _, out subtitle),
            Ui.Stack(10, Wrap(Ui.Field("搜索", search), subscription, favoritesOnly), Ui.Bar(count, qualityFilter, order)),
            table,
            Ui.Bar(batch),
            Wrap(select, speedSelected, speedAll, favorite, recommended, udp, cancel),
            Ui.Note("按住 Ctrl 或 Shift 多选；双击节点设为当前出口。国家和地区由节点名称识别，风险显示上次实际出口检测结果。"));
        view.Loaded += async (_, _) => await S.RefreshNodes();
    }

    static WrapPanel Wrap(params UIElement[] items) {
        var panel = new WrapPanel();
        foreach (var item in items) { if (item is FrameworkElement element) element.Margin = new Thickness(0, 0, 8, 8); panel.Children.Add(item); }
        return panel;
    }
    static DataTemplate TwoLine(string first, string second) {
        var panel = new FrameworkElementFactory(typeof(StackPanel));
        panel.SetValue(FrameworkElement.MarginProperty, new Thickness(0, 6, 0, 6));
        var title = new FrameworkElementFactory(typeof(TextBlock));
        title.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding(first));
        title.SetValue(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis);
        title.SetBinding(FrameworkElement.ToolTipProperty, new System.Windows.Data.Binding(first));
        if (first is "Latency" or "CheckedAt") title.SetValue(TextBlock.FontFamilyProperty, new System.Windows.Media.FontFamily("Consolas"));
        title.SetValue(TextBlock.FontSizeProperty, 13.0); title.SetValue(TextBlock.FontWeightProperty, FontWeights.Medium);
        var detail = new FrameworkElementFactory(typeof(TextBlock));
        detail.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding(second));
        detail.SetValue(TextBlock.FontSizeProperty, 10.0); detail.SetValue(UIElement.OpacityProperty, 0.7);
        detail.SetValue(FrameworkElement.MarginProperty, new Thickness(0, 4, 0, 0));
        panel.AppendChild(title); panel.AppendChild(detail);
        return new DataTemplate { VisualTree = panel };
    }
    static string Id(JsonNode node) => node.At("identityKey").Str() ?? node.At("name").Str() ?? "";
    static JsonArray Names(IEnumerable<JsonNode> nodes) => J.Array(nodes.Select(n => n.At("name").Str() ?? ""));
    void Speed(IEnumerable<JsonNode> nodes) => S.StartNodeSpeed(nodes);

    List<JsonNode> SelectedNodes() =>
        table.SelectedItems.OfType<NodeRow>().Select(r => byId.GetValueOrDefault(r.Id)).Where(n => n is not null).Select(n => n!).ToList();

    public override void Update(bool trafficOnly)
    {
        if (trafficOnly) return;
        SyncSubscriptions();
        subtitle.Text = S.NodesError is { } error ? $"节点读取失败：{error}" : $"当前出口：{S.DisplaySelectedProxy}";
        var subscriptionId = (subscription.SelectedItem as ComboBoxItem)?.Tag as string ?? "all";
        var favorites = S.Favorites;
        var query = search.Text.Trim();
        filtered = S.Nodes.Where(n =>
        {
            var name = n.At("name").Str() ?? "";
            var location = n.At("location");
            return (n.At("identityKey").Str() is not null || name == "DIRECT")
                && (subscriptionId == "all" || n.At("subscriptionId").Str() == subscriptionId)
                && (qualityFilter.SelectedIndex == 0 || (qualityFilter.SelectedIndex == 1 && n.At("available").Bool() == true) || (qualityFilter.SelectedIndex == 2 && n.At("available").Bool() == false) || (qualityFilter.SelectedIndex == 3 && n.At("available").Bool() is null))
                && (favoritesOnly.IsChecked != true || favorites.Contains(name))
                && (query.Length == 0 || $"{name} {n.At("subscriptionName").Str()} {location.At("country").Str()} {location.At("city").Str()}"
                    .Contains(query, StringComparison.OrdinalIgnoreCase));
        }).ToList();
        if (order.SelectedIndex == 1) filtered = filtered.OrderBy(n => n.At("available").Bool() == true && n.At("delay").Num() is { } d && d > 0 ? d : double.MaxValue).ThenBy(n => n.At("name").Str()).ToList();
        if (order.SelectedIndex == 2) filtered = filtered.OrderBy(n => n.At("available").Bool() == false ? 0 : 1).ThenBy(n => n.At("name").Str()).ToList();
        byId.Clear();
        foreach (var node in filtered) byId[Id(node)] = node;
        var rows = filtered.Select(n =>
        {
            var name = n.At("name").Str() ?? "";
            var provider = n.At("identityKey").Str() is not null;
            var ambiguous = n.At("identityAmbiguous").Bool() == true;
            var status = n.At("latencyStatus").Str();
            var label = status switch { "timeout" => "连接超时", "failed" or "unreachable" => "暂未连通", "stale" => "结果已过期", "unstable" => "响应波动", "available" => "可用", _ => "尚未测速" };
            var active = S.SpeedTestingNode == name;
            var latency = active ? "检测中…" : n.At("delay").Num() is { } delay && delay > 0 ? $"{delay:0} ms" : status == "timeout" ? "超时" : n.At("available").Bool() == false ? "未连通" : "待测速";
            var stamp = n.At("latencyCheckedAt").Str();
            var clock = DateTimeOffset.TryParse(stamp, out var tested) ? tested.ToLocalTime().ToString("HH:mm:ss") : "—";
            var risk = ambiguous ? null : S.Risks.FirstOrDefault(r => r.At("nodeName").Str() == name);
            return new NodeRow(Id(n), n.At("selected").Bool() == true ? "✓" : "", name,
                $"{(n.At("type").Str() ?? "").ToUpperInvariant()} · {n.At("subscriptionName").Str() ?? "内置出口"}",
                string.Join(" · ", new[] { n.At("location").At("country").Str(), n.At("location").At("city").Str() }.Where(s => !string.IsNullOrEmpty(s))),
                RiskLabel(risk), latency, active ? "正在等待响应" : ambiguous ? "同名冲突" : label, clock,
                stamp is null ? "尚无记录" : n.At("latencySource").Str() == "engine" ? "自动探测" : "手动测速",
                !provider ? "" : favorites.Contains(name) ? "★" : "☆");
        }).ToList();
        Ui.Fill(table, rows, r => r.Id);
        count.Text = $"{rows.Count} 项 · {filtered.Count(n => n.At("available").Bool() == true)} 可用 · {filtered.Count(n => n.At("available").Bool() == false)} 异常";
        batch.Text = S.BatchMessage ?? "";
        UpdateButtons();
    }

    void SyncSubscriptions()
    {
        var entries = S.Status.At("subscription").At("entries").Items()
            .Select(e => (Id: e.At("id").Str() ?? "", Name: e.At("name").Str() ?? "")).ToList();
        var current = subscription.Items.OfType<ComboBoxItem>().Skip(1).Select(i => ((string)i.Tag, (string)i.Content)).ToList();
        if (subscription.Items.Count > 0 && current.SequenceEqual(entries)) return;
        syncing = true;
        var keep = (subscription.SelectedItem as ComboBoxItem)?.Tag as string ?? "all";
        subscription.Items.Clear();
        subscription.Items.Add(new ComboBoxItem { Content = "全部订阅", Tag = "all" });
        foreach (var (id, name) in entries) subscription.Items.Add(new ComboBoxItem { Content = name, Tag = id });
        subscription.SelectedItem = subscription.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == keep) ?? subscription.Items[0];
        syncing = false;
    }

    void UpdateButtons()
    {
        var selected = SelectedNodes();
        var ready = S.CanMutate;
        var live = ready && S.Running && !S.SpeedBatchRunning;
        select.IsEnabled = ready && selected.Count == 1;
        favorite.IsEnabled = ready && selected is [var one] && one.At("identityKey").Str() is not null;
        speedSelected.IsEnabled = live && selected.Count > 0;
        speedAll.IsEnabled = live && filtered.Count > 0;
        recommended.IsEnabled = live && selected is [var single] && single.At("identityKey").Str() is not null;
        udp.IsEnabled = live && selected.Count > 0;
        cancel.IsEnabled = S.SpeedBatchRunning;
    }
}

public sealed record MemberRow(string Id, string Name, string State, string Delay, string Current);

public sealed class GroupsPage : PageBase
{
    readonly Grid view;
    readonly ListBox list = new() { MinWidth = 220 };
    readonly TextBlock count = Ui.Text("", 13, secondary: true), title = Ui.Text("", 20, bold: true), note = Ui.Note();
    readonly ListView members = Ui.Table(SelectionMode.Single, ("成员", "Name", 320), ("状态", "State", 130), ("延迟", "Delay", 90), ("当前", "Current", 60));
    readonly Button add, edit, use, speed, delete;
    readonly Grid detail;
    readonly TextBlock empty = Ui.Text("选择节点组，已有的组、成员和测速结果会在这里显示", 14, secondary: true, wrap: true);
    string signature = "";
    bool syncing;
    public override FrameworkElement View => view;

    public GroupsPage(Store store) : base(store)
    {
        add = Ui.Button("新增节点组", () => Edit(null), accent: true);
        edit = Ui.Button("编辑", () => { if (Selected() is { } g) Edit(g.Id); });
        use = Ui.Button("使用选中节点", () => { if (SelectedNode() is { } node) S.Select(node); }, accent: true);
        speed = Ui.Button("测速此组", () =>
        {
            if (Selected() is { } g)
                S.Act("启动组测速", "nodes:start-speed-batch",
                    new JsonObject { ["nodeNames"] = J.Array(g.Members.Where(m => m.Issue is null).Select(m => m.Name)) });
        });
        delete = Ui.Button("删除组", () =>
        {
            if (Selected() is { } g && Confirm("删除节点组？", $"将删除“{g.Name}”，节点本身不受影响。"))
                S.SaveGroups(S.Settings.At("nodeGroups").Items().Where(x => x.At("id").Str() != g.Id));
        });
        list.SelectionChanged += (_, _) => { if (!syncing) UpdateDetail(); };
        members.SelectionChanged += (_, _) => UpdateButtons();

        detail = Rows(
            Ui.Bar(edit, Ui.Stack(4, title, Ui.Text("选择一个成员，固定使用这个节点。", 13, secondary: true))),
            members,
            Ui.Row(use, speed, delete),
            note);
        var right = new Grid { Margin = new Thickness(20, 0, 0, 0) };
        right.Children.Add(detail);
        right.Children.Add(empty);
        var split = new Grid { Tag = "fill" };
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(240) });
        split.ColumnDefinitions.Add(new ColumnDefinition());
        split.Children.Add(list);
        Grid.SetColumn(right, 1);
        split.Children.Add(right);
        view = Layout(Ui.Header("节点组", "整理节点与批量测速，选择具体节点作为出口"), Ui.Bar(count, add), split);
    }

    GroupInfo? Selected() => list.SelectedItem is ListBoxItem { Tag: string id } ? S.Groups.FirstOrDefault(g => g.Id == id) : null;

    JsonNode? SelectedNode()
    {
        if (members.SelectedItem is not MemberRow row || Selected()?.Members.FirstOrDefault(m => m.Id == row.Id)?.IdentityKey is not { } key) return null;
        return S.ProviderNodes.FirstOrDefault(n => n.At("identityKey").Str() == key && n.At("identityAmbiguous").Bool() != true);
    }

    public override void Update(bool trafficOnly)
    {
        if (trafficOnly) return;
        count.Text = $"{S.Groups.Count} 个节点组";
        add.IsEnabled = S.CanMutate;
        var next = string.Join("\n", S.Groups.Select(g => $"{g.Id}|{g.Name}|{g.Members.Count}"));
        if (next != signature)
        {
            signature = next;
            syncing = true;
            var keep = (list.SelectedItem as ListBoxItem)?.Tag as string;
            list.Items.Clear();
            foreach (var g in S.Groups)
                list.Items.Add(new ListBoxItem
                {
                    Tag = g.Id,
                    Padding = new Thickness(10, 8, 10, 8),
                    Content = Ui.Stack(3, Ui.Text(g.Name, 15, bold: true),
                        Ui.Text($"{(g.IsSubscription ? "订阅自动维护" : "自定义分组")} · {g.Members.Count} 个成员", 12, secondary: true)),
                });
            list.SelectedItem = list.Items.OfType<ListBoxItem>().FirstOrDefault(i => (string)i.Tag == keep)
                ?? list.Items.OfType<ListBoxItem>().FirstOrDefault();
            syncing = false;
        }
        UpdateDetail();
    }

    void UpdateDetail()
    {
        var group = Selected();
        detail.Visibility = group is null ? Visibility.Collapsed : Visibility.Visible;
        empty.Visibility = group is null ? Visibility.Visible : Visibility.Collapsed;
        if (group is null) return;
        title.Text = group.Name;
        var rows = group.Members.Select(m => new MemberRow(m.Id, m.Name,
            m.Issue ?? m.Available switch { true => "可用", false => "失败", null => "未检测" },
            Ui.Ms(m.Delay), m.Name == S.SelectedProxy ? "✓" : "")).ToList();
        Ui.Fill(members, rows, r => r.Id);
        delete.Visibility = group.IsSubscription ? Visibility.Collapsed : Visibility.Visible;
        note.Text = "连接固定使用选中的具体节点。" + (group.IsSubscription ? "此组成员随订阅更新。" : "");
        UpdateButtons();
    }

    void UpdateButtons()
    {
        var group = Selected();
        edit.IsEnabled = S.CanMutate && group is not null;
        use.IsEnabled = S.CanMutate && SelectedNode() is not null;
        speed.IsEnabled = S.CanMutate && S.Running && group is not null;
        delete.IsEnabled = S.CanMutate && group is { Selected: false };
    }

    void Edit(string? id)
    {
        var group = id is null
            ? new JsonObject { ["id"] = Guid.NewGuid().ToString().ToUpperInvariant(), ["name"] = "", ["nodeNames"] = new JsonArray(), ["members"] = new JsonArray(), ["strategy"] = "manual" }
            : S.Settings.At("nodeGroups").Items().FirstOrDefault(g => g.At("id").Str() == id)?.DeepClone() as JsonObject;
        if (group is null) return;
        var groupId = group.At("id").Str() ?? "";
        var managed = groupId.StartsWith("subscription:");
        var subscription = managed ? groupId["subscription:".Length..] : null;
        var nodes = S.ProviderNodes.Where(n => !managed || n.At("subscriptionId").Str() == subscription).ToList();
        string Key(JsonNode n) => n.At("identityKey").Str() ?? "";
        var previous = group.At("members") is JsonArray
            ? group.At("members").Items().Select(m => (Key: m.At("identityKey").Str(), Name: m.At("lastKnownName").Str() ?? "")).ToList()
            : null;
        var chosen = managed ? nodes.Select(Key).ToHashSet()
            : previous is not null ? previous.Where(m => m.Key is not null).Select(m => m.Key!).ToHashSet()
            : nodes.Where(n => group.At("nodeNames").Strings().Contains(n.At("name").Str())).Select(Key).ToHashSet();

        var name = new TextBox { Text = group.At("name").Str() ?? "", MinHeight = 32 };
        var filter = new TextBox { MinHeight = 32 };
        var picker = new ListBox { Height = 300 };
        var summary = Ui.Note();
        void Count() => summary.Text = managed ? "成员随订阅更新。" : $"已选 {chosen.Count} 个成员；原成员顺序会保留，新成员追加到末尾。";
        foreach (var node in nodes)
        {
            var key = Key(node);
            var box = new CheckBox
            {
                Content = node.At("name").Str(),
                Tag = node.At("name").Str() ?? "",
                IsChecked = chosen.Contains(key),
                IsEnabled = !managed && node.At("identityAmbiguous").Bool() != true,
            };
            box.Click += (_, _) => { if (box.IsChecked == true) chosen.Add(key); else chosen.Remove(key); Count(); };
            picker.Items.Add(box);
        }
        filter.TextChanged += (_, _) =>
        {
            foreach (var box in picker.Items.OfType<CheckBox>())
                box.Visibility = ((string)box.Tag).Contains(filter.Text.Trim(), StringComparison.OrdinalIgnoreCase) ? Visibility.Visible : Visibility.Collapsed;
        };
        Count();
        var body = Ui.Stack(10, Ui.Text("组名称", 13, secondary: true), name, Ui.Text("搜索成员", 13, secondary: true), filter, picker, summary);
        bool Valid() => name.Text.Trim().Length > 0 && chosen.Count > 0;
        if (!Dialog.Show(id is null ? "新增节点组" : "编辑节点组", body, validate: Valid, width: 560)) return;

        var kept = (previous ?? []).Where(m => m.Key is not null && chosen.Contains(m.Key)).ToList();
        var oldKeys = kept.Select(m => m.Key!).ToHashSet();
        var all = kept.Concat(nodes.Where(n => chosen.Contains(Key(n)) && !oldKeys.Contains(Key(n)))
            .Select(n => (Key: (string?)Key(n), Name: n.At("name").Str() ?? ""))).ToList();
        group["name"] = name.Text.Trim();
        group["members"] = new JsonArray(all.Select(m => (JsonNode?)new JsonObject { ["identityKey"] = m.Key, ["lastKnownName"] = m.Name }).ToArray());
        group["nodeNames"] = J.Array(all.Select(m => m.Name));
        if (group.At("preferredIdentityKey").Str() is { } preferred && !chosen.Contains(preferred)) group.Remove("preferredIdentityKey");

        var groups = S.Settings.At("nodeGroups").Items().ToList();
        var index = groups.FindIndex(g => g.At("id").Str() == groupId);
        if (index >= 0) groups[index] = group; else groups.Add(group);
        S.SaveGroups(groups);
    }
}

public sealed record RuleRow(string Rule, string Target)
{
    public string Id => $"{Target}:{Rule}";
    public string Address => Rule.Split(',', 2).Last();
    public string Kind => Rule.Split(',', 2).First();
    public string Match => Kind switch { "DOMAIN" => "仅此域名", "DOMAIN-SUFFIX" => "域名及子域名", "DOMAIN-KEYWORD" => "域名包含关键词", "IP-CIDR" or "IP-CIDR6" => "IP 地址或网段", "GEOSITE" => "Geo 分类", _ => "高级规则" };
    public string Exit => Target == "direct" ? "直连" : "走 VPN";
}

public sealed class RoutingPage : PageBase
{
    readonly Grid view;
    readonly TextBox search = Ui.Input(260), target = new() { MinHeight = 32, MinWidth = 360 };
    readonly ComboBox unknown = new() { Width = 150, MinHeight = 32 }, outletFilter = new() { Width = 100, MinHeight = 32 };
    readonly ComboBox geoFallback = new() { Width = 210, MinHeight = 32 };
    readonly ListView table = Ui.Table(SelectionMode.Single, ("地址", "Address", 350), ("匹配范围", "Match", 160), ("出口", "Exit", 110));
    readonly TextBlock count = Ui.Text("", 13, secondary: true), result = Ui.Text("", 14, wrap: true);
    readonly Button add, editRule, deleteRule, diagnose;
    bool syncing, checking;
    public override FrameworkElement View => view;

    public RoutingPage(Store store) : base(store)
    {
        search.TextChanged += (_, _) => Update(false);
        add = Ui.Button("添加规则", () => Edit(null), accent: true);
        outletFilter.Items.Add(new ComboBoxItem { Content = "全部出口", Tag = "all" });
        outletFilter.Items.Add(new ComboBoxItem { Content = "走 VPN", Tag = "vpn" });
        outletFilter.Items.Add(new ComboBoxItem { Content = "直连", Tag = "direct" });
        outletFilter.SelectedIndex = 0;
        outletFilter.SelectionChanged += (_, _) => Update(false);
        unknown.Items.Add(new ComboBoxItem { Content = "默认直连", Tag = "direct" });
        unknown.Items.Add(new ComboBoxItem { Content = "默认 VPN", Tag = "vpn" });
        unknown.SelectionChanged += (_, _) =>
        {
            if (syncing || unknown.SelectedItem is not ComboBoxItem { Tag: string value }) return;
            if (value != (S.Settings.At("unknownTraffic").Str() ?? "direct"))
                S.Act("更新默认策略", "routing:update", new JsonObject { ["unknownTraffic"] = value });
        };
        geoFallback.Items.Add(new ComboBoxItem { Content = "国内名单直连，其余 VPN", Tag = "cn-direct-else-vpn" });
        geoFallback.Items.Add(new ComboBoxItem { Content = "跟随默认策略", Tag = "follow-default" });
        geoFallback.Items.Add(new ComboBoxItem { Content = "拒绝启动", Tag = "block" });
        geoFallback.ToolTip = "分流数据可用时使用完整的国内外规则；缺失时按此策略连接。国内直连仅覆盖内置域名名单。";
        geoFallback.SelectionChanged += (_, _) =>
        {
            if (syncing || geoFallback.SelectedItem is not ComboBoxItem { Tag: string value }) return;
            if (value != (S.Settings.At("geoFallback").Str() ?? "cn-direct-else-vpn"))
                S.Act("更新分流数据缺失策略", "routing:update", new JsonObject { ["geoFallback"] = value });
        };
        editRule = Ui.Button("编辑规则", () => { if (table.SelectedItem is RuleRow row) Edit(row); });
        deleteRule = Ui.Button("删除规则", () =>
        {
            if (table.SelectedItem is RuleRow row && Confirm("删除规则？", row.Rule))
                S.Act("删除规则", "routing:delete-rule", new JsonObject { ["rule"] = row.Rule, ["target"] = row.Target });
        });
        table.SelectionChanged += (_, _) => UpdateButtons();
        table.MouseDoubleClick += (_, _) => { if (table.SelectedItem is RuleRow row && S.CanMutate) Edit(row); };
        diagnose = Ui.Button("检查匹配", Diagnose);
        target.TextChanged += (_, _) => UpdateButtons();
        view = Layout(
            Ui.Header("分流规则", "为指定域名、IP 或网段选择 VPN 或直连"),
            Ui.Row(Ui.Field("搜索", search), outletFilter, add),
            Ui.Row(Ui.Field("未命中策略", unknown), Ui.Field("分流数据缺失时", geoFallback)),
            table,
            Ui.Bar(count, editRule, deleteRule),
            new Separator(),
            Ui.Row(Ui.Field("检查地址", target), diagnose),
            result,
            Ui.Note("自定义规则优先于国内外自动分流，重叠时直连优先。局域网、Tailscale 与私有网络按接入设置处理；匹配检查不检测网络是否连通。"));
        unknown.ToolTip = "自定义规则和国内外自动分流都未命中时，才使用此策略。";
    }

    public override void Update(bool trafficOnly)
    {
        if (trafficOnly) return;
        var vpn = S.Settings.At("vpnDomainRules").Strings().ToList();
        var direct = S.Settings.At("directDomainRules").Strings().ToList();
        var all = direct.Select(r => new RuleRow(r, "direct")).Concat(vpn.Select(r => new RuleRow(r, "vpn")));
        var query = search.Text.Trim();
        var filter = (outletFilter.SelectedItem as ComboBoxItem)?.Tag as string ?? "all";
        var rows = all.Where(r => (filter == "all" || r.Target == filter) && (query.Length == 0 || r.Rule.Contains(query, StringComparison.OrdinalIgnoreCase) || r.Exit.Contains(query, StringComparison.OrdinalIgnoreCase))).ToList();
        Ui.Fill(table, rows, r => r.Id);
        count.Text = $"VPN {vpn.Count} 条 · 直连 {direct.Count} 条";
        syncing = true;
        var mode = S.Settings.At("unknownTraffic").Str() ?? "direct";
        unknown.SelectedItem = unknown.Items.OfType<ComboBoxItem>().First(i => (string)i.Tag == (mode == "vpn" ? "vpn" : "direct"));
        var geoMode = S.Settings.At("geoFallback").Str() ?? "cn-direct-else-vpn";
        geoFallback.SelectedItem = geoFallback.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == geoMode)
            ?? geoFallback.Items[0];
        syncing = false;
        add.IsEnabled = unknown.IsEnabled = geoFallback.IsEnabled = S.CanMutate;
        UpdateButtons();
    }

    void UpdateButtons()
    {
        editRule.IsEnabled = deleteRule.IsEnabled = S.CanMutate && table.SelectedItem is RuleRow;
        diagnose.IsEnabled = S.CanMutate && !checking && target.Text.Trim().Length > 0;
        diagnose.Content = checking ? "检查中…" : "检查匹配";
    }

    void Edit(RuleRow? original)
    {
        var outlet = new ComboBox { MinHeight = 32, MinWidth = 160 };
        outlet.Items.Add(new ComboBoxItem { Content = "走 VPN · 当前节点或节点组", Tag = "vpn" });
        outlet.Items.Add(new ComboBoxItem { Content = "直连 · 本机网络", Tag = "direct" });
        outlet.SelectedIndex = original?.Target == "direct" ? 1 : 0;
        var kind = new ComboBox { MinHeight = 32, MinWidth = 200 };
        foreach (var (label, tag) in new[] { ("自动识别（推荐）", "auto"), ("域名及子域名", "DOMAIN-SUFFIX"), ("仅此域名", "DOMAIN"), ("域名包含关键词", "DOMAIN-KEYWORD"), ("IP 地址或网段", "ip"), ("高级规则", "raw") })
            kind.Items.Add(new ComboBoxItem { Content = label, Tag = tag });
        var initialKind = original is null ? "auto" : original.Kind.StartsWith("IP-CIDR") ? "ip" : original.Kind == "GEOSITE" ? "raw" : original.Kind;
        kind.SelectedItem = kind.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == initialKind) ?? kind.Items[0];
        var input = new TextBox { Text = original is null ? "" : initialKind == "raw" ? original.Rule : original.Address, MinHeight = 32 };
        var hint = Ui.Text("", 13, secondary: true, wrap: true);
        var preview = Ui.Text("填写后会显示匹配范围。", 13, wrap: true);
        var error = Ui.Text("", 13, wrap: true);
        error.Foreground = System.Windows.Media.Brushes.IndianRed;
        var generation = 0;
        JsonObject Payload() => new() { ["rule"] = input.Text.Trim(), ["kind"] = (string)((ComboBoxItem)kind.SelectedItem).Tag, ["target"] = (string)((ComboBoxItem)outlet.SelectedItem).Tag };
        void Hint()
        {
            hint.Text = ((ComboBoxItem)kind.SelectedItem).Tag switch
            {
                "DOMAIN-SUFFIX" => "填写 example.test，也会匹配 api.example.test 等子域名。",
                "DOMAIN" => "例如 api.example.test，只匹配这个域名，不包含子域名。",
                "DOMAIN-KEYWORD" => "例如 example，匹配域名中包含这个词的地址。",
                "ip" => "例如 192.0.2.8 或 192.0.2.0/24，也支持 IPv6。",
                "raw" => "例如 DOMAIN-SUFFIX,example.test，保留已有规则格式。",
                _ => "可填域名、IP、网段或完整网址；域名默认包含子域名，网址路径不参与分流。"
            };
        }
        async Task Validate()
        {
            var version = ++generation;
            error.Text = "";
            if (input.Text.Trim().Length == 0) { preview.Text = "填写后会显示匹配范围。"; return; }
            preview.Text = "正在检查地址…";
            await Task.Delay(250);
            if (version != generation) return;
            try
            {
                var normalized = await S.Core.Request("routing:normalize-rule", Payload());
                if (version == generation) preview.Text = $"{normalized.At("value").Str()} → {(((ComboBoxItem)outlet.SelectedItem).Tag as string == "direct" ? "直连" : "走 VPN")}";
            }
            catch (Exception e) { if (version == generation) { preview.Text = ""; error.Text = e.Message; } }
        }
        input.TextChanged += (_, _) => _ = Validate();
        kind.SelectionChanged += (_, _) => { Hint(); _ = Validate(); };
        outlet.SelectionChanged += (_, _) => _ = Validate();
        Hint(); _ = Validate();
        var body = Ui.Stack(12, Ui.Field("这些地址走哪里？", outlet), Ui.Field("匹配方式", kind), input, hint, preview, error,
            Ui.Note("每条规则填一个地址。相同规则改出口会替换原设置；不同范围重叠时直连优先。局域网、Tailscale 与私有网络仍按接入设置处理。"));
        Dialog.Show(original is null ? "添加分流规则" : "编辑分流规则", body, confirm: "保存规则", width: 570, submit: async () =>
        {
            try
            {
                var payload = Payload();
                if (original is not null) { payload["originalRule"] = original.Rule; payload["originalTarget"] = original.Target; }
                await S.SaveRoutingRule(payload, original is not null);
                result.Text = "";
                return true;
            }
            catch (Exception e) { error.Text = e.Message; return false; }
        });
        generation++;
    }

    async void Diagnose()
    {
        checking = true;
        UpdateButtons();
        try
        {
            var r = await S.Core.Request("routing:diagnose", new JsonObject { ["target"] = target.Text.Trim() });
            var matches = r.At("matchedRules").Strings().ToList();
            result.Text = $"{r.At("host").Str()}：{r.At("policy").Str()}\n{(matches.Count == 0 ? "未命中自定义规则；实际出口取决于自动分流与接入设置。" : "命中：" + string.Join("；", matches))}";
        }
        catch (Exception e) { result.Text = e.Message; }
        finally
        {
            checking = false;
            UpdateButtons();
        }
    }
}
