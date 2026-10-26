using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;

namespace Qingzhou;

public sealed class CoreException(string message) : Exception(message);

/// Talks to splitvpn-core.exe over the same JSON-lines protocol the macOS app uses.
public sealed class CoreClient : ICoreClient
{
    readonly ConcurrentDictionary<string, TaskCompletionSource<JsonNode?>> pending = new();
    readonly object writeLock = new();
    readonly StringBuilder stderrTail = new();
    Process? process;
    StreamWriter? stdin;
    long next;
    IntPtr job;

    /// Raised on a background thread.
    public event Action<string, JsonNode?>? Event;

    string ExitReason()
    {
        lock (stderrTail)
        {
            var line = stderrTail.ToString().Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.Length > 0);
            return line is null ? "VPN 服务已结束，请重新打开轻舟。" : $"VPN 服务已结束：{line}";
        }
    }

    void Start()
    {
        if (process is not null) return;
        var dir = AppContext.BaseDirectory;
        var info = new ProcessStartInfo(Path.Combine(dir, "splitvpn-core.exe"))
        {
            WorkingDirectory = dir,
            UseShellExecute = false,
            // Hidden console; mihomo and tool children inherit it instead of flashing windows.
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
        };
        Process child;
        try { child = Process.Start(info) ?? throw new CoreException("无法启动 splitvpn-core.exe。"); }
        catch (Exception e) when (e is not CoreException) { throw new CoreException($"无法启动 splitvpn-core.exe：{e.Message}"); }
        KillWithApp(child);
        process = child;
        stdin = child.StandardInput;
        stdin.AutoFlush = false;

        new Thread(() =>
        {
            var buffer = new char[4096];
            int n;
            while ((n = child.StandardError.Read(buffer, 0, buffer.Length)) > 0)
                lock (stderrTail)
                {
                    stderrTail.Append(buffer, 0, n);
                    if (stderrTail.Length > 4096) stderrTail.Remove(0, stderrTail.Length - 4096);
                }
        }) { IsBackground = true, Name = "core-stderr" }.Start();

        new Thread(() =>
        {
            string? line;
            while ((line = child.StandardOutput.ReadLine()) is not null)
            {
                JsonNode? message;
                try { message = JsonNode.Parse(line); } catch { continue; }
                if (message.At("event").Str() is { } name) { Event?.Invoke(name, message.At("data")); continue; }
                if (message.At("id").Str() is not { } id || !pending.TryRemove(id, out var waiter)) continue;
                if (message.At("ok").Bool() == true) waiter.TrySetResult(message.At("data")?.DeepClone());
                else waiter.TrySetException(new CoreException(message.At("error").At("message").Str() ?? "操作未完成。"));
            }
            // Core gone: let the stderr reader finish, then fail every waiter.
            Thread.Sleep(100);
            lock (writeLock) stdin = null;
            var reason = ExitReason();
            foreach (var id in pending.Keys)
                if (pending.TryRemove(id, out var waiter)) waiter.TrySetException(new CoreException(reason));
            Event?.Invoke("core:disconnected", JsonValue.Create(reason));
        }) { IsBackground = true, Name = "core-stdout" }.Start();
    }

    public Task<JsonNode?> Request(string channel, JsonObject? payload = null)
    {
        var id = "w" + Interlocked.Increment(ref next);
        var waiter = new TaskCompletionSource<JsonNode?>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = waiter;
        var line = new JsonObject { ["id"] = id, ["channel"] = channel, ["payload"] = payload ?? new JsonObject() }.ToJsonString();
        try
        {
            lock (writeLock)
            {
                Start();
                if (stdin is null) throw new CoreException(ExitReason());
                stdin.Write(line);
                stdin.Write('\n');
                stdin.Flush();
            }
        }
        catch (Exception e)
        {
            pending.TryRemove(id, out _);
            return Task.FromException<JsonNode?>(e as CoreException ?? new CoreException(ExitReason()));
        }
        // A core that never answers must not leave the page waiting forever.
        var timer = new CancellationTokenSource(TimeoutFor(channel));
        timer.Token.Register(() =>
        {
            if (pending.TryRemove(id, out var stale))
                stale.TrySetException(new CoreException("VPN 服务响应超时，操作可能仍在进行，请稍后刷新状态。"));
        });
        waiter.Task.ContinueWith(_ => timer.Dispose(), TaskScheduler.Default);
        return waiter.Task;
    }

    /// Longest wait for one reply, covering engine start and slow downloads.
    static TimeSpan TimeoutFor(string channel) => channel switch
    {
        "diagnostics:get-state" or "native:bootstrap" or "vpn:get-status" or "traffic:get-monitor" or "traffic:get-snapshot" or "nodes:list" or "node-groups:list" => TimeSpan.FromSeconds(8),
        "vpn:stop" => TimeSpan.FromSeconds(45),
        "nodes:test" or "nodes:test-recommended" or "connectivity:check" or "connectivity:test-website-speeds" => TimeSpan.FromSeconds(40),
        _ => TimeSpan.FromMinutes(5),
    };

    /// Closing stdin is the core's shutdown signal: it stops its mihomo child.
    public void Shutdown()
    {
        lock (writeLock)
        {
            try { stdin?.Close(); } catch { }
            stdin = null;
        }
        var child = process;
        if (child is null) return;
        try
        {
            if (!child.WaitForExit(10_000)) child.Kill(entireProcessTree: true);
        }
        catch { }
    }

    /// Put the core (and the mihomo it spawns) in a kill-on-close job, so a crash
    /// or forced exit of the UI never leaves an unmanaged TUN behind.
    void KillWithApp(Process child)
    {
        job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) return;
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        var size = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
        var ptr = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(info, ptr, false);
            SetInformationJobObject(job, 9 /* JobObjectExtendedLimitInformation */, ptr, (uint)size);
            AssignProcessToJobObject(job, child.Handle);
        }
        finally { Marshal.FreeHGlobal(ptr); }
        // The handle stays open for the app's lifetime; process exit closes it.
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObjectW(IntPtr attributes, string? name);

    [DllImport("kernel32.dll")]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);

    [DllImport("kernel32.dll")]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
}
