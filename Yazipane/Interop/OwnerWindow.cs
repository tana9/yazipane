using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using static Yazipane.Interop.Native;

namespace Yazipane.Interop;

/// <summary>
/// 右クリックメニュー・クリップボード・ファイル操作のダイアログの持ち主になる、見えないウィンドウ。
/// </summary>
internal static unsafe partial class OwnerWindow
{
    public static nint Create()
    {
        var hInst = GetModuleHandleW(null);
        fixed (char* cls = "yazipane.menu")
        {
            var wc = new WNDCLASSEXW
            {
                cbSize = (uint)sizeof(WNDCLASSEXW),
                lpfnWndProc = (nint)(delegate* unmanaged[Stdcall]<nint, uint, nint, nint, nint>)&WndProc,
                hInstance = hInst,
                lpszClassName = (nint)cls,
            };
            // 2 回目以降は「登録済み」で失敗するが、クラスはそのまま使える
            RegisterClassExW(&wc);
            var hwnd = CreateWindowExW(WS_EX_TOOLWINDOW, (nint)cls, 0, WS_POPUP, 0, 0, 0, 0, 0, 0, hInst, 0);
            if (hwnd == 0)
            {
                throw new COMException("ウィンドウを作成できません", Marshal.GetLastPInvokeError());
            }
            return hwnd;
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static nint WndProc(nint hwnd, uint msg, nint wParam, nint lParam) =>
        // 右クリックメニューのサブメニュー（送る、プログラムから開く など）の描画はメニュー側に任せる
        ShellMenu.TryHandleMenuMessage(msg, wParam, lParam, out var result)
            ? result
            : DefWindowProcW(hwnd, msg, wParam, lParam);

    /// <summary>
    /// 前面に出す。yazi（バックグラウンドのプロセス）から起動されると SetForegroundWindow が拒否されるので、
    /// 前面ウィンドウのスレッドに入力を一時的に接続してから前面化する。
    /// </summary>
    public static void ForceForeground(nint hwnd, nint current)
    {
        var me = GetCurrentThreadId();
        var fgThread = current == 0 ? 0 : GetWindowThreadProcessId(current, null);
        if (fgThread != 0 && fgThread != me)
        {
            AttachThreadInput(me, fgThread, 1);
            SetForegroundWindow(hwnd);
            AttachThreadInput(me, fgThread, 0);
        }
        else
        {
            SetForegroundWindow(hwnd);
        }
    }

    /// <summary>オーナーウィンドウ（大きさ 0）を target の中央に置く。ダイアログはオーナーを基準に表示される。</summary>
    public static void CenterOn(nint owner, nint target)
    {
        RECT r;
        if (target != 0 && GetWindowRect(target, &r) != 0)
        {
            SetWindowPos(owner, 0, (r.Left + r.Right) / 2, (r.Top + r.Bottom) / 2, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        }
    }

    private const uint WS_POPUP = 0x80000000, WS_EX_TOOLWINDOW = 0x80;
    private const uint SWP_NOSIZE = 0x1, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10;

    [StructLayout(LayoutKind.Sequential)]
    private struct WNDCLASSEXW
    {
        public uint cbSize; public uint style; public nint lpfnWndProc; public int cbClsExtra; public int cbWndExtra;
        public nint hInstance; public nint hIcon; public nint hCursor; public nint hbrBackground;
        public nint lpszMenuName; public nint lpszClassName; public nint hIconSm;
    }

    [LibraryImport("user32.dll")] private static partial ushort RegisterClassExW(WNDCLASSEXW* wc);
    [LibraryImport("user32.dll", SetLastError = true)]
    private static partial nint CreateWindowExW(uint exStyle, nint cls, nint title, uint style, int x, int y, int w, int h, nint parent, nint menu, nint inst, nint param);
    [LibraryImport("user32.dll")] private static partial nint DefWindowProcW(nint hwnd, uint msg, nint w, nint l);
    [LibraryImport("user32.dll")] private static partial int GetWindowRect(nint hwnd, RECT* rect);
    [LibraryImport("user32.dll")] private static partial int SetWindowPos(nint hwnd, nint after, int x, int y, int cx, int cy, uint flags);
}
