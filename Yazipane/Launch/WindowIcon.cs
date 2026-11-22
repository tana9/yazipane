using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Yazipane.Launch;

/// <summary>
/// WezTerm のウィンドウに yazipane のアイコンと AppUserModelID を設定する。
/// - WM_SETICON: タイトルバー / Alt+Tab のアイコン
/// - AppUserModelID: タスクバーで普段の WezTerm と別のグループにし、yazipane のアイコンで表示する
/// アイコンは読み込んだプロセスが持ち主なので、WezTerm が終了するまでこのプロセスを残しておく。
/// </summary>
internal static unsafe partial class WindowIcon
{
    private const string AppId = "tana9.yazipane";

    /// <param name="stateDir">ウィンドウの位置を記録する場所</param>
    /// <param name="restore">前回のウィンドウの位置（null なら WezTerm 側で最大化している）</param>
    public static void ApplyAndWait(Process wezterm, string stateDir, WindowPlacement.Saved? restore)
    {
        var hwnd = WaitForMainWindow(wezterm, TimeSpan.FromSeconds(30));
        if (hwnd == 0)
        {
            Log.Write("window icon: WezTerm のウィンドウが見つからない");
            return;
        }
        Log.Write($"window icon: hwnd=0x{hwnd:X} restore={restore}");

        if (restore is { } r)
        {
            WindowPlacement.Apply(hwnd, r);
        }
        SetAppUserModelId(hwnd);

        // 終了まで時々確認し、WezTerm 側でアイコンが設定し直された場合は付け直す。
        // 拡大率の違うモニターへ移った（DPI が変わった）場合は、その大きさで読み直す。
        // ウィンドウの位置・大きさが変わったら、次回の起動のために記録する。
        var dpi = WindowDpi(hwnd);
        var (big, small) = LoadIcons(hwnd, dpi);
        var placement = WindowPlacement.Current(hwnd);
        while (!wezterm.WaitForExit(1000))
        {
            if (WindowPlacement.Current(hwnd) is { } current && current != placement)
            {
                placement = current;
                WindowPlacement.Save(stateDir, current);
            }

            var now = WindowDpi(hwnd);
            if (now != dpi)
            {
                var (oldBig, oldSmall) = (big, small);
                dpi = now;
                (big, small) = LoadIcons(hwnd, dpi);
                DestroyIconIfAny(oldBig);
                DestroyIconIfAny(oldSmall);
            }
            else if (big != 0 && SendMessageW(hwnd, WM_GETICON, ICON_BIG, 0) != big)
            {
                SendMessageW(hwnd, WM_SETICON, ICON_BIG, big);
                SendMessageW(hwnd, WM_SETICON, ICON_SMALL, small);
            }
        }
    }

    private static uint WindowDpi(nint hwnd)
    {
        var dpi = GetDpiForWindow(hwnd);
        return dpi == 0 ? 96 : dpi;
    }

    private static void DestroyIconIfAny(nint icon)
    {
        if (icon != 0)
        {
            DestroyIcon(icon);
        }
    }

    private static nint WaitForMainWindow(Process p, TimeSpan timeout)
    {
        var sw = Stopwatch.StartNew();
        while (sw.Elapsed < timeout)
        {
            if (p.HasExited)
            {
                return 0;
            }
            p.Refresh();
            if (p.MainWindowHandle != 0)
            {
                return p.MainWindowHandle;
            }
            Thread.Sleep(200);
        }
        return 0;
    }

    private static (nint Big, nint Small) LoadIcons(nint hwnd, uint dpi)
    {
        int bigSize = GetSystemMetricsForDpi(SM_CXICON, dpi), smallSize = GetSystemMetricsForDpi(SM_CXSMICON, dpi);

        // ApplicationIcon で埋め込んだアイコン（リソース ID 32512）を、ウィンドウの DPI に合った大きさで読む
        var hInst = Native.GetModuleHandleW(null);
        var big = LoadImageW(hInst, AppIconResourceId, IMAGE_ICON, bigSize, bigSize, 0);
        var small = LoadImageW(hInst, AppIconResourceId, IMAGE_ICON, smallSize, smallSize, 0);
        if (big == 0 || small == 0)
        {
            // リソース ID が違う場合の予備: exe の最初のアイコン
            nint l = 0, s = 0;
            ExtractIconExW(Environment.ProcessPath ?? "", 0, &l, &s, 1);
            big = big != 0 ? big : l;
            small = small != 0 ? small : s;
        }
        Log.Write($"window icon: dpi={dpi} big={bigSize}px(0x{big:X}) small={smallSize}px(0x{small:X})");

        if (big != 0)
        {
            SendMessageW(hwnd, WM_SETICON, ICON_BIG, big);
        }
        if (small != 0)
        {
            SendMessageW(hwnd, WM_SETICON, ICON_SMALL, small);
        }
        return (big, small);
    }

