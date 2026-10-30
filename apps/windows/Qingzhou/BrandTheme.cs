using Microsoft.Win32;
using System.Windows;
using System.Windows.Media;

namespace Qingzhou;

/// Shared Qingzhou palette. Native input, table and menu behavior stays with Fluent.
public static class BrandTheme
{
    static bool listening;
    static string appearance = "system";

    public static void Apply(string value)
    {
        appearance = value;
        if (!listening)
        {
            SystemEvents.UserPreferenceChanged += (_, _) =>
            {
                if (Application.Current is { } app && !app.Dispatcher.HasShutdownStarted)
                    app.Dispatcher.InvokeAsync(() => Apply(appearance));
            };
            listening = true;
        }
        var dark = value == "dark";
        if (value == "system")
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
                dark = key?.GetValue("AppsUseLightTheme") is int light && light == 0;
            }
            catch (System.Security.SecurityException) { dark = false; }
            catch (UnauthorizedAccessException) { dark = false; }
        }
        var resources = Application.Current.Resources;
        void Set(string key, string light, string night) => resources[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(dark ? night : light));
        // High contrast keeps the system's chosen foreground and background.
        if (SystemParameters.HighContrast)
        {
            resources["BrandBackground"] = SystemColors.WindowBrush;
            resources["BrandSurface"] = SystemColors.WindowBrush;
            resources["BrandText"] = SystemColors.WindowTextBrush;
            resources["BrandSecondary"] = SystemColors.WindowTextBrush;
            resources["BrandBorder"] = SystemColors.WindowTextBrush;
            resources["BrandSelection"] = SystemColors.HighlightBrush;
            resources["BrandAccent"] = SystemColors.HighlightBrush;
            resources["BrandButton"] = SystemColors.HighlightBrush;
            resources["BrandHero"] = SystemColors.WindowBrush;
            resources["BrandHeroText"] = SystemColors.WindowTextBrush;
            resources["BrandHeroMuted"] = SystemColors.WindowTextBrush;
            return;
        }
        Set("BrandHero", "#14382E", "#14382E");
        Set("BrandHeroText", "#F0F7E8", "#F0F7E8");
        Set("BrandHeroMuted", "#ABCCBA", "#ABCCBA");
        Set("BrandBackground", "#F5F5F2", "#121B1D");
        Set("BrandSurface", "#FFFFFF", "#1B272A");
        Set("BrandText", "#203632", "#E9F1ED");
        Set("BrandSecondary", "#61736F", "#A5B8B2");
        Set("BrandBorder", "#E1E7E2", "#324440");
        Set("BrandSelection", "#E1ECE5", "#29443C");
        Set("BrandAccent", "#216650", "#97DABB");
        Set("BrandButton", "#216650", "#276D53");
    }
}
