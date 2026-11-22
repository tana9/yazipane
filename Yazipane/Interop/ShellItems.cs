using System.Runtime.InteropServices;
using static Yazipane.Interop.Native;

namespace Yazipane.Interop;

/// <summary>
/// パスの一覧をシェルの項目（親フォルダの IShellFolder と子の PIDL）にする。
/// 右クリックメニュー（IContextMenu）、クリップボード / ドラッグ（IDataObject）で共通に使う。
/// シェルの UI オブジェクトは 1 つのフォルダの中身にしか作れないので、最初のパスと同じフォルダにあるものだけを対象にする。
/// </summary>
internal sealed unsafe partial class ShellItems : IDisposable
{
    private readonly List<nint> _pidls = [];
    private readonly List<nint> _children = [];
    private nint _folder;

    public string? ParentDir { get; private set; }
    public int Count => _children.Count;

    private ShellItems()
    {
    }

    /// <summary>パスを解決する。失敗したときは COMException（メッセージはそのまま表示できる）。</summary>
    public static ShellItems Parse(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0)
        {
            throw new COMException("パスが指定されていません");
        }

        var items = new ShellItems();
        try
        {
            var first = Path.GetFullPath(paths[0]);
            items.ParentDir = Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(first));
            foreach (var raw in paths)
            {
                var full = Path.GetFullPath(raw);
                if (items._children.Count > 0 && !string.Equals(
                        Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(full)), items.ParentDir,
                        StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                nint pidl;
                uint attrs;
                var hr = SHParseDisplayName(full, 0, &pidl, 0, &attrs);
                if (hr < 0)
                {
                    throw new COMException($"パスを解決できません: {full} (0x{hr:X8})", hr);
                }
                items._pidls.Add(pidl);

                if (items._children.Count == 0)
                {
                    nint folder, last;
                    var iid = IID_IShellFolder;
                    Com.Check(SHBindToParent(pidl, &iid, &folder, &last));
                    items._folder = folder;
                    items._children.Add(last);
                }
                else
                {
                    items._children.Add(ILFindLastID(pidl));
                }
            }
            return items;
        }
        catch
        {
            items.Dispose();
            throw;
        }
    }

    /// <summary>IShellFolder::GetUIObjectOf で IContextMenu / IDataObject などを作る。呼び出し側で Release する。</summary>
    public nint GetUIObject(nint hwnd, Guid iid)
    {
        nint result;
        fixed (nint* apidl = _children.ToArray())
        {
            // IShellFolder::GetUIObjectOf (vtable 10)
            var fn = (delegate* unmanaged[Stdcall]<nint, nint, uint, nint*, Guid*, uint*, nint*, int>)Com.Vtbl(_folder)[10];
            Com.Check(fn(_folder, hwnd, (uint)_children.Count, apidl, &iid, null, &result));
        }
        return result;
    }

    public void Dispose()
    {
        if (_folder != 0)
        {
            Com.Release(_folder);
            _folder = 0;
        }
        foreach (var p in _pidls)
        {
            CoTaskMemFree(p);
        }
        _pidls.Clear();
        _children.Clear();
    }

    private static Guid IID_IShellFolder => new("000214E6-0000-0000-C000-000000000046");

    [LibraryImport("shell32.dll")] private static partial int SHBindToParent(nint pidl, Guid* riid, nint* ppv, nint* pidlLast);
    [LibraryImport("shell32.dll")] private static partial nint ILFindLastID(nint pidl);
}
