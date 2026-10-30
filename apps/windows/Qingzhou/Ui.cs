using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Threading;

namespace Qingzhou;

/// Small builders so pages read like the SwiftUI views they mirror.
public static class Ui
{
    public static TextBlock Text(string text = "", double size = 14, bool bold = false, bool secondary = false, bool wrap = false)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = size,
            FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        block.SetResourceReference(TextBlock.ForegroundProperty, secondary ? "BrandSecondary" : "BrandText");
        return block;
    }

    public static TextBlock Note(string text = "") => Text(text, 12, secondary: true, wrap: true);

    public static TextBlock Warning(string text = "")
    {
        var block = Text(text, 13, wrap: true);
        block.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCautionBrush");
        return block;
    }

    public static void Tone(TextBlock block, string? tone) => block.SetResourceReference(TextBlock.ForegroundProperty, tone switch
    {
        "good" => "SystemFillColorSuccessBrush",
        "bad" => "SystemFillColorCriticalBrush",
        "warn" => "SystemFillColorCautionBrush",
        "muted" => "TextFillColorSecondaryBrush",
        _ => "TextFillColorPrimaryBrush",
    });

    public static Button Button(string text, Action click, bool accent = false)
    {
        var button = new Button { Content = text, Padding = new Thickness(15, 7, 15, 7), MinHeight = 36 };
        button.SetResourceReference(FrameworkElement.StyleProperty, accent ? "QingzhouPrimaryButtonStyle" : "QingzhouButtonStyle");
        button.Click += (_, _) => click();
        return button;
    }

    public static StackPanel Row(params UIElement[] items)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var item in items)
        {
            if (item is FrameworkElement element && element.Margin == default) element.Margin = new Thickness(0, 0, 8, 0);
            panel.Children.Add(item);
        }
        return panel;
    }

    /// Items on the left, one element pinned to the right.
    public static DockPanel Bar(UIElement right, params UIElement[] left)
    {
        var dock = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(right, Dock.Right);
        if (right is FrameworkElement r) r.VerticalAlignment = VerticalAlignment.Center;
        dock.Children.Add(right);
        dock.Children.Add(Row(left));
        return dock;
    }

    public static StackPanel Stack(double gap, params UIElement[] items)
    {
        var panel = new StackPanel();
        foreach (var item in items) Add(panel, item, gap);
        return panel;
    }

    public static void Add(Panel panel, UIElement item, double gap)
    {
        if (item is FrameworkElement element) element.Margin = new Thickness(0, 0, 0, gap);
        panel.Children.Add(item);
    }

    public static Border Card(UIElement child, double padding = 16)
    {
        var border = new Border { Child = child, Padding = new Thickness(padding), CornerRadius = new CornerRadius(16), BorderThickness = new Thickness(1) };
        border.SetResourceReference(Border.BackgroundProperty, "BrandSurface");
        border.SetResourceReference(Border.BorderBrushProperty, "BrandBorder");
        return border;
    }

    public static StackPanel Header(string title, string subtitle, out TextBlock titleBlock, out TextBlock subtitleBlock)
    {
        titleBlock = Text(title, 30, bold: true);
        subtitleBlock = Text(subtitle, 14, secondary: true, wrap: true);
        subtitleBlock.Margin = new Thickness(0, 6, 0, 0);
        var panel = new StackPanel();
        panel.Children.Add(titleBlock);
        panel.Children.Add(subtitleBlock);
        return panel;
    }

    public static StackPanel Header(string title, string subtitle) => Header(title, subtitle, out _, out _);

    public static TextBox Input(double width = 280) => new() { Width = width, MinHeight = 32, VerticalContentAlignment = VerticalAlignment.Center };

    /// A labelled input; WPF text boxes have no placeholder.
    public static StackPanel Field(string label, Control input) => Row(Text(label, 13, secondary: true), input);

    public static ListView Table(SelectionMode mode, params (string Header, string Path, double Width)[] columns)
    {
        var grid = new GridView();
        foreach (var (header, path, width) in columns)
            grid.Columns.Add(new GridViewColumn { Header = header, DisplayMemberBinding = new Binding(path), Width = width });
        return new ListView { View = grid, SelectionMode = mode, MinHeight = 160 };
    }

    /// Replace rows while keeping selection and scroll position across refreshes.
    public static void Fill<T>(ListView view, IReadOnlyList<T> rows, Func<T, string> key) where T : class
    {
        if (view.ItemsSource is IEnumerable<T> current && current.SequenceEqual(rows)) return;
        var keep = view.SelectedItems.OfType<T>().Select(key).ToHashSet();
        var scroll = Find<ScrollViewer>(view);
        var offset = scroll?.VerticalOffset ?? 0;
        view.ItemsSource = rows;
        var matched = rows.Where(r => keep.Contains(key(r))).ToList();
        if (view.SelectionMode == SelectionMode.Single) view.SelectedItem = matched.FirstOrDefault();
        else foreach (var row in matched) view.SelectedItems.Add(row);
        if (scroll is not null && offset > 0)
            view.Dispatcher.InvokeAsync(() => scroll.ScrollToVerticalOffset(offset), DispatcherPriority.Loaded);
    }

    static T? Find<T>(DependencyObject root) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T match) return match;
            if (Find<T>(child) is { } nested) return nested;
        }
        return null;
    }

    public static string Ms(double? value) => value is { } v ? $"{(int)v} ms" : "—";

    public static string Bytes(double count)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        var value = Math.Max(0, count);
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1) { value /= 1024; unit++; }
        return unit == 0 ? $"{value:0} {units[unit]}" : $"{value:0.#} {units[unit]}";
    }

    public static string Date(string? value)
    {
        if (string.IsNullOrEmpty(value)) return "尚无记录";
        return DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)
            ? date.ToLocalTime().ToString("yyyy-MM-dd HH:mm")
            : value;
    }
}
