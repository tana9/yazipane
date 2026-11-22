using System.Runtime.InteropServices;

namespace Yazipane.Interop;

/// <summary>複数のクラスで使う Win32 API と構造体。</summary>
internal static unsafe partial class Native
{
    private const uint MB_ICONERROR = 0x10, MB_ICONINFORMATION = 0x40;

    [LibraryImport("user32.dll", EntryPoint = "MessageBoxW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int MessageBox(nint hWnd, string text, string caption, uint type);

    /// <summary>WinExe なのでコンソールが無い。エラーはメッセージボックスで表示する。</summary>
    public static void ShowError(string message) => MessageBox(0, message, "yazipane", MB_ICONERROR);

    public static void ShowInfo(string message) => MessageBox(0, message, "yazipane", MB_ICONINFORMATION);

    [StructLayout(LayoutKind.Sequential)]
    internal struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    internal struct RECT { public int Left, Top, Right, Bottom; }

    [LibraryImport("ole32.dll")] internal static partial int OleInitialize(nint reserved);
    [LibraryImport("ole32.dll")] internal static partial void OleUninitialize();
    [LibraryImport("ole32.dll")] internal static partial void CoTaskMemFree(nint p);

    [LibraryImport("shell32.dll", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial int SHParseDisplayName(string name, nint bindCtx, nint* pidl, uint sfgaoIn, uint* sfgaoOut);

    [LibraryImport("user32.dll")] internal static partial nint GetForegroundWindow();
    [LibraryImport("user32.dll")] internal static partial int SetForegroundWindow(nint hwnd);
    [LibraryImport("user32.dll")] internal static partial uint GetWindowThreadProcessId(nint hwnd, uint* pid);
    [LibraryImport("user32.dll")] internal static partial int AttachThreadInput(uint idAttach, uint idAttachTo, int attach);
    [LibraryImport("user32.dll")] internal static partial int DestroyWindow(nint hwnd);
    [LibraryImport("kernel32.dll")] internal static partial uint GetCurrentThreadId();
    [LibraryImport("kernel32.dll", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial nint GetModuleHandleW(string? name);
}
