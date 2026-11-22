using System.Runtime.InteropServices;
using Yazipane.Tests.Support;

namespace Yazipane.Tests.Interop;

/// <summary>パスの一覧をシェルの項目にする（右クリックメニュー / クリップボード / ドラッグで共通）。画面は出さない。</summary>
public sealed class ShellItemsTests : IDisposable
{
    private readonly TempDir _temp = new();

    public void Dispose() => _temp.Dispose();

    /// <summary>シェルの API は COM を使うので STA のスレッドで解決し、件数と親フォルダを返す</summary>
    private static (int Count, string? ParentDir) Parse(params string[] paths) =>
        Sta.Run(() =>
        {
            using var items = ShellItems.Parse(paths);
            return (items.Count, items.ParentDir);
        });

    [Fact]
    public void 同じフォルダのものをまとめる()
    {
        var a = _temp.File(@"dir\a.txt", "a");
        var b = _temp.File(@"dir\b.txt", "b");

        Assert.Equal((2, _temp.PathOf("dir")), Parse(a, b));
    }

    [Fact]
    public void 最初のパスと違うフォルダのものは外す()
    {
        var a = _temp.File(@"dir\a.txt", "a");
        var other = _temp.File(@"other\c.txt", "c");
        var b = _temp.File(@"dir\b.txt", "b");

        Assert.Equal((2, _temp.PathOf("dir")), Parse(a, other, b));
    }

    [Fact]
    public void フォルダも項目にできる()
    {
        var sub = _temp.Dir(@"dir\sub");

        Assert.Equal((1, _temp.PathOf("dir")), Parse(sub + @"\"));
    }

    [Fact]
    public void 解決できないパスは例外()
    {
        var e = Assert.Throws<InvalidOperationException>(() => Parse(_temp.PathOf(@"dir\missing.txt")));
        Assert.IsType<COMException>(e.InnerException);
    }

    [Fact]
    public void パスが無ければ例外()
    {
        var e = Assert.Throws<InvalidOperationException>(() => Parse());
        Assert.IsType<COMException>(e.InnerException);
    }
}
