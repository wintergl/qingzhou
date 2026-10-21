using System.Buffers.Binary;
using System.Collections;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Resources;
using System.Security.Cryptography;
using System.Text.Json;

if (args.Length != 2) throw new ArgumentException("Expected application DLL and tray manifest paths.");
using var source = File.OpenRead(args[0]);
using var pe = new PEReader(source);
var metadata = pe.GetMetadataReader();
var resource = metadata.ManifestResources.Select(metadata.GetManifestResource)
    .Single(r => metadata.GetString(r.Name) == "Qingzhou.g.resources");
if (!resource.Implementation.IsNil) throw new InvalidOperationException("Expected embedded resources.");
var content = pe.GetSectionData(pe.PEHeaders.CorHeader!.ResourcesDirectory.RelativeVirtualAddress).GetContent().ToArray();
var offset = checked((int)resource.Offset);
var length = BinaryPrimitives.ReadInt32LittleEndian(content.AsSpan(offset));
using var data = new MemoryStream(content, offset + 4, length, writable: false);
using var reader = new ResourceReader(data);
var hashes = new Dictionary<string, string>();
foreach (DictionaryEntry entry in reader)
{
    if (entry.Key is not string key || !key.StartsWith("assets/tray/")) continue;
    using var bytes = new MemoryStream();
    if (entry.Value is Stream stream) stream.CopyTo(bytes);
    else throw new InvalidOperationException("Expected a stream resource.");
    hashes.Add(Path.GetFileName(key), Convert.ToHexString(SHA256.HashData(bytes.ToArray())).ToLowerInvariant());
}
using var manifest = JsonDocument.Parse(File.ReadAllText(args[1]));
var expected = manifest.RootElement.GetProperty("files").EnumerateArray()
    .ToDictionary(f => f.GetProperty("file").GetString()!, f => f.GetProperty("sha256").GetString()!);
if (hashes.Count != 32 || hashes.Count != expected.Count || expected.Any(p => !hashes.TryGetValue(p.Key, out var hash) || hash != p.Value))
    throw new InvalidOperationException("Embedded tray icons do not match the macOS export.");
Console.WriteLine("32 embedded tray icon resources match the macOS renderer export byte for byte (metadata-only; no Windows UI loaded).");
