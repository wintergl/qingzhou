using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace Qingzhou;

public sealed record ResourceRowView(string Id, string Name, string Address, string Network, string Ports);

public sealed record AuthOption(string Domain, string Name);

/// Company VPN: login, tunnel and resource takeover, each controlled separately.
public sealed class CompanyPage : PageBase
{
    static readonly (string Key, string Title)[] StepTitles =
        [("probe", "入口证书"), ("login", "账号认证"), ("resources", "授权资源"), ("tunnel", "私有网络隧道"), ("routing", "资源接管")];
    readonly CompanyStore C;
    readonly Grid view;
    readonly TextBlock pill = Ui.Text("", 13, bold: true);
    readonly TextBlock[] steps = StepTitles.Select(_ => Ui.Text("", 12)).ToArray();
    readonly TextBox origin = Box(), username = Box(), search = Box();
    readonly PasswordBox password = new() { MinHeight = 32, VerticalContentAlignment = VerticalAlignment.Center };
    readonly ComboBox domain = new() { MinHeight = 32, DisplayMemberPath = "Name" };
    readonly TextBlock certText = Ui.Text("", 12, wrap: true), sessionUser = Ui.Text("", 18, bold: true);
    readonly TextBlock credentialNote = Ui.Note(), takeoverNote = Ui.Note(), connectionNote = Ui.Note();
    readonly TextBlock internetText = Ui.Text("", 12, secondary: true), resourceCount = Ui.Text("", 12, secondary: true);
    readonly TextBlock resourceFooter = Ui.Text("", 11, secondary: true), error = Ui.Text("", 13);
    readonly CheckBox remember = new() { Content = "记住账号和密码" }, takeover = new() { Content = "接管授权资源" };
    readonly CheckBox connection = new() { Content = "私有网络", FontWeight = FontWeights.SemiBold };
    readonly Button detect, viewCert, refresh, logout, login, cancel, forget, verify, internet;
    readonly StackPanel certRow, loggedIn, loggedOut, emptyResources, searchField, domainField;
    readonly DockPanel errorBar;
    readonly Border passwordChangeGuidance;
    readonly Button openPasswordChangeEntry;
    readonly ListView table = Ui.Table(SelectionMode.Single, ("应用", "Name", 140), ("授权地址", "Address", 220), ("协议", "Network", 60), ("端口", "Ports", 110));
    bool updating;
    public override FrameworkElement View => view;

