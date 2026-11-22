using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Yazipane.Launch;

/// <summary>
/// 起動中の yazipane の記録（%LOCALAPPDATA%\yazipane\instances\&lt;ランチャーの PID&gt;.txt）。
/// <c>--reuse</c> で起動したときに、既に開いているウィンドウへ移動先を伝えるのに使う。
/// 中身は 3 行: 左の yazi のクライアント ID / 右の yazi のクライアント ID / WezTerm の PID。
/// </summary>
internal sealed partial class Instances(string stateDir)
{
    private readonly string _dir = Path.Combine(stateDir, "instances");

    public sealed record Entry(string File, ulong LeftId, ulong RightId, int WeztermPid);

    /// <summary>起動した WezTerm を記録する。戻り値は終了時に消すファイル。</summary>
    public string Add(ulong leftId, ulong rightId, int weztermPid)
    {
        Directory.CreateDirectory(_dir);
        var file = Path.Combine(_dir, $"{Environment.ProcessId}.txt");
        File.WriteAllText(file, $"{leftId}\n{rightId}\n{weztermPid}\n");
        return file;
    }

    public static void Remove(string file)
    {
        try
        {
            File.Delete(file);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    /// <summary>まだ動いている yazipane を新しい順に返す。終了済みの記録は消す。</summary>
    public List<Entry> Alive()
    {
        var list = new List<(Entry Entry, DateTime Time)>();
        if (!Directory.Exists(_dir))
        {
            return [];
        }
        foreach (var file in Directory.EnumerateFiles(_dir, "*.txt"))
        {
            var entry = Parse(file);
            if (entry is not null && IsWezterm(entry.WeztermPid))
            {
                list.Add((entry, File.GetLastWriteTimeUtc(file)));
            }
            else
            {
                Remove(file);
            }
        }
        return [.. list.OrderByDescending(x => x.Time).Select(x => x.Entry)];
    }

    internal static Entry? Parse(string file)
    {
        try
        {
            var lines = File.ReadAllLines(file);
            if (lines.Length >= 3
                && ulong.TryParse(lines[0], out var l) && ulong.TryParse(lines[1], out var r)
                && int.TryParse(lines[2], out var pid))
            {
                return new Entry(file, l, r, pid);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
        return null;
    }

    private static bool IsWezterm(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            return !p.HasExited && p.ProcessName.Equals("wezterm-gui", StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException)
        {
            return false;
        }
    }

    /// <summary>
    /// 起動中のウィンドウで左右のフォルダを開き直し、そのウィンドウを前面に出す。
    /// left / right が null ならフォルダは変えない。ya.exe が無い、または伝えられなければ false。
    /// </summary>
    public static bool Reuse(Entry entry, string? ya, string? left, string? right)
    {
        if (left is not null || right is not null)
        {
            if (ya is null)
            {
                return false;
            }
            if ((left is not null && !EmitCd(ya, entry.LeftId, left)) ||
                (right is not null && !EmitCd(ya, entry.RightId, right)))
            {
                return false;
            }
        }

        using var p = Process.GetProcessById(entry.WeztermPid);
        var hwnd = p.MainWindowHandle;
        if (hwnd != 0)
        {
            if (IsIconic(hwnd) != 0)
            {
                ShowWindow(hwnd, SW_RESTORE);
            }
            Native.SetForegroundWindow(hwnd);
        }
        return true;
    }

    private static bool EmitCd(string ya, ulong id, string dir)
    {
        var psi = new ProcessStartInfo(ya)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
        };
        foreach (var a in new[] { "emit-to", id.ToString(), "cd", dir })
        {
            psi.ArgumentList.Add(a);
        }
        using var p = Process.Start(psi);
        if (p is null)
        {
            return false;
        }
        var err = p.StandardError.ReadToEnd();
        p.WaitForExit();
        Log.Write($"reuse: ya emit-to {id} cd {dir} -> {p.ExitCode} {err.Trim()}");
        return p.ExitCode == 0;
    }

    private const int SW_RESTORE = 9;

    [LibraryImport("user32.dll")] private static partial int IsIconic(nint hwnd);
    [LibraryImport("user32.dll")] private static partial int ShowWindow(nint hwnd, int cmd);
}
