using Microsoft.Win32;
using System.Windows;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace Qingzhou;

public sealed class TrayIconProvider : ITrayIconProvider
{
    public event Action? Changed;
    public TrayIconProvider() => SystemEvents.UserPreferenceChanged += OnPreferenceChanged;

    public bool IsLightTheme
    {
        get
        {
            if (Forms.SystemInformation.HighContrast)
                return Drawing.SystemColors.Window.GetBrightness() >= 0.5f;
            try
            {
                // The taskbar follows the system theme, independently of app appearance.
                return Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                    "SystemUsesLightTheme", 1) is not int value || value != 0;
            }
            catch { return true; }
        }
    }

    public Drawing.Icon Load(string fileName)
    {
        var uri = new Uri($"pack://application:,,,/Assets/Tray/{fileName}");
        using var stream = Application.GetResourceStream(uri)?.Stream
            ?? throw new InvalidOperationException("应用缺少托盘图标，请重新安装轻舟。");
        using var original = new Drawing.Icon(stream, Forms.SystemInformation.SmallIconSize);
        return (Drawing.Icon)original.Clone();
    }

    void OnPreferenceChanged(object sender, UserPreferenceChangedEventArgs e) => Changed?.Invoke();
    public void Dispose() => SystemEvents.UserPreferenceChanged -= OnPreferenceChanged;
}
