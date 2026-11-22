namespace Yazipane.Common;

/// <summary>デバッグ時のみ、起動セッションとプロセスごとに別ファイルへ記録する。</summary>
internal static class Log
{
    private static string? s_path;

    public static void Enable(string directory, string name)
    {
        try
        {
            Directory.CreateDirectory(directory);
            s_path = Path.Combine(directory, $"{name}-{Environment.ProcessId}.log");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            s_path = null;
        }
    }

    /// <summary>
    /// root 直下の起動ごとのログフォルダを新しい順に keep 件だけ残し、古いものを消す。
    /// 使用中（別の yazipane が書き込み中）などで消せないものは残す。
    /// </summary>
    public static void Prune(string root, int keep)
    {
        try
        {
            var old = new DirectoryInfo(root).EnumerateDirectories()
                .OrderByDescending(d => d.CreationTimeUtc)
                .Skip(keep)
                .ToList();
            foreach (var d in old)
            {
                try
                {
                    d.Delete(recursive: true);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // ログの掃除の失敗で起動を失敗させない。
        }
    }

    public static void Write(string message)
    {
        if (s_path is null) return;
        try
        {
            File.AppendAllText(s_path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {message}\n");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // ログの失敗でアプリ本体の操作を失敗させない。
        }
    }
}
