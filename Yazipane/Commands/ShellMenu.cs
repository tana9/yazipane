using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using static Yazipane.Interop.Native;

namespace Yazipane.Commands;

/// <summary>
/// エクスプローラーと同じ右クリックメニュー（IContextMenu）をマウス位置に表示する。
/// 先頭に yazipane 独自の項目を追加し、それが選ばれた場合は動作名を標準出力に書く（yazi 側のプラグインが実行する）。
/// </summary>
internal static unsafe partial class ShellMenu
{
    /// <summary>yazipane 独自の項目（id, 表示名, 標準出力に書く動作名）</summary>
    private static readonly (uint Id, string Label, string Action)[] s_customItems =
    [
        (1, "反対ペインへコピー\tF5", "copy"),
        (2, "反対ペインへ移動\tF6", "move"),
        (3, "パスをコピー", "copypath"),
    ];

    private const uint ShellIdFirst = 100;
    private const uint ShellIdLast = 0x7FFF;

    private static nint s_cm2;
    private static nint s_cm3;

    public static int Run(string[] paths)
    {
        if (paths.Length == 0)
        {
            Console.Error.WriteLine("パスが指定されていません");
            return 2;
        }

        OleInitialize(0);
        ShellItems? items = null;
        nint cm = 0, hwnd = 0, hmenu = 0;
        try
        {
            // 最初のパスの親フォルダを基準にし、同じフォルダにあるものだけを対象にする
            items = ShellItems.Parse(paths);
            var parentDir = items.ParentDir;

            hwnd = OwnerWindow.Create();
            cm = items.GetUIObject(hwnd, IID_IContextMenu);
            // サブメニュー（送る、プログラムから開く など）の描画に必要
            var iid3 = IID_IContextMenu3;
            var iid2 = IID_IContextMenu2;
            nint tmp;
            if (Com.QueryInterface(cm, &iid3, &tmp) >= 0)
            {
                s_cm3 = tmp;
            }
            else if (Com.QueryInterface(cm, &iid2, &tmp) >= 0)
            {
                s_cm2 = tmp;
            }

            hmenu = CreatePopupMenu();
            foreach (var (id, label, _) in s_customItems)
            {
                AppendMenuW(hmenu, MF_STRING, id, label);
            }
            AppendMenuW(hmenu, MF_SEPARATOR, 0, null);

            uint flags = CMF_NORMAL;
            if ((GetKeyState(VK_SHIFT) & 0x8000) != 0)
            {
                flags |= CMF_EXTENDEDVERBS;
            }
            Com.Check(ContextMenu_QueryContextMenu(cm, hmenu, (uint)GetMenuItemCount(hmenu), ShellIdFirst, ShellIdLast, flags));

            POINT pt;
            GetCursorPos(&pt);
            // メニューの外をクリックしたときに閉じるには、オーナーウィンドウが前面である必要がある
            var previous = GetForegroundWindow();
            OwnerWindow.ForceForeground(hwnd, previous);

            var cmd = (uint)TrackPopupMenuEx(hmenu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.X, pt.Y, hwnd, 0);
            PostMessageW(hwnd, WM_NULL, 0, 0);
            Log.Write($"menu: items={items.Count} cmd={cmd}" +
                      (cmd >= ShellIdFirst ? $" verb={GetVerb(cm, cmd - ShellIdFirst)}" : ""));

            if (cmd == 0)
            {
                SetForegroundWindow(previous);
                return 0;
            }

            foreach (var (id, _, action) in s_customItems)
            {
                if (id == cmd)
                {
                    SetForegroundWindow(previous);
                    Console.Out.Write(action);
                    Console.Out.Flush();
                    return 0;
                }
            }

            if (cmd >= ShellIdFirst)
            {
                // エクスプローラーの外では動かない項目は yazi 側で処理する
                if (s_yaziHandledVerbs.TryGetValue(GetVerb(cm, cmd - ShellIdFirst) ?? "", out var yaziAction))
                {
                    SetForegroundWindow(previous);
                    Console.Out.Write(yaziAction);
                    Console.Out.Flush();
                    return 0;
                }
                Invoke(cm, hwnd, cmd - ShellIdFirst, parentDir, pt);
                // プロパティ等のダイアログはこのプロセス内で動くので、閉じられるまで終了しない
                WaitForOwnWindows(hwnd);
            }
            return 0;
        }
        catch (COMException e)
        {
            Console.Error.WriteLine(e.Message);
            return 1;
        }
        finally
        {
            if (hmenu != 0) DestroyMenu(hmenu);
            if (s_cm3 != 0) Com.Release(s_cm3);
            if (s_cm2 != 0) Com.Release(s_cm2);
            if (cm != 0) Com.Release(cm);
            items?.Dispose();
            if (hwnd != 0) DestroyWindow(hwnd);
            OleUninitialize();
        }
    }

