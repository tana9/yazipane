using System.Runtime.InteropServices;
using static Yazipane.Interop.Native;

namespace Yazipane.Launch;

/// <summary>
/// 前回のウィンドウの位置・大きさ・最大化の状態（%LOCALAPPDATA%\yazipane\window.txt）。
/// 中身は 1 行: 「最大化なら 1」 通常時の左 上 右 下（スクリーン座標）。
/// </summary>
internal static unsafe partial class WindowPlacement
{
    public readonly record struct Saved(bool Maximized, int Left, int Top, int Right, int Bottom)
    {
        public override string ToString() => $"{(Maximized ? 1 : 0)} {Left} {Top} {Right} {Bottom}";

        public static Saved? Parse(string text)
        {
            var p = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (p.Length == 5 && p.All(x => int.TryParse(x, out _)))
            {
                var v = p.Select(int.Parse).ToArray();
                if (v[3] - v[1] >= 100 && v[4] - v[2] >= 100)
                {
                    return new Saved(v[0] == 1, v[1], v[2], v[3], v[4]);
                }
            }
            return null;
        }
    }

    private static string FilePath(string stateDir) => Path.Combine(stateDir, "window.txt");

    /// <summary>前回の状態。記録が無い・壊れている・今はどのモニターにも映らない位置なら null。</summary>
    public static Saved? Load(string stateDir)
    {
        try
        {
            var s = Saved.Parse(File.ReadAllText(FilePath(stateDir)).Trim());
            if (s is { } v)
            {
                var r = new RECT { Left = v.Left, Top = v.Top, Right = v.Right, Bottom = v.Bottom };
                if (MonitorFromRect(&r, MONITOR_DEFAULTTONULL) != 0)
                {
                    return v;
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
        return null;
    }

    public static void Apply(nint hwnd, Saved s)
    {
        var wp = new WINDOWPLACEMENT
        {
            length = (uint)sizeof(WINDOWPLACEMENT),
            showCmd = s.Maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL,
            rcNormalPosition = new RECT { Left = s.Left, Top = s.Top, Right = s.Right, Bottom = s.Bottom },
        };
        SetWindowPlacement(hwnd, &wp);
    }

    /// <summary>今の状態。最小化中は記録しない（次回に最小化で開かないよう）ので null。</summary>
    public static Saved? Current(nint hwnd)
    {
        var wp = new WINDOWPLACEMENT { length = (uint)sizeof(WINDOWPLACEMENT) };
        if (GetWindowPlacement(hwnd, &wp) == 0 || wp.showCmd == SW_SHOWMINIMIZED)
        {
            return null;
        }
        var r = wp.rcNormalPosition;
        return new Saved(wp.showCmd == SW_SHOWMAXIMIZED, r.Left, r.Top, r.Right, r.Bottom);
    }

    public static void Save(string stateDir, Saved s)
    {
        try
        {
            File.WriteAllText(FilePath(stateDir), s + "\n");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    private const uint SW_SHOWNORMAL = 1, SW_SHOWMINIMIZED = 2, SW_SHOWMAXIMIZED = 3;
    private const uint MONITOR_DEFAULTTONULL = 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct WINDOWPLACEMENT
    {
        public uint length, flags, showCmd;
        public POINT ptMinPosition, ptMaxPosition;
        public RECT rcNormalPosition;
    }

    [LibraryImport("user32.dll")] private static partial int GetWindowPlacement(nint hwnd, WINDOWPLACEMENT* wp);
    [LibraryImport("user32.dll")] private static partial int SetWindowPlacement(nint hwnd, WINDOWPLACEMENT* wp);
    [LibraryImport("user32.dll")] private static partial nint MonitorFromRect(RECT* rect, uint flags);
}
