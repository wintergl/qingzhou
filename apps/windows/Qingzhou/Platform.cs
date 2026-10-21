using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Principal;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows;

namespace Qingzhou;

static class Paths
{
    public static string Dir
    {
        get
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Qingzhou");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }
}

public static class Appearance
{
    static string FilePath => Path.Combine(Paths.Dir, "ui.json");

    public static string Load()
    {
        try { return JsonNode.Parse(File.ReadAllText(FilePath)).At("appearance").Str() ?? "system"; }
        catch { return "system"; }
    }

    public static void Save(string value)
    {
        try { File.WriteAllText(FilePath, new JsonObject { ["appearance"] = value }.ToJsonString()); } catch { }
    }

    public static void Apply(string value) => Application.Current.ThemeMode = value switch
    {
        "light" => ThemeMode.Light,
        "dark" => ThemeMode.Dark,
        _ => ThemeMode.System,
    };
}

/// Launch at logon through Task Scheduler: it can start an elevated app without a UAC prompt.
public static class LoginTask
{
    const string Name = "Qingzhou";

    public static bool Enabled() => Run("schtasks", "/Query", "/TN", Name) == 0;

    public static void Set(bool enabled)
    {
        if (!enabled)
        {
            if (Enabled() && Run("schtasks", "/Delete", "/TN", Name, "/F") != 0)
                throw new InvalidOperationException("无法移除登录启动任务。");
            return;
        }
        var user = SecurityElement.Escape(WindowsIdentity.GetCurrent().Name);
        var exe = SecurityElement.Escape(Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Qingzhou.exe"));
        // XML instead of /SC ONLOGON flags: the defaults would skip the start on battery power.
        var xml = $"""
            <?xml version="1.0" encoding="UTF-16"?>
            <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
              <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>{user}</UserId><Delay>PT5S</Delay></LogonTrigger></Triggers>
              <Principals><Principal id="Author"><UserId>{user}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
              <Settings>
                <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
                <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
                <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
                <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
                <Enabled>true</Enabled>
              </Settings>
              <Actions Context="Author"><Exec><Command>{exe}</Command></Exec></Actions>
            </Task>
            """;
        var file = Path.Combine(Path.GetTempPath(), $"qingzhou-task-{Guid.NewGuid():N}.xml");
        try
        {
            File.WriteAllText(file, xml, Encoding.Unicode);
            if (Run("schtasks", "/Create", "/TN", Name, "/XML", file, "/F") != 0)
                throw new InvalidOperationException("无法创建登录启动任务。");
        }
        finally { try { File.Delete(file); } catch { } }
    }

    static int Run(string file, params string[] args)
    {
        var info = new ProcessStartInfo(file)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        using var process = Process.Start(info) ?? throw new InvalidOperationException($"无法运行 {file}。");
        var error = process.StandardError.ReadToEndAsync();
        process.StandardOutput.ReadToEnd();
        error.Wait(15_000);
        process.WaitForExit(15_000);
        return process.HasExited ? process.ExitCode : -1;
    }
}

/// The ipdata key, encrypted with DPAPI for the current Windows user.
public static class RiskKeyVault
{
    static string KeyPath => Path.Combine(Paths.Dir, "risk-key.bin");

    public static string? Load() =>
        File.Exists(KeyPath) ? Encoding.UTF8.GetString(Transform(File.ReadAllBytes(KeyPath), protect: false)) : null;

    public static void Save(string key) => File.WriteAllBytes(KeyPath, Transform(Encoding.UTF8.GetBytes(key), protect: true));

    public static void Remove()
    {
        if (File.Exists(KeyPath)) File.Delete(KeyPath);
    }

    /// DPAPI for the current Windows user; also used by the company account vault.
    internal static byte[] Transform(byte[] data, bool protect)
    {
        var handle = GCHandle.Alloc(data, GCHandleType.Pinned);
        try
        {
            var input = new Blob { Size = data.Length, Data = handle.AddrOfPinnedObject() };
            Blob output;
            var ok = protect
                ? CryptProtectData(ref input, "Qingzhou", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error(), "本机加密存储不可用。");
            try
            {
                var result = new byte[output.Size];
                Marshal.Copy(output.Data, result, 0, output.Size);
                return result;
            }
            finally { LocalFree(output.Data); }
        }
        finally { handle.Free(); }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct Blob
    {
        public int Size;
        public IntPtr Data;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CryptProtectData(ref Blob input, string? description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);

    [DllImport("crypt32.dll", SetLastError = true)]
    static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);

    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr memory);
}
