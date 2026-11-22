using System.Runtime.InteropServices;

namespace Yazipane.Commands;

/// <summary>クリップボードのファイル一覧（CF_HDROP + Preferred DropEffect。エクスプローラーのコピー / 切り取りと同じ形式）。</summary>
internal static unsafe partial class Clipboard
{
    public const uint CF_HDROP = 15;
    public const uint DROPEFFECT_COPY = 1, DROPEFFECT_MOVE = 2, DROPEFFECT_LINK = 4;

    /// <summary>ほかのアプリがクリップボードを開いていることがあるので、少し待って再試行する。</summary>
    public static bool Open(nint owner)
    {
        for (var i = 0; i < 20; i++)
        {
            if (OpenClipboard(owner) != 0)
            {
                return true;
            }
            Thread.Sleep(50);
        }
        return false;
    }

    /// <summary>クリップボードのファイル一覧と、切り取り（移動）かどうか。ファイルが無ければ空の一覧。</summary>
    public static (List<string> Files, bool Move, uint Sequence) ReadFiles()
    {
        var files = new List<string>();
        if (!Open(0))
        {
            throw new IOException("クリップボードを開けません（ほかのアプリが使用中です）");
        }
        try
        {
            var hDrop = GetClipboardData(CF_HDROP);
            if (hDrop == 0)
            {
                return (files, false, GetClipboardSequenceNumber());
            }
            var count = DragQueryFileW(hDrop, uint.MaxValue, null, 0);
            for (uint i = 0; i < count; i++)
            {
                var len = DragQueryFileW(hDrop, i, null, 0);
                var buf = new char[len + 1];
                fixed (char* p = buf)
                {
                    DragQueryFileW(hDrop, i, p, len + 1);
                }
                files.Add(new string(buf, 0, (int)len));
            }

            var move = false;
            var fmt = RegisterClipboardFormatW("Preferred DropEffect");
            var hEffect = fmt == 0 ? 0 : GetClipboardData(fmt);
            if (hEffect != 0 && GlobalLock(hEffect) is var p2 && p2 != 0)
            {
                move = (*(uint*)p2 & DROPEFFECT_MOVE) != 0;
                GlobalUnlock(hEffect);
            }
            return (files, move, GetClipboardSequenceNumber());
        }
        finally
        {
            CloseClipboard();
        }
    }

    /// <summary>クリップボードを空にする（切り取ったファイルを貼り付けた後）。</summary>
    public static void Clear(uint sequence)
    {
        if (Open(0))
        {
            try
            {
                if (sequence != 0 && GetClipboardSequenceNumber() == sequence) EmptyClipboard();
            }
            finally
            {
                CloseClipboard();
            }
        }
    }

    [LibraryImport("user32.dll")] internal static partial int OpenClipboard(nint hwnd);
    [LibraryImport("user32.dll")] internal static partial int CloseClipboard();
    [LibraryImport("user32.dll")] internal static partial int EmptyClipboard();
    [LibraryImport("user32.dll")] private static partial uint GetClipboardSequenceNumber();
    [LibraryImport("user32.dll")] internal static partial nint GetClipboardData(uint format);
    [LibraryImport("user32.dll")] internal static partial nint SetClipboardData(uint format, nint data);
    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial uint RegisterClipboardFormatW(string name);
    [LibraryImport("kernel32.dll")] internal static partial nint GlobalLock(nint h);
    [LibraryImport("kernel32.dll")] internal static partial int GlobalUnlock(nint h);
    [LibraryImport("shell32.dll")] private static partial uint DragQueryFileW(nint hDrop, uint index, char* file, uint cch);
}