    public CompanyPage(Store store, CompanyStore company) : base(store)
    {
        C = company;

        var details = Ui.Button("证书与连接详情", ShowDetails);
        var header = Ui.Bar(Ui.Row(pill, details), Ui.Header("私有网络", "登录、连接与资源接管，可以分别控制"));
        var stepGrid = new UniformGrid { Columns = StepTitles.Length };
        foreach (var step in steps) stepGrid.Children.Add(step);
        openPasswordChangeEntry = Ui.Button("打开接入网关", () => { if (C.PasswordChangeEntryUrl is { } url) OpenInBrowser(url); });
        passwordChangeGuidance = Ui.Card(Ui.Stack(8,
            Ui.Warning("需要修改接入密码"), Ui.Note(CompanyStore.PasswordChangeGuidance),
            Ui.Row(openPasswordChangeEntry, Ui.Button("已改好，输入新密码", () =>
            {
                C.PrepareAfterPasswordChange(); password.Focus();
            }))), 12);

        origin.TextChanged += (_, _) => { if (!updating) C.Origin = origin.Text; };
        username.TextChanged += (_, _) => { if (!updating) { C.Username = username.Text; S.Notify(); } };
        password.PasswordChanged += (_, _) => { if (!updating) { C.Password = password.Password; S.Notify(); } };
        domain.SelectionChanged += (_, _) => { if (!updating && domain.SelectedItem is AuthOption o) { C.SelectedDomain = o.Domain; S.Notify(); } };
        remember.Click += (_, _) => C.SetRememberCredentials(remember.IsChecked == true);
        takeover.Click += (_, _) => C.SetTakeover(takeover.IsChecked == true);
        connection.Click += (_, _) => { if (C.ConnectionEnabled) C.DisconnectTunnel(); else C.ConnectTunnel(); };
        search.TextChanged += (_, _) => { if (!updating) Update(false); };

        detect = Ui.Button("重新检测入口", C.DetectEntry);
        viewCert = Ui.Button("查看", ShowDetails);
        certText.MaxWidth = 180;
        certRow = Ui.Row(certText, viewCert);
        refresh = Ui.Button("刷新授权资源", C.RefreshResources);
        logout = Ui.Button("退出接入账号", C.EndTest);
        login = Ui.Button("登录并获取授权", C.Login, accent: true);
        cancel = Ui.Button("取消本次连接", C.EndTest);
        forget = Ui.Button("忘记", () => C.ForgetCredentials());
        verify = Ui.Button("验证", ShowVerification);
        internet = Ui.Button("检查 GPT 网络", C.VerifyInternet);
        domainField = Labeled("认证方式", domain);
        searchField = Labeled("搜索应用、地址或端口", search);
        var passed = Ui.Text("✓ 账号认证已通过", 13, bold: true);
        Ui.Tone(passed, "good");
        loggedIn = Ui.Stack(10, passed, sessionUser, Ui.Row(refresh, logout));
        loggedOut = Ui.Stack(10, Labeled("接入账号", username), Labeled("接入密码", password));

        var account = Ui.Card(Scroll(Ui.Stack(12,
            Ui.Text("接入账号", 16, bold: true),
            Labeled("HTTPS 接入网关", origin),
            Ui.Row(detect),
            certRow,
            domainField,
            loggedIn,
            loggedOut,
            remember,
            Ui.Bar(forget, Ui.Text("Windows 数据保护加密保存", 11, secondary: true)),
            credentialNote,
            Ui.Row(login, cancel))), 18);
        account.Width = 300;

        var business = Ui.Card(Ui.Stack(10,
            Ui.Bar(takeover, Ui.Text("私有网络连接", 16, bold: true)),
            takeoverNote,
            Ui.Bar(verify, connection),
            connectionNote,
            Ui.Row(internet, internetText)), 18);

        emptyResources = Ui.Stack(10,
            Ui.Text("登录后显示授权资源", 18, bold: true),
            Ui.Text("应用、网段、域名与允许端口会显示在此。", 14, secondary: true, wrap: true));
        var resources = Ui.Card(Rows(
            Ui.Bar(resourceCount, Ui.Text("授权资源", 16, bold: true)),
            searchField,
            table,
            resourceFooter,
            emptyResources), 18);
        resources.Tag = "fill";
        var right = Rows(business, resources);
        right.Margin = new Thickness(16, 0, 0, 0);
        var columns = new Grid { Tag = "fill" };
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        columns.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(right, 1);
        columns.Children.Add(account);
        columns.Children.Add(right);

        Ui.Tone(error, "bad");
        errorBar = Ui.Bar(Ui.Button("详情", ShowDetails), error);
        view = Layout(header, stepGrid, passwordChangeGuidance, columns, errorBar);
        C.ChallengeRequested += challenge => view.Dispatcher.InvokeAsync(() => ShowChallenge(challenge));
    }

    static TextBox Box() => new() { MinHeight = 32, VerticalContentAlignment = VerticalAlignment.Center };

    static StackPanel Labeled(string label, Control input)
    {
        input.HorizontalAlignment = HorizontalAlignment.Stretch;
        return Ui.Stack(4, Ui.Text(label, 12, secondary: true), input);
    }

    static void Visible(UIElement element, bool visible) => element.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;

    /// The app runs elevated for the TUN; handing the URL to the existing
    /// explorer keeps the browser at the user's normal privilege level.
    static void OpenInBrowser(Uri url)
    {
        var info = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
        info.ArgumentList.Add(url.AbsoluteUri);
        try { Process.Start(info); } catch { }
    }

    public override void Shown() => C.StartOnce();

