using System.Text;
using System.Text.Json.Nodes;

namespace Qingzhou;

/// Current-user DPAPI; neither settings nor diagnostic exports contain passwords.
public static class StaticExitVault
{
    static string FilePath => Path.Combine(Paths.Dir, "static-exit.bin");
    public static JsonObject? Load() => File.Exists(FilePath)
        ? JsonNode.Parse(Encoding.UTF8.GetString(RiskKeyVault.Transform(File.ReadAllBytes(FilePath), false))) as JsonObject : null;

    public static void Save(JsonObject? credential)
    {
        if (credential is null) { if (File.Exists(FilePath)) File.Delete(FilePath); return; }
        var bytes = RiskKeyVault.Transform(Encoding.UTF8.GetBytes(credential.ToJsonString()), true);
        Directory.CreateDirectory(Paths.Dir);
        var temporary = FilePath + ".tmp-" + Guid.NewGuid().ToString("N");
        try { File.WriteAllBytes(temporary, bytes); File.Move(temporary, FilePath, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
