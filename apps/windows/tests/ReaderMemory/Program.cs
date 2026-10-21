using System.Collections.Concurrent;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using Qingzhou;

// Copied apphosts load this same assembly as harmless JSON-line fixtures.
var executable = Path.GetFileNameWithoutExtension(Environment.ProcessPath);
if (executable is "splitvpn-core" or "company-account-helper")
{
    Fixture(executable == "splitvpn-core");
    return;
}

if (!OperatingSystem.IsWindows())
{
    if (!OperatingSystem.IsMacOS()) throw new PlatformNotSupportedException("Run on macOS or Windows.");
    NativeLibrary.SetDllImportResolver(typeof(CoreClient).Assembly, (name, _, _) => name == "kernel32.dll"
        ? NativeLibrary.Load(Path.Combine(AppContext.BaseDirectory, "libreader-job-stub.dylib")) : IntPtr.Zero);
}

const int rounds = 3, perRound = 4000, bytes = 16 * 1024;
const long heapLimit = 8 * 1024 * 1024;
var samples = new List<object>();
var weak = new ConcurrentBag<WeakReference<JsonNode>>();
// Optional negative control must fail the same retained-heap assertion.
var retainedForControl = args.Contains("--retain-events") ? new List<JsonNode>() : null;
var core = new CoreClient();
var helper = new CompanyHelper();
var disconnected = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
var helperDone = new ConcurrentDictionary<int, TaskCompletionSource>();
var helperExit = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
int coreEvents = 0, helperEvents = 0;
var fixturePaths = new[] { "splitvpn-core.exe", "company-account-helper.exe" }
    .Select(name => Path.Combine(AppContext.BaseDirectory, name)).ToArray();
foreach (var path in fixturePaths)
{
    if (File.Exists(path)) throw new InvalidOperationException("Refusing to overwrite a fixture executable.");
    File.Copy(Environment.ProcessPath!, path);
    if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, File.GetUnixFileMode(Environment.ProcessPath!));
}

core.Event += (name, data) =>
{
    if (name == "core:disconnected") { disconnected.TrySetResult(); return; }
    if (name != "fixture:message" || data is null) throw new InvalidOperationException("Unexpected fixture event.");
    var count = Interlocked.Increment(ref coreEvents);
    if (count % 250 == 0) weak.Add(new(data));
    if (count % 16 == 0) retainedForControl?.Add(data);
};