    public override void Update(bool trafficOnly)
    {
        if (trafficOnly) return;
        updating = true;
        try
        {
            pill.Text = C.StatusText;
            var needsPasswordChange = C.PasswordChangeRequired || C.Challenge.At("kind").Str() == "password_change";
            Ui.Tone(pill, C.ConnectionReady ? "good" : needsPasswordChange ? "warn" : "muted");
            for (var i = 0; i < StepTitles.Length; i++)
            {
                var (key, title) = StepTitles[i];
                var phase = C.Phases[key];
                var changePassword = key == "login" && needsPasswordChange;
                var mark = changePassword ? "!" : phase switch { Phase.Passed => "✓", Phase.Failed => "✕", _ => $"{i + 1}." };
                steps[i].Text = $"{mark} {title} · {(changePassword ? "需修改密码" : key == "routing" && !C.TakeoverEnabled ? "未接管" : phase.Title())}";
                Ui.Tone(steps[i], changePassword ? "warn" : phase switch { Phase.Passed => "good", Phase.Failed => "bad", Phase.Running => null, _ => "muted" });
            }
            Visible(passwordChangeGuidance, C.PasswordChangeRequired);
            Visible(openPasswordChangeEntry, C.PasswordChangeEntryUrl is not null);

            var locked = C.Working || C.HasSession;
            if (origin.Text != C.Origin) origin.Text = C.Origin;
            origin.IsEnabled = detect.IsEnabled = domain.IsEnabled = !locked;
            Visible(certRow, C.Probe is not null);
            certText.Text = C.Certificate.Title();
            Ui.Tone(certText, C.Certificate.Approved() ? "good" : "warn");
            Visible(viewCert, C.Certificate.NeedsConfirmation());
            Visible(domainField, C.Probe is not null);
            var options = C.PasswordMethods.Select(m => new AuthOption(m.At("loginDomain").Str() ?? "", m.At("authName").Str() ?? "")).ToList();
            if (domain.ItemsSource is not IEnumerable<AuthOption> shown || !shown.SequenceEqual(options)) domain.ItemsSource = options;
            domain.SelectedItem = options.FirstOrDefault(o => o.Domain == C.SelectedDomain);

            Visible(loggedIn, C.HasSession);
            Visible(loggedOut, !C.HasSession);
            sessionUser.Text = C.AuthenticatedUsername ?? C.Username;
            refresh.IsEnabled = !C.Working && C.TunnelProof is null;
            logout.IsEnabled = !C.Working;
            if (username.Text != C.Username) username.Text = C.Username;
            if (password.Password != C.Password) password.Password = C.Password;
            username.IsEnabled = password.IsEnabled = !C.Working;
            remember.IsChecked = C.RememberCredentials;
            remember.IsEnabled = forget.IsEnabled = !C.Working;
            Visible(forget, C.HasSavedCredentials);
            credentialNote.Text = C.CredentialMessage ?? "";
            Visible(credentialNote, C.CredentialMessage is not null);
            Visible(login, !C.HasSession);
            login.IsEnabled = C.CanLogin;
            Visible(cancel, !C.HasSession && C.Working);

            takeover.IsChecked = C.TakeoverEnabled;
            takeover.IsEnabled = !C.Working;
            takeoverNote.Text = C.TakeoverEnabled ? "授权资源走私有网络隧道，外网沿用现有 VPN。" : "仅连接和验证私有网络隧道，其他应用的流量不接管。";
            connection.IsChecked = C.ConnectionEnabled;
            connection.IsEnabled = C.HasSession && C.Resources is not null && !C.Working;
            verify.IsEnabled = C.TunnelProof is not null && !C.Working;
            connectionNote.Text = (C.TunnelProof is not null ? "可按需验证内网地址。" : "登录后打开开关，连接私有网络。") +
                (C.RoutingRecovering ? "  私有网络分流恢复中…" : "");
            internet.IsEnabled = !C.Working;
            var check = C.Routing.At("internet");
            var reachable = check.At("result").At("ok").Bool() == true;
            internetText.Text = check is null ? "外网结果单独检测" : reachable ? $"可达 · {check.At("result").At("elapsedMs").Num() ?? 0:0} ms" : "未连通";
            Ui.Tone(internetText, check is null ? "muted" : reachable ? "good" : "warn");
            internetText.ToolTip = check is null ? null : check.At("result").At("error").Str() ?? Ui.Date(check.At("checkedAt").Str());

            var result = C.Resources;
            Visible(searchField, result is not null);
            Visible(table, result is not null);
            Visible(resourceFooter, result is not null);
            Visible(emptyResources, result is null);
            resourceCount.Text = result is null ? "" : $"{result.At("appCount").Num() ?? 0:0} 个应用 · {result.At("rows").Items().Count()} 条规则";
            resourceFooter.Text = result is null ? "" : $"接入网关下发 · {Ui.Date(result.At("fetchedAt").Str())}";
            var term = search.Text.Trim();
            var rows = result.At("rows").Items().Select(r => new ResourceRowView(
                    r.At("id").Str() ?? "", r.At("name").Str() ?? "", r.At("address").Str() ?? "", r.At("network").Str() ?? "", r.At("ports").Str() ?? ""))
                .Where(r => term.Length == 0 || $"{r.Name} {r.Address} {r.Ports} {r.Network}".Contains(term, StringComparison.OrdinalIgnoreCase))
                .ToList();
            Ui.Fill(table, rows, r => r.Id);

            var showError = C.ErrorMessage is not null && C.ErrorStage != "business" && !C.PasswordChangeRequired;
            error.Text = showError ? $"{C.ErrorHeading}：{C.ErrorMessage}" : "";
            error.ToolTip = C.ErrorMessage;
            Visible(errorBar, showError);
        }
        finally { updating = false; }
    }

