using System.Runtime.InteropServices;
using static Yazipane.Commands.Clipboard;
using static Yazipane.Interop.Native;

namespace Yazipane.Commands;

/// <summary>
/// ファイルをほかのアプリへ渡す（エクスプローラーと同じ IDataObject を使う）。
/// - クリップボードへコピー（貼り付け先で Ctrl+V）
/// - ドラッグ&ドロップ（yazi でドラッグを始めたときに呼ばれ、Windows 標準のドラッグを開始する）
/// </summary>
internal static unsafe partial class ShellData
{
    private static Guid IID_IDataObject => new("0000010E-0000-0000-C000-000000000046");

    /// <summary>
    /// ファイルをクリップボードにコピーする（エクスプローラーの「コピー」と同じく CF_HDROP + Preferred DropEffect）。
    /// シェルのデータオブジェクトは CF_HDROP をその場で作るため、プロセス終了後も残るよう CF_HDROP を自分で組み立てて置く。
    /// 成功したら件数を標準出力に書く。
    /// </summary>
    public static int CopyToClipboard(string[] paths) => PutOnClipboard(paths, false);

    public static int CutToClipboard(string[] paths) => PutOnClipboard(paths, true);

    private static int PutOnClipboard(string[] paths, bool move)
    {
        var files = paths.Select(Path.GetFullPath).Where(p => File.Exists(p) || Directory.Exists(p)).ToList();
        if (files.Count == 0)
        {
            Console.Error.Write("コピーできるファイルがありません");
            return 1;
        }

        // DROPFILES（20 バイト）の後に、NUL 区切り・末尾が二重 NUL の UTF-16 のパス一覧
        var list = string.Join('\0', files) + "\0\0";
        var size = 20 + list.Length * 2;
        var hDrop = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, (nuint)size);
        var hEffect = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, 4);
        var p = hDrop == 0 ? null : (byte*)GlobalLock(hDrop);
        var e = hEffect == 0 ? null : (uint*)GlobalLock(hEffect);
        if (p is null || e is null)
        {
            if (p is not null) GlobalUnlock(hDrop);
            if (e is not null) GlobalUnlock(hEffect);
            if (hDrop != 0) GlobalFree(hDrop);
            if (hEffect != 0) GlobalFree(hEffect);
            Console.Error.Write("メモリを確保できません");
            return 1;
        }

        *(uint*)p = 20;          // pFiles: パス一覧の開始位置
        *(int*)(p + 16) = 1;     // fWide: UTF-16
        fixed (char* s = list)
        {
            Buffer.MemoryCopy(s, p + 20, size - 20, list.Length * 2);
        }
        GlobalUnlock(hDrop);

        *e = move ? DROPEFFECT_MOVE : DROPEFFECT_COPY;
        GlobalUnlock(hEffect);

        nint owner;
        try
        {
            owner = OwnerWindow.Create();
        }
        catch (Exception ex)
        {
            GlobalFree(hDrop);
            GlobalFree(hEffect);
            Console.Error.Write($"クリップボード用ウィンドウを作成できません: {ex.Message}");
            return 1;
        }
        if (!Clipboard.Open(owner))
        {
            GlobalFree(hDrop);
            GlobalFree(hEffect);
            DestroyWindow(owner);
            Console.Error.Write("クリップボードを開けません（ほかのアプリが使用中です）");
            return 1;
        }
        try
        {
            if (EmptyClipboard() == 0)
            {
                GlobalFree(hDrop);
                GlobalFree(hEffect);
                Console.Error.Write("クリップボードを消去できません");
                return 1;
            }
            // 成功するとメモリの所有権はクリップボードに移る
            if (SetClipboardData(CF_HDROP, hDrop) == 0)
            {
                GlobalFree(hDrop);
                GlobalFree(hEffect);
                Console.Error.Write("ファイルをクリップボードにコピーできません");
                return 1;
            }
            var fmt = RegisterClipboardFormatW("Preferred DropEffect");
            if (fmt == 0 || SetClipboardData(fmt, hEffect) == 0)
            {
                GlobalFree(hEffect);
                if (move)
                {
                    EmptyClipboard();
                    Console.Error.Write("切り取り情報をクリップボードに設定できません");
                    return 1;
                }
            }
        }
        finally
        {
            CloseClipboard();
            DestroyWindow(owner);
        }

        Log.Write($"clipboard: {files.Count} file(s)");
        Console.Out.Write(files.Count);
        return 0;
    }

    /// <summary>
    /// ドラッグを開始する。マウスの左ボタンが押されている間に呼ばれる前提で、離された位置のアプリにファイルを渡す。
    /// 移動は許可しない（エクスプローラーの同じドライブに落とすと既定が「移動」になり、意図せず移動してしまうため）。
    /// 終了コード: 0 = ドロップされた / 4 = キャンセル / 3 = 既にボタンが離されていた
    /// </summary>
    public static int Drag(string[] paths)
    {
        OleInitialize(0);
        nint hwnd = 0, obj = 0;
        try
        {
            using var items = ShellItems.Parse(paths);

            // 起動までの間にボタンが離されていたら何もしない
            if ((GetAsyncKeyState(VK_LBUTTON) & 0x8000) == 0)
            {
                Console.Error.Write("ドラッグ開始前にマウスのボタンが離されました");
                return 3;
            }

            hwnd = OwnerWindow.Create();
            obj = items.GetUIObject(hwnd, IID_IDataObject);

            // マウスは WezTerm が握っているので、WezTerm のスレッドと入力状態を共有してからドラッグを始める
            var fg = GetForegroundWindow();
            var me = GetCurrentThreadId();
            var fgThread = fg == 0 ? 0 : GetWindowThreadProcessId(fg, null);
            var attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, 1) != 0;
            uint effect = 0;
            int hr;
            try
            {
                hr = SHDoDragDrop(hwnd, obj, 0, DROPEFFECT_COPY | DROPEFFECT_LINK, &effect);
            }
            finally
            {
                if (attached)
                {
                    AttachThreadInput(me, fgThread, 0);
                }
            }

            Log.Write($"drag: hr=0x{hr:X8} effect={effect}");
            if (hr == DRAGDROP_S_DROP)
            {
                Console.Out.Write(effect == DROPEFFECT_LINK ? "link" : "copy");
                return 0;
            }
            return hr < 0 ? 1 : 4;
        }
        catch (COMException e)
        {
            Console.Error.Write(e.Message);
            return 1;
        }
        finally
        {
            if (obj != 0) Com.Release(obj);
            if (hwnd != 0) DestroyWindow(hwnd);
            OleUninitialize();
        }
    }

    private const int DRAGDROP_S_DROP = 0x40100;
    private const int VK_LBUTTON = 0x01;
    private const uint GMEM_MOVEABLE = 0x2, GMEM_ZEROINIT = 0x40;

    [LibraryImport("kernel32.dll")] private static partial nint GlobalAlloc(uint flags, nuint bytes);
    [LibraryImport("kernel32.dll")] private static partial nint GlobalFree(nint h);
    [LibraryImport("shell32.dll")] private static partial int SHDoDragDrop(nint hwnd, nint dataObject, nint dropSource, uint okEffects, uint* effect);
    [LibraryImport("user32.dll")] private static partial short GetAsyncKeyState(int vk);
}