    /// <summary>シェルの verb → yazi に任せる動作名（「名前の変更」はエクスプローラーのビュー以外では何も起きない）</summary>
    private static readonly Dictionary<string, string> s_yaziHandledVerbs = new(StringComparer.OrdinalIgnoreCase)
    {
        ["rename"] = "rename",
    };

    /// <summary>メニュー項目の正規の verb 名（"open", "rename" など）。取れない項目は null。</summary>
    private static string? GetVerb(nint cm, uint offset)
    {
        const uint GCS_VERBW = 4;
        var buf = stackalloc char[256];
        buf[0] = '\0';
        var hr = ContextMenu_GetCommandString(cm, offset, GCS_VERBW, null, (byte*)buf, 256);
        return hr < 0 ? null : new string(buf);
    }

    private static void Invoke(nint cm, nint hwnd, uint verb, string? dir, POINT pt)
    {
        var dirPtr = dir is null ? 0 : Marshal.StringToHGlobalUni(dir);
        try
        {
            var info = new CMINVOKECOMMANDINFOEX
            {
                cbSize = (uint)sizeof(CMINVOKECOMMANDINFOEX),
                fMask = CMIC_MASK_UNICODE | CMIC_MASK_PTINVOKE,
                hwnd = hwnd,
                lpVerb = (nint)verb,
                lpVerbW = (nint)verb,
                lpDirectoryW = dirPtr,
                nShow = SW_SHOWNORMAL,
                ptInvoke = pt,
            };
            if ((GetKeyState(VK_CONTROL) & 0x8000) != 0) info.fMask |= CMIC_MASK_CONTROL_DOWN;
            if ((GetKeyState(VK_SHIFT) & 0x8000) != 0) info.fMask |= CMIC_MASK_SHIFT_DOWN;
            Com.Check(ContextMenu_InvokeCommand(cm, &info));
        }
        finally
        {
            if (dirPtr != 0) Marshal.FreeHGlobal(dirPtr);
        }
    }

    /// <summary>
    /// オーナーウィンドウに届いたメッセージのうち、サブメニュー（送る、プログラムから開く など）の描画に必要なものをメニューに渡す。
    /// 処理したら true。
    /// </summary>
    internal static bool TryHandleMenuMessage(uint msg, nint wParam, nint lParam, out nint result)
    {
        result = 0;
        if (msg is not (WM_INITMENUPOPUP or WM_DRAWITEM or WM_MEASUREITEM or WM_MENUCHAR))
        {
            return false;
        }
        if (s_cm3 != 0)
        {
            nint r;
            if (ContextMenu3_HandleMenuMsg2(s_cm3, msg, wParam, lParam, &r) >= 0)
            {
                result = r;
                return true;
            }
        }
        else if (s_cm2 != 0 && msg != WM_MENUCHAR)
        {
            if (ContextMenu2_HandleMenuMsg(s_cm2, msg, wParam, lParam) >= 0)
            {
                result = msg == WM_INITMENUPOPUP ? 0 : 1;
                return true;
            }
        }
        return false;
    }

    // ---- 実行後の待機 ----

    private static nint s_ignoreHwnd;
    private static int s_visibleCount;

    private static void WaitForOwnWindows(nint owner)
    {
        s_ignoreHwnd = owner;
        var pid = (uint)Environment.ProcessId;
        var start = Environment.TickCount64;
        long lastSeen = start;
        MSG msg;
        while (true)
        {
            while (PeekMessageW(&msg, 0, 0, 0, PM_REMOVE) != 0)
            {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }

            s_visibleCount = 0;
            EnumWindows(&CountOwnWindows, (nint)pid);
            var now = Environment.TickCount64;
            if (s_visibleCount > 0)
            {
                lastSeen = now;
            }
            // ダイアログが少し遅れて出ることがあるので、最後に見えてから 1.5 秒待つ
            else if (now - lastSeen > 1500)
            {
                return;
            }
            MsgWaitForMultipleObjects(0, null, 0, 100, QS_ALLINPUT);
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static int CountOwnWindows(nint hwnd, nint lParam)
    {
        uint pid;
        GetWindowThreadProcessId(hwnd, &pid);
        if (pid == (uint)lParam && hwnd != s_ignoreHwnd && IsWindowVisible(hwnd) != 0)
        {
            s_visibleCount++;
        }
        return 1;
    }

    // ---- COM（vtable を直接呼ぶ。トリミング/AOT でも壊れない） ----

    private static Guid IID_IContextMenu => new("000214E4-0000-0000-C000-000000000046");
    private static Guid IID_IContextMenu2 => new("000214F4-0000-0000-C000-000000000046");
    private static Guid IID_IContextMenu3 => new("BCFCE0A0-EC17-11D0-8D10-00A0C90F2719");

    // IContextMenu::QueryContextMenu (3), InvokeCommand (4)
    private static int ContextMenu_QueryContextMenu(nint p, nint hmenu, uint index, uint first, uint last, uint flags) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, uint, uint, uint, uint, int>)Com.Vtbl(p)[3])(p, hmenu, index, first, last, flags);