    /// <summary>
    /// ウィンドウ単位の AppUserModelID を設定する。タスクバーで普段の WezTerm と別グループになり、
    /// ピン留めしたときは yazipane.exe が起動されるようにする。
    /// </summary>
    private static void SetAppUserModelId(nint hwnd)
    {
        var iid = IID_IPropertyStore;
        nint store;
        var hr = SHGetPropertyStoreForWindow(hwnd, &iid, &store);
        if (hr < 0)
        {
            Log.Write($"window icon: SHGetPropertyStoreForWindow failed 0x{hr:X8}");
            return;
        }
        try
        {
            var exe = Environment.ProcessPath ?? "";
            SetString(store, PKEY_AppUserModel_ID, AppId);
            SetString(store, PKEY_AppUserModel_RelaunchCommand, $"\"{exe}\"");
            SetString(store, PKEY_AppUserModel_RelaunchIconResource, $"{exe},0");
            SetString(store, PKEY_AppUserModel_RelaunchDisplayNameResource, "yazipane");
            ((delegate* unmanaged[Stdcall]<nint, int>)Com.Vtbl(store)[7])(store); // Commit
        }
        finally
        {
            Com.Release(store);
        }
    }

    private static void SetString(nint store, PROPERTYKEY key, string value)
    {
        var str = Marshal.StringToCoTaskMemUni(value);
        try
        {
            var pv = new PROPVARIANT { vt = VT_LPWSTR, p = str };
            // IPropertyStore::SetValue (vtable 6)。値はコピーされるので、呼び出し後に解放してよい
            var hr = ((delegate* unmanaged[Stdcall]<nint, PROPERTYKEY*, PROPVARIANT*, int>)Com.Vtbl(store)[6])(store, &key, &pv);
            if (hr < 0)
            {
                Log.Write($"window icon: SetValue failed 0x{hr:X8}");
            }
        }
        finally
        {
            Marshal.FreeCoTaskMem(str);
        }
    }

    // ---- Win32 ----

    private const uint WM_SETICON = 0x80, WM_GETICON = 0x7F;
    private const nint ICON_SMALL = 0, ICON_BIG = 1;
    private const uint IMAGE_ICON = 1;
    private const int SM_CXICON = 11, SM_CXSMICON = 49;
    private const ushort VT_LPWSTR = 31;
    private const nint AppIconResourceId = 32512;

    private static Guid IID_IPropertyStore => new("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    private static Guid FMTID_AppUserModel => new("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    private static PROPERTYKEY PKEY_AppUserModel_RelaunchCommand => new(FMTID_AppUserModel, 2);
    private static PROPERTYKEY PKEY_AppUserModel_RelaunchIconResource => new(FMTID_AppUserModel, 3);
    private static PROPERTYKEY PKEY_AppUserModel_RelaunchDisplayNameResource => new(FMTID_AppUserModel, 4);
    private static PROPERTYKEY PKEY_AppUserModel_ID => new(FMTID_AppUserModel, 5);

    [StructLayout(LayoutKind.Sequential)]
    private struct PROPERTYKEY(Guid fmtid, uint pid)
    {
        public Guid fmtid = fmtid;
        public uint pid = pid;
    }

    // PROPVARIANT（x64 では 24 バイト）。文字列（VT_LPWSTR）だけを使う
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct PROPVARIANT
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public nint p;
    }

    [LibraryImport("user32.dll")] private static partial nint SendMessageW(nint hwnd, uint msg, nint w, nint l);
    [LibraryImport("user32.dll")] private static partial uint GetDpiForWindow(nint hwnd);
    [LibraryImport("user32.dll")] private static partial int DestroyIcon(nint icon);
    [LibraryImport("user32.dll")] private static partial int GetSystemMetricsForDpi(int index, uint dpi);
    [LibraryImport("user32.dll")] private static partial nint LoadImageW(nint hInst, nint name, uint type, int cx, int cy, uint flags);
    [LibraryImport("shell32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial uint ExtractIconExW(string file, int index, nint* large, nint* small, uint count);
    [LibraryImport("shell32.dll")] private static partial int SHGetPropertyStoreForWindow(nint hwnd, Guid* riid, nint* ppv);
}
