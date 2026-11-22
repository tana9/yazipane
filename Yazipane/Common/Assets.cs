using System.Reflection;

namespace Yazipane.Common;

/// <summary>exe に埋め込んだ assets/ 以下のファイルへのアクセス。リソース名は "assets/..." のパス。</summary>
internal static class Assets
{
    private static readonly Assembly s_assembly = typeof(Assets).Assembly;

    private static string Normalize(string name) => name.Replace('\\', '/');

    public static byte[] Read(string name)
    {
        var actual = s_assembly.GetManifestResourceNames().FirstOrDefault(n => Normalize(n) == name)
            ?? throw new FileNotFoundException($"埋め込みリソースがありません: {name}");
        using var s = s_assembly.GetManifestResourceStream(actual)!;
        using var ms = new MemoryStream();
        s.CopyTo(ms);
        return ms.ToArray();
    }

    /// <summary>root（例: "assets/yazi/plugins"）以下の埋め込みファイルを dst に書き出す。</summary>
    public static void Extract(string root, string dst)
    {
        var prefix = root.TrimEnd('/') + "/";
        foreach (var raw in s_assembly.GetManifestResourceNames())
        {
            var name = Normalize(raw);
            if (!name.StartsWith(prefix, StringComparison.Ordinal))
            {
                continue;
            }
            var rel = name[prefix.Length..].Replace('/', Path.DirectorySeparatorChar);
            Files.WriteIfChanged(Path.Combine(dst, rel), Read(name));
        }
    }
}
