using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Qingzhou;

public abstract class PageBase(Store store)
{
    protected readonly Store S = store;
    public abstract FrameworkElement View { get; }
    public abstract void Update(bool trafficOnly);
    public virtual void Shown() { }
    public virtual void Hidden() { }

    /// Stack items vertically; tables (and items tagged "fill") take the remaining height.
    protected static Grid Layout(params UIElement[] items)
    {
        var grid = Rows(items);
        grid.Margin = new Thickness(28, 24, 28, 20);
        return grid;
    }

    protected static Grid Rows(params UIElement[] items)
    {
        var grid = new Grid();
        for (var i = 0; i < items.Length; i++)
        {
            var fill = items[i] is ListView || items[i] is FrameworkElement { Tag: "fill" };
            grid.RowDefinitions.Add(new RowDefinition { Height = fill ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
            if (items[i] is FrameworkElement element) element.Margin = new Thickness(0, 0, 0, i == items.Length - 1 ? 0 : 14);
            Grid.SetRow(items[i], i);
            grid.Children.Add(items[i]);
        }
        return grid;
    }

    protected static ScrollViewer Scroll(UIElement content) => new()
    {
        Content = content,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
    };

    protected static bool Confirm(string title, string message) =>
        MessageBox.Show(Application.Current.MainWindow, message, title, MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK;

    protected static string RiskLabel(JsonNode? risk) => risk.At("riskLevel").Str() switch
    {
        "low" => "低风险",
        "medium" => "中风险",
        "high" => "高风险",
        null => "未检测",
        _ => "未确认",
    };
}

/// Modal editor sheet: title, caller-built body, 取消 / confirm buttons.
public static class Dialog
{
    public static bool Show(string title, UIElement body, string confirm = "保存", Func<bool>? validate = null, double width = 520, Func<Task<bool>>? submit = null)
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
        var ok = Ui.Button(confirm, () => { }, accent: true);
        ok.IsDefault = true;
        ok.Margin = new Thickness(0);
        var cancel = Ui.Button("取消", () => window.DialogResult = false);
        cancel.IsCancel = true;
        var submitting = false;
        window.Closing += (_, e) => { if (submitting) e.Cancel = true; };
        ok.Click += async (_, _) =>
        {
            if (submitting || (validate is not null && !validate())) return;
            if (submit is null) { window.DialogResult = true; return; }
            submitting = true;
            ok.IsEnabled = cancel.IsEnabled = false;
            if (body is FrameworkElement element) element.IsEnabled = false;
            try
            {
                var saved = await submit();
                submitting = false;
                if (saved) window.DialogResult = true;
            }
            finally
            {
                submitting = false;
                ok.IsEnabled = cancel.IsEnabled = true;
                if (body is FrameworkElement restoredElement) restoredElement.IsEnabled = true;
            }
        };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        cancel.Margin = new Thickness(0, 0, 8, 0);
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);
        var content = Ui.Stack(16, Ui.Text(title, 20, bold: true), body, buttons);
        content.Margin = new Thickness(24);
        window.Content = content;
        return window.ShowDialog() == true;
    }
}