    /// A modal sheet; the caller fills body and buttons and keeps the window to close it.
    static Window Sheet(string title, UIElement body, Panel buttons, double width)
    {
        var owner = Application.Current.MainWindow;
        var window = new Window
        {
            Title = title,
            Owner = owner,
            Width = width,
            SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false,
            FontFamily = owner.FontFamily,
            FontSize = owner.FontSize,
        };
        window.SetResourceReference(Window.BackgroundProperty, "ApplicationBackgroundBrush");
        TextOptions.SetTextFormattingMode(window, TextFormattingMode.Display);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        var content = Ui.Stack(16, Ui.Text(title, 20, bold: true), body, buttons);
        content.Margin = new Thickness(24);
        window.Content = content;
        return window;
    }

    static TextBlock Mono(string text)
    {
        var block = Ui.Text(text, 12, wrap: true);
        block.FontFamily = new FontFamily("Consolas, Microsoft YaHei UI");
        return block;
    }

    void ShowDetails()
    {
        var body = new StackPanel();
        if (C.Probe is { } probe)
        {
            Ui.Add(body, Ui.Text(probe.At("subject").Str() ?? "", 15, bold: true, wrap: true), 8);
            Ui.Add(body, Ui.Text($"有效期至 {Ui.Date(probe.At("validTo").Str())}", 13), 8);
            Ui.Add(body, Mono($"SHA-256\n{probe.At("fingerprint").Str()}"), 8);
            var state = Ui.Text(C.Certificate.Title(), 13, wrap: true);
            Ui.Tone(state, C.Certificate.Approved() ? "good" : "warn");
            Ui.Add(body, state, 8);
            if (C.Certificate.NeedsConfirmation())
            {
                Ui.Add(body, Ui.Text(C.Certificate == CertState.Changed
                    ? "证书与之前确认的网关不同。确认网关管理员已更换证书后，再更新网关记录。"
                    : "该证书尚未被系统信任。首次确认属于目标网关后，只为这个网关记住指纹；之后自动核验。", 13, wrap: true), 8);
                if (C.Certificate == CertState.Changed && C.PreviousFingerprint is { } previous)
                    Ui.Add(body, Mono($"之前的 SHA-256\n{previous}"), 8);
            }
        }
        else Ui.Add(body, Ui.Text("检测入口后可查看网关证书。", 13), 8);
        if (C.ErrorMessage is { } message)
        {
            var line = Ui.Text($"{C.ErrorHeading}：{message}", 13, wrap: true);
            Ui.Tone(line, "bad");
            Ui.Add(body, line, 8);
        }
        Ui.Add(body, new Separator(), 8);
        foreach (var (time, text) in C.Timeline) Ui.Add(body, Ui.Text($"{time:HH:mm:ss}  {text}", 13, wrap: true), 4);
        var scroll = Scroll(body);
        scroll.MaxHeight = 380;

        Window? window = null;
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(Ui.Button("复制诊断信息", () => { C.CopyDiagnostics(); S.Message = "诊断信息已复制。"; S.Notify(); }));
        if (C.Certificate.NeedsConfirmation())
        {
            var trust = Ui.Button(C.Certificate == CertState.Changed ? "确认网关更换证书并更新" : "信任此接入网关并记住", () =>
            {
                C.ConfirmGatewayCertificate();
                if (C.Certificate.Approved()) window?.Close();
            });
            trust.IsEnabled = !C.Working && !C.HasSession;
            buttons.Children.Add(trust);
        }
        var done = Ui.Button("完成", () => window?.Close(), accent: true);
        done.IsCancel = true;
        buttons.Children.Add(done);
        window = Sheet("证书与连接详情", scroll, buttons, 620);
        window.ShowDialog();
    }