    private static int ContextMenu_InvokeCommand(nint p, CMINVOKECOMMANDINFOEX* info) =>
        ((delegate* unmanaged[Stdcall]<nint, CMINVOKECOMMANDINFOEX*, int>)Com.Vtbl(p)[4])(p, info);

    // IContextMenu::GetCommandString (5)
    private static int ContextMenu_GetCommandString(nint p, nuint idCmd, uint type, uint* reserved, byte* name, uint cch) =>
        ((delegate* unmanaged[Stdcall]<nint, nuint, uint, uint*, byte*, uint, int>)Com.Vtbl(p)[5])(p, idCmd, type, reserved, name, cch);

    // IContextMenu2::HandleMenuMsg (6), IContextMenu3::HandleMenuMsg2 (7)
    private static int ContextMenu2_HandleMenuMsg(nint p, uint msg, nint w, nint l) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, nint, nint, int>)Com.Vtbl(p)[6])(p, msg, w, l);

    private static int ContextMenu3_HandleMenuMsg2(nint p, uint msg, nint w, nint l, nint* result) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, nint, nint, nint*, int>)Com.Vtbl(p)[7])(p, msg, w, l, result);

    // ---- Win32 ----

    private const uint MF_STRING = 0x0, MF_SEPARATOR = 0x800;
    private const uint CMF_NORMAL = 0x0, CMF_EXTENDEDVERBS = 0x100;
    private const uint TPM_RETURNCMD = 0x100, TPM_RIGHTBUTTON = 0x2;
    private const uint CMIC_MASK_UNICODE = 0x4000, CMIC_MASK_PTINVOKE = 0x20000000;
    private const uint CMIC_MASK_SHIFT_DOWN = 0x10000000, CMIC_MASK_CONTROL_DOWN = 0x40000000;
    private const int SW_SHOWNORMAL = 1;
    private const int VK_SHIFT = 0x10, VK_CONTROL = 0x11;
    private const uint WM_NULL = 0x0, WM_DRAWITEM = 0x2B, WM_MEASUREITEM = 0x2C, WM_INITMENUPOPUP = 0x117, WM_MENUCHAR = 0x120;
    private const uint PM_REMOVE = 0x1, QS_ALLINPUT = 0x4FF;

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public nint hwnd; public uint message; public nint wParam; public nint lParam; public uint time; public POINT pt; public uint lPrivate;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CMINVOKECOMMANDINFOEX
    {
        public uint cbSize; public uint fMask; public nint hwnd;
        public nint lpVerb; public nint lpParameters; public nint lpDirectory;
        public int nShow; public uint dwHotKey; public nint hIcon; public nint lpTitle;
        public nint lpVerbW; public nint lpParametersW; public nint lpDirectoryW; public nint lpTitleW;
        public POINT ptInvoke;
    }

    [LibraryImport("user32.dll")] private static partial nint CreatePopupMenu();
    [LibraryImport("user32.dll")] private static partial int DestroyMenu(nint hmenu);
    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int AppendMenuW(nint hmenu, uint flags, nuint id, string? item);
    [LibraryImport("user32.dll")] private static partial int GetMenuItemCount(nint hmenu);
    [LibraryImport("user32.dll")] private static partial int TrackPopupMenuEx(nint hmenu, uint flags, int x, int y, nint hwnd, nint tpm);
    [LibraryImport("user32.dll")] private static partial int GetCursorPos(POINT* pt);
    [LibraryImport("user32.dll")] private static partial short GetKeyState(int vk);
    [LibraryImport("user32.dll")] private static partial int PostMessageW(nint hwnd, uint msg, nint w, nint l);
    [LibraryImport("user32.dll")] private static partial int PeekMessageW(MSG* msg, nint hwnd, uint min, uint max, uint remove);
    [LibraryImport("user32.dll")] private static partial int TranslateMessage(MSG* msg);
    [LibraryImport("user32.dll")] private static partial nint DispatchMessageW(MSG* msg);
    [LibraryImport("user32.dll")] private static partial uint MsgWaitForMultipleObjects(uint count, nint* handles, int waitAll, uint ms, uint wakeMask);
    [LibraryImport("user32.dll")] private static partial int EnumWindows(delegate* unmanaged[Stdcall]<nint, nint, int> fn, nint lParam);
    [LibraryImport("user32.dll")] private static partial int IsWindowVisible(nint hwnd);
}