try
{
    await core.Request("fixture:echo");
    helper.Start(new JsonObject { ["type"] = "fixture:ready" }, message =>
    {
        switch (message.At("type").Str())
        {
            case "fixture:ready": ready.TrySetResult(); break;
            case "fixture:message":
                var count = Interlocked.Increment(ref helperEvents);
                if (count % 250 == 0) weak.Add(new(message));
                if (count % 16 == 0) retainedForControl?.Add(message);
                break;
            case "fixture:done": helperDone[(int)message.At("round").Num()!].TrySetResult(); break;
            default: throw new InvalidOperationException("Unexpected helper fixture event.");
        }
    }, status => helperExit.TrySetResult(status));
    await ready.Task.WaitAsync(TimeSpan.FromSeconds(15));

    // Warm up JSON readers, task continuations and their allocator pools first.
    await PumpCore(250);
    await PumpHelper(0, 250);
    var baseline = Sample("warmup", 0);
    for (var round = 1; round <= rounds; round++)
    {
        await PumpCore(perRound);
        await PumpHelper(round, perRound);
        var heap = Sample("round", round);
        Check(heap - baseline < heapLimit, "Retained managed heap grows with consumed messages.");
        Check(weak.Count(w => w.TryGetTarget(out _)) <= 2, "Consumed event objects remain reachable.");
        Check(PendingCount() == 0, "Answered requests remain pending.");
    }
    Check(coreEvents == 1 + 250 + rounds * perRound, "Core events were lost.");
    Check(helperEvents == 250 + rounds * perRound, "Helper events were lost.");
    var stderr = (System.Text.StringBuilder)typeof(CoreClient)
        .GetField("stderrTail", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(core)!;
    lock (stderr) Check(stderr.Length <= 4096, "stderr tail is unbounded.");

    // EOF must reject all in-flight requests rather than retaining their waiters.
    var unanswered = Enumerable.Range(0, 16).Select(_ => core.Request("fixture:no-reply")).ToArray();
    core.Shutdown();
    await disconnected.Task.WaitAsync(TimeSpan.FromSeconds(15));
    foreach (var task in unanswered)
    {
        try { await task; throw new InvalidOperationException("EOF completed a missing reply successfully."); }
        catch (CoreException) { }
    }
    Check(PendingCount() == 0, "Core exit retains pending requests.");
    helper.Send(new JsonObject { ["type"] = "fixture:exit" });
    Check(await helperExit.Task.WaitAsync(TimeSpan.FromSeconds(15)) == 0, "Fixture helper failed to exit.");
    Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new
    {
        passed = true, host = RuntimeInformation.OSDescription,
        productionReaders = new[] { "CoreClient.cs", "Company.cs:CompanyHelper" },
        messagesPerReader = 250 + rounds * perRound, payloadBytes = bytes,
        forcedCollection = true, retainedHeapLimitBytes = heapLimit, samples,
        pendingAfterExit = PendingCount(),
        boundary = "Isolated production .NET readers; WPF, Windows APIs, real VPN and long-run Windows memory not exercised.",
    }, new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
}
finally
{
    helper.Stop();
    core.Shutdown();
    foreach (var path in fixturePaths) File.Delete(path);
}

async Task PumpCore(int count)
{
    for (var i = 0; i < count; i++)
    {
        var result = await core.Request("fixture:echo", new JsonObject { ["sequence"] = i });
        Check(result.At("sequence").Num() == i && result.At("padding").Str()?.Length == bytes,
            "Fragmented UTF-8 reply was lost or corrupted.");
    }
}

async Task PumpHelper(int round, int count)
{
    var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    helperDone[round] = completion;
    helper.Send(new JsonObject { ["type"] = "fixture:pump", ["round"] = round, ["count"] = count });
    await completion.Task.WaitAsync(TimeSpan.FromSeconds(45));
    helperDone.TryRemove(round, out _);
}

long Sample(string stage, int round)
{
    GC.Collect();
    GC.WaitForPendingFinalizers();
    var heap = GC.GetTotalMemory(forceFullCollection: true);
    using var process = Process.GetCurrentProcess();
    samples.Add(new { stage, round, managedHeapBytes = heap, workingSetBytes = process.WorkingSet64 });
    return heap;
}

int PendingCount() => ((ConcurrentDictionary<string, TaskCompletionSource<JsonNode?>>)typeof(CoreClient)
    .GetField("pending", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(core)!).Count;

static void Check(bool value, string message)
{
    if (!value) throw new InvalidOperationException(message);
}

static void Fixture(bool isCore)
{
    Console.InputEncoding = new System.Text.UTF8Encoding(false);
    Console.OutputEncoding = new System.Text.UTF8Encoding(false);
    var padding = "轻舟😀" + new string('x', 16 * 1024 - 4);
    string? line;
    while ((line = Console.ReadLine()) is not null)
    {
        var command = JsonNode.Parse(line)!;
        if (isCore)
        {
            if (command.At("channel").Str() == "fixture:no-reply") continue;
            var data = new JsonObject { ["sequence"] = command.At("payload").At("sequence").Num() ?? 0, ["padding"] = padding };
            Emit(new JsonObject { ["event"] = "fixture:message", ["data"] = data.DeepClone() });
            Emit(new JsonObject { ["id"] = command.At("id").Str(), ["ok"] = true, ["data"] = data });
            Console.Error.WriteLine(new string('e', 128));
        }
        else switch (command.At("type").Str())
        {
            case "fixture:ready": Emit(new JsonObject { ["type"] = "fixture:ready" }); break;
            case "fixture:exit": return;
            case "fixture:pump":
                for (var i = 0; i < command.At("count").Num(); i++)
                    Emit(new JsonObject { ["type"] = "fixture:message", ["sequence"] = i, ["padding"] = padding });
                Emit(new JsonObject { ["type"] = "fixture:done", ["round"] = command.At("round").Num() });
                break;
            default: throw new InvalidOperationException("Unexpected fixture command.");
        }
    }

    static void Emit(JsonObject message)
    {
        var json = message.ToJsonString(new System.Text.Json.JsonSerializerOptions
        {
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        });
        var middle = json.Length / 2;
        Console.Out.Write(json.AsSpan(0, middle));
        Console.Out.Flush();
        Console.Out.WriteLine(json.AsSpan(middle));
        Console.Out.Flush();
    }
}