    void ShowPasswordChange(JsonNode challenge)
    {
        var id = challenge.At("id").Str();
        if (C.Challenge.At("id").Str() != id) return;
        var body = new StackPanel();
        Ui.Add(body, Ui.Text(challenge.At("message").Str() ?? "修改接入密码后继续本次登录。", 13, secondary: true, wrap: true), 12);
        Ui.Add(body, Ui.Text($"接入账号：{challenge.At("username").Str() ?? C.Username}", 13), 10);
        if (challenge.At("errorMessage").Str() is { Length: > 0 } error) Ui.Add(body, Ui.Warning(error), 10);
        foreach (var rule in challenge.At("rules").Items())
            Ui.Add(body, Ui.Text($"• {rule.Str()}", 12, secondary: true, wrap: true), 5);
        var requireUsername = challenge.At("requireUsername").Bool() == true;
        var account = Box();
        if (requireUsername) Ui.Add(body, Labeled("新账号名", account), 10);
        PasswordBox Field() => new() { MinHeight = 32, VerticalContentAlignment = VerticalAlignment.Center };
        var oldPassword = Field();
        var newPassword = Field();
        var confirmation = Field();
        Ui.Add(body, Labeled("旧密码", oldPassword), 10);
        Ui.Add(body, Labeled("新密码", newPassword), 10);
        Ui.Add(body, Labeled("再次输入新密码", confirmation), 10);
        var validation = Ui.Text("", 12, wrap: true);
        Ui.Add(body, validation, 8);
        Window? window = null;
        var answered = false;
        var submit = Ui.Button("修改并继续登录", () => { }, accent: true);
        submit.IsDefault = true;
        string? Validate() => new CompanyPasswordChangeInput(oldPassword.Password, newPassword.Password, confirmation.Password, account.Text).ValidationMessage(requireUsername);
        void Update()
        {
            var error = Validate();
            submit.IsEnabled = error is null;
            validation.Text = confirmation.Password.Length > 0 ? error ?? "" : "";
        }
        oldPassword.PasswordChanged += (_, _) => Update();
        newPassword.PasswordChanged += (_, _) => Update();
        confirmation.PasswordChanged += (_, _) => Update();
        account.TextChanged += (_, _) => Update();
        Update();
        void Clear() { oldPassword.Clear(); newPassword.Clear(); confirmation.Clear(); }
        submit.Click += (_, _) =>
        {
            if (Validate() is not null) return;
            var response = new JsonObject { ["oldPassword"] = oldPassword.Password, ["newPassword"] = newPassword.Password };
            if (requireUsername) response["newUsername"] = account.Text.Trim();
            answered = true; Clear(); window?.Close(); C.AnswerChallenge(response, id);
        };
        var cancel = Ui.Button("取消登录", () => window?.Close());
        cancel.IsCancel = true;
        // Long server policies remain scrollable; the actions stay visible.
        var scroll = new ScrollViewer { Content = body, MaxHeight = 440, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        window = Sheet("修改接入密码", scroll, Ui.Row(cancel, submit), 510);
        Action<bool> watch = _ => { if (C.Challenge.At("id").Str() != id) { answered = true; window.Close(); } };
        S.Changed += watch;
        window.Closed += (_, _) => { S.Changed -= watch; Clear(); if (!answered) C.EndTest(); };
        window.Loaded += (_, _) => { if (requireUsername) account.Focus(); else oldPassword.Focus(); };
        window.ShowDialog();
    }

    void ShowChallenge(JsonNode challenge)
    {
        if (challenge.At("kind").Str() == "password_change") { ShowPasswordChange(challenge); return; }
        var id = challenge.At("id").Str();
        if (C.Challenge.At("id").Str() != id) return;
        var kind = challenge.At("kind").Str() ?? "text";
        var body = new StackPanel();
        Ui.Add(body, Ui.Text(challenge.At("message").Str() ?? "", 13, secondary: true, wrap: true), 12);
        var code = Box();
        var points = new List<(int X, int Y)>();
        BitmapImage? image = null;
        try
        {
            if (challenge.At("imageBase64").Str() is { Length: > 0 } encoded)
            {
                image = new BitmapImage();
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.StreamSource = new MemoryStream(Convert.FromBase64String(encoded));
                image.EndInit();
            }
        }
        catch { image = null; }

        Window? window = null;
        var answered = false;
        var submit = Ui.Button("提交", () => { }, accent: true);
        submit.IsDefault = true;
        submit.IsEnabled = false;
        if (image is not null)
        {
            var scale = Math.Min(1, Math.Min(460.0 / image.PixelWidth, 330.0 / image.PixelHeight));
            double width = image.PixelWidth * scale, height = image.PixelHeight * scale;
            var canvas = new Canvas { Width = width, Height = height, HorizontalAlignment = HorizontalAlignment.Left, Background = Brushes.Transparent };
            canvas.Children.Add(new Image { Source = image, Width = width, Height = height });
            Ui.Add(body, canvas, 8);
            if (kind == "click")
            {
                var count = Ui.Text("已点选 0 个位置", 12, secondary: true);
                void Redraw()
                {
                    while (canvas.Children.Count > 1) canvas.Children.RemoveAt(1);
                    for (var i = 0; i < points.Count; i++)
                    {
                        var marker = new Grid { Width = 23, Height = 23, IsHitTestVisible = false };
                        marker.Children.Add(new Ellipse { Fill = Brushes.RoyalBlue });
                        marker.Children.Add(new TextBlock
                        {
                            Text = $"{i + 1}", Foreground = Brushes.White, FontSize = 12, FontWeight = FontWeights.Bold,
                            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                        });
                        Canvas.SetLeft(marker, points[i].X * scale - 11.5);
                        Canvas.SetTop(marker, points[i].Y * scale - 11.5);
                        canvas.Children.Add(marker);
                    }
                    count.Text = $"已点选 {points.Count} 个位置";
                    submit.IsEnabled = points.Count > 0;
                }
                canvas.Cursor = System.Windows.Input.Cursors.Hand;
                canvas.MouseLeftButtonDown += (_, e) =>
                {
                    var p = e.GetPosition(canvas);
                    points.Add((Math.Clamp((int)Math.Round(p.X / scale), 0, image.PixelWidth - 1),
                        Math.Clamp((int)Math.Round(p.Y / scale), 0, image.PixelHeight - 1)));
                    Redraw();
                };
                Ui.Add(body, Ui.Bar(Ui.Row(
                    Ui.Button("撤销", () => { if (points.Count > 0) points.RemoveAt(points.Count - 1); Redraw(); }),
                    Ui.Button("清空", () => { points.Clear(); Redraw(); })), count), 8);
            }
        }
        else if (kind is "click" or "text") Ui.Add(body, Ui.Warning("验证码图片无法显示，请取消后重试。"), 8);
        if (kind == "external")
        {
            if (challenge.At("url").Str() is { } raw && Uri.TryCreate(raw, UriKind.Absolute, out var url) && url.Scheme is "https" or "http")
                Ui.Add(body, Ui.Button("打开私有网络认证页面", () => OpenInBrowser(url)), 8);
            Ui.Add(body, Labeled("粘贴完成认证后的回调地址", code), 8);
        }
        else if (kind != "click") Ui.Add(body, Labeled("输入验证码", code), 8);
        code.TextChanged += (_, _) => submit.IsEnabled = code.Text.Trim().Length > 0;

        submit.Click += (_, _) =>
        {
            JsonObject response;
            if (kind == "click")
            {
                if (points.Count == 0 || image is null) return;
                response = new JsonObject
                {
                    ["points"] = new JsonArray(points.Select(p => (JsonNode?)new JsonObject { ["x"] = p.X, ["y"] = p.Y }).ToArray()),
                    ["width"] = image.PixelWidth, ["height"] = image.PixelHeight,
                };
            }
            else
            {
                if (code.Text.Trim().Length == 0) return;
                response = new JsonObject { [kind == "external" ? "callbackURL" : "code"] = code.Text.Trim() };
            }
            answered = true;
            window?.Close();
            C.AnswerChallenge(response, id);
        };
        var cancelButton = Ui.Button("取消测试", () => window?.Close());
        cancelButton.IsCancel = true;
        window = Sheet(challenge.At("title").Str() ?? "安全验证", body, Ui.Row(cancelButton, submit), 510);
        // A failure or a newer challenge replaces this one; close without cancelling.
        Action<bool> watch = _ => { if (C.Challenge.At("id").Str() != id) { answered = true; window.Close(); } };
        S.Changed += watch;
        window.Closed += (_, _) =>
        {
            S.Changed -= watch;
            if (!answered) C.EndTest();
        };
        window.ShowDialog();
    }

    void ShowVerification()
    {
        var target = Box();
        target.Text = C.Target;
        target.TextChanged += (_, _) => C.Target = target.Text;
        var state = Ui.Text("", 13, wrap: true);
        var note = Ui.Text("", 13, secondary: true);
        Window? window = null;
        var attempted = "";
        var started = false;
        DispatcherTimer? dismissal = null;
        bool Passed() => C.Phases["business"] == Phase.Passed;
        var run = Ui.Button("验证", () => { }, accent: true);
        run.IsDefault = true;
        void Start()
        {
            dismissal?.Stop();
            dismissal = null;
            attempted = C.Target;
            started = true;
            C.VerifyBusiness();
        }
        run.Click += (_, _) => Start();
        void Refresh()
        {
            target.IsEnabled = !C.Working;
            run.Content = Passed() ? "重新验证" : "验证";
            run.IsEnabled = !C.Working && C.TunnelProof is not null && C.Target.Trim().Length > 0;
            note.Text = "";
            if (C.Working) { state.Text = "正在验证…"; Ui.Tone(state, null); }
            else if (C.ErrorMessage is { } message) { state.Text = message; Ui.Tone(state, "bad"); }
            else if (Passed())
            {
                state.Text = "✓ 验证通过";
                Ui.Tone(state, "good");
                if (C.BusinessVerified && C.Routing.At("proof") is { } proof)
                    note.Text = $"系统访问 HTTP {proof.At("httpStatus").Num():0} · {proof.At("elapsedMs").Num():0} ms";
                else if (C.TunnelProof is { } tunnel)
                    note.Text = $"私有网络隧道 HTTP {tunnel.At("httpStatus").Num():0} · {tunnel.At("elapsedMs").Num():0} ms";
                if (started && dismissal is null)
                {
                    var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
                    timer.Tick += (_, _) =>
                    {
                        timer.Stop();
                        if (!C.Working && Passed() && C.ErrorMessage is null && C.Target == attempted) window?.Close();
                    };
                    dismissal = timer;
                    timer.Start();
                }
            }
            else state.Text = "";
        }
        var close = Ui.Button("关闭", () => window?.Close());
        close.IsCancel = true;
        var body = Ui.Stack(12, Ui.Text("通过当前私有网络连接检查这个地址是否可访问。", 13, secondary: true, wrap: true),
            Labeled("内网网址或 IP", target), state, note);
        window = Sheet("验证私有网络", body, Ui.Row(close, run), 440);
        Action<bool> watch = trafficOnly => { if (!trafficOnly) Refresh(); };
        S.Changed += watch;
        window.Closed += (_, _) => { S.Changed -= watch; dismissal?.Stop(); };
        window.Loaded += (_, _) => { Refresh(); Start(); };
        window.ShowDialog();
    }
}
