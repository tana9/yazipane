using System.Text;

namespace Yazipane.Commands;

/// <summary>名前付きの左右フォルダを保存する。</summary>
internal static class FolderPairs
{
    internal const int MaxPairs = 36;

    public static int Run(string[] args)
    {
        var root = Environment.GetEnvironmentVariable("YAZIPANE_STATE_DIR");
        if (string.IsNullOrEmpty(root)) throw new UserFacingException("保存先が指定されていません");
        var dir = Path.Combine(root, "pairs");
        if (args.Length == 1 && args[0] == "list")
        {
            foreach (var p in List(dir)) Console.Out.WriteLine($"{p.Name}\t{p.Left}\t{p.Right}");
            return 0;
        }
        if (args.Length == 4 && args[0] == "save")
        {
            Save(dir, args[1], args[2], args[3]);
            return 0;
        }
        if (args.Length == 2 && args[0] == "delete")
        {
            Delete(dir, args[1]);
            return 0;
        }
        throw new UserFacingException("使い方: --pairs list | save <名前> <左> <右> | delete <名前>");
    }

    internal sealed record Pair(string Name, string Left, string Right);

    private static string Key(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Length > 80 || name.Any(char.IsControl))
            throw new UserFacingException("名前は 1〜80 文字で入力してください");
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(name))) + ".txt";
    }

    internal static List<Pair> List(string dir)
    {
        if (!Directory.Exists(dir)) return [];
        var result = new List<Pair>();
        foreach (var file in Directory.EnumerateFiles(dir, "*.txt"))
        {
            var lines = File.ReadAllLines(file, Encoding.UTF8);
            if (lines.Length != 3 || lines.Any(string.IsNullOrEmpty))
                throw new UserFacingException($"フォルダの組を読み取れません: {file}");
            result.Add(new Pair(lines[0], lines[1], lines[2]));
        }
        return [.. result.OrderBy(p => p.Name, StringComparer.OrdinalIgnoreCase)];
    }

    internal static void Save(string dir, string name, string left, string right)
    {
        var key = Key(name);
        if (!Directory.Exists(left) || !Directory.Exists(right)) throw new UserFacingException("保存するフォルダが見つかりません");
        if (left.Any(char.IsControl) || right.Any(char.IsControl)) throw new UserFacingException("フォルダ名に使用できない文字があります");
        Directory.CreateDirectory(dir);
        using var mutex = new Mutex(false, @"Local\yazipane-pairs");
        var owned = false;
        try
        {
            try { owned = mutex.WaitOne(TimeSpan.FromSeconds(10)); }
            catch (AbandonedMutexException) { owned = true; }
            if (!owned) throw new UserFacingException("保存を待ちきれませんでした");
            var path = Path.Combine(dir, key);
            if (!File.Exists(path) && List(dir).Count >= MaxPairs) throw new UserFacingException($"保存できる組は {MaxPairs} 件までです");
            var tmp = Path.Combine(dir, $"{Guid.NewGuid():N}.tmp");
            try
            {
                File.WriteAllLines(tmp, [name, left, right], new UTF8Encoding(false));
                File.Move(tmp, path, overwrite: true);
            }
            finally { File.Delete(tmp); }
        }
        finally { if (owned) mutex.ReleaseMutex(); }
    }

    internal static void Delete(string dir, string name)
    {
        var path = Path.Combine(dir, Key(name));
        if (!File.Exists(path)) throw new UserFacingException("保存された組が見つかりません");
        File.Delete(path);
    }
}
