namespace Yazipane.Common;

internal static class Files
{
    /// <summary>内容が変わったときだけ書き込む。</summary>
    public static void WriteIfChanged(string path, byte[] data)
    {
        if (File.Exists(path) && File.ReadAllBytes(path).AsSpan().SequenceEqual(data))
        {
            return;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, data);
    }

    /// <summary>src の内容を dst にコピーし、src に無いものを dst から消す。</summary>
    public static void SyncDir(string src, string dst)
    {
        if (File.Exists(dst))
        {
            File.Delete(dst);
        }
        Directory.CreateDirectory(dst);
        HashSet<string> seen = [with(StringComparer.OrdinalIgnoreCase)];

        foreach (var p in Directory.EnumerateFileSystemEntries(src, "*", SearchOption.AllDirectories))
        {
            var rel = Path.GetRelativePath(src, p);
            seen.Add(rel);
            var outPath = Path.Combine(dst, rel);
            // 同じ名前でもファイル / フォルダの種類が違うものが dst に残っていたら、先に消す
            // （そのままでは書き込みに失敗し、生成先を手で消すまで毎回起動できなくなる）
            if (Directory.Exists(p))
            {
                if (File.Exists(outPath))
                {
                    File.Delete(outPath);
                }
                Directory.CreateDirectory(outPath);
            }
            else
            {
                if (Directory.Exists(outPath))
                {
                    Directory.Delete(outPath, recursive: true);
                }
                WriteIfChanged(outPath, File.ReadAllBytes(p));
            }
        }

        foreach (var p in Directory.EnumerateFiles(dst, "*", SearchOption.AllDirectories).ToList())
        {
            if (!seen.Contains(Path.GetRelativePath(dst, p)))
            {
                File.Delete(p);
            }
        }
        // 深い階層から消す
        foreach (var p in Directory.EnumerateDirectories(dst, "*", SearchOption.AllDirectories)
                     .OrderByDescending(p => p.Length).ToList())
        {
            if (!seen.Contains(Path.GetRelativePath(dst, p)) && Directory.Exists(p))
            {
                Directory.Delete(p, recursive: true);
            }
        }
    }

    public static bool SameDir(string a, string b) =>
        string.Equals(
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(a)),
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(b)),
            StringComparison.OrdinalIgnoreCase);
}
