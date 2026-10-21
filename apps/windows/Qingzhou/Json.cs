using System.Text.Json.Nodes;

namespace Qingzhou;

/// Null-tolerant readers for the core's loosely typed JSON.
public static class J
{
    public static JsonNode? At(this JsonNode? node, string key) =>
        node is JsonObject o && o.TryGetPropertyValue(key, out var v) ? v : null;

    public static string? Str(this JsonNode? node) =>
        node is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    public static bool? Bool(this JsonNode? node) =>
        node is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;

    public static double? Num(this JsonNode? node)
    {
        if (node is not JsonValue v) return null;
        if (v.TryGetValue<double>(out var d)) return d;
        if (v.TryGetValue<long>(out var l)) return l;
        if (v.TryGetValue<int>(out var i)) return i;
        return null;
    }

    public static IEnumerable<JsonNode> Items(this JsonNode? node) =>
        node is JsonArray a ? a.Where(x => x is not null).Select(x => x!) : [];

    public static IEnumerable<string> Strings(this JsonNode? node) =>
        node.Items().Select(x => x.Str()).Where(x => x is not null).Select(x => x!);

    public static JsonArray Array(IEnumerable<string> values) =>
        new(values.Select(v => (JsonNode?)JsonValue.Create(v)).ToArray());
}
