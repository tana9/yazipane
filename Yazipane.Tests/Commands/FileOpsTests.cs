using Yazipane.Tests.Support;

namespace Yazipane.Tests.Commands;

/// <summary>
/// IFileOperation でのコピー / 移動と、件数の数え方。
/// ダイアログを出さないフラグ（FOF_SILENT など）を付け、一時フォルダの小さなファイルで実際に動かす。
/// </summary>
public sealed class FileOpsTests : IDisposable
{
    private readonly TempDir _temp = new();
    private readonly string _src;
    private readonly string _dst;

    // テストではダイアログ（進捗・確認・エラー）を出さない
    private const uint Quiet = FileOps.FOF_SILENT | FileOps.FOF_NOERRORUI;

    public FileOpsTests()
    {
        _src = _temp.Dir("src");
        _dst = _temp.Dir("dst");
    }

    public void Dispose() => _temp.Dispose();

    // IFileOperation は STA のスレッドでしか使えない
    private static FileOps.Result Run(bool move, string dest, string[] paths, uint flags = Quiet) =>
        Sta.Run(() => FileOps.Execute(move, dest, paths, flags));

    [Fact]
    public void コピーしたファイルとフォルダを1件ずつ数える()
    {
        var a = _temp.File(@"src\a.txt", "a");
        _temp.File(@"src\sub\b.txt", "b");
        _temp.File(@"src\sub\c.txt", "c");

        var result = Run(false, _dst, [a, _temp.PathOf(@"src\sub")]);

        // フォルダの中身（b.txt と c.txt）は数えず、渡した 2 件だけを数える
        Assert.Equal(new FileOps.Result(FileOps.Done, 2, 0, 0), result);
        Assert.Equal("2 0 0", result.Counts);
        Assert.True(File.Exists(_temp.PathOf(@"dst\a.txt")));
        Assert.True(File.Exists(_temp.PathOf(@"dst\sub\c.txt")));
        Assert.True(File.Exists(a), "コピー元は残る");
    }

    [Fact]
    public void 移動するとコピー元から消える()
    {
        var a = _temp.File(@"src\a.txt", "a");

        var result = Run(true, _dst, [a]);

        Assert.Equal(new FileOps.Result(FileOps.Done, 1, 0, 0), result);
        Assert.True(File.Exists(_temp.PathOf(@"dst\a.txt")));
        Assert.False(File.Exists(a));
    }

    [Fact]
    public void 同じフォルダへのコピーは別の名前で複製する()
    {
        var a = _temp.File(@"src\a.txt", "a");

        var result = Run(false, _src, [a]);

        Assert.Equal(1, result.Succeeded);
        Assert.Equal(2, Directory.GetFiles(_src).Length);
    }

    [Fact]
    public void 同じフォルダへの移動は対象が無い扱い()
    {
        var a = _temp.File(@"src\a.txt", "a");

        Assert.Equal(FileOps.Nothing, Run(true, _src, [a]).Code);
    }

    [Fact]
    public void 存在しないパスだけなら対象が無い扱い()
    {
        Assert.Equal(FileOps.Nothing, Run(false, _dst, [_temp.PathOf(@"src\missing.txt")]).Code);
    }

    [Fact]
    public void 同名のファイルを残したときはスキップとして数える()
    {
        // コピー先の方が新しければ残す（FOFX_KEEPNEWERFILE）。ダイアログでスキップを選んだときと同じく、何もせずに終わる
        var a = _temp.File(@"src\a.txt", "old");
        var b = _temp.File(@"src\b.txt", "new");
        File.SetLastWriteTimeUtc(a, new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc));
        _temp.File(@"dst\a.txt", "dst is newer");

        var result = Run(false, _dst, [a, b], Quiet | FileOps.FOF_NOCONFIRMATION | FileOps.FOFX_KEEPNEWERFILE);

        Assert.Equal(new FileOps.Result(FileOps.Done, 1, 1, 0), result);
        Assert.Equal("dst is newer", File.ReadAllText(_temp.PathOf(@"dst\a.txt")));
    }

    [Fact]
    public void 同名のファイルを置き換えたときはできた件数に数える()
    {
        var a = _temp.File(@"src\a.txt", "new");
        _temp.File(@"dst\a.txt", "old");

        var result = Run(false, _dst, [a], Quiet | FileOps.FOF_NOCONFIRMATION);

        Assert.Equal(new FileOps.Result(FileOps.Done, 1, 0, 0), result);
        Assert.Equal("new", File.ReadAllText(_temp.PathOf(@"dst\a.txt")));
    }

    [Fact]
    public void コピー先が無ければ失敗する()
    {
        var a = _temp.File(@"src\a.txt", "a");

        Assert.Equal(FileOps.Failed, Run(false, _temp.PathOf("missing"), [a]).Code);
    }
    [Fact]
    public void 存在しない項目は失敗として数える()
    {
        var a = _temp.File(@"src\a.txt", "a");
        var result = Run(false, _dst, [a, _temp.PathOf(@"src\missing.txt")]);
        Assert.Equal(new FileOps.Result(FileOps.Done, 1, 0, 1), result);
    }

    [Fact]
    public void 異なるフォルダの同名ファイルは別名にしない()
    {
        var same = _temp.File(@"dst\same.txt", "same");
        var other = _temp.File(@"src\other.txt", "new");
        _temp.File(@"dst\other.txt", "old");
        var result = Run(false, _dst, [same, other], Quiet | FileOps.FOF_NOCONFIRMATION);
        Assert.Equal(new FileOps.Result(FileOps.Done, 2, 0, 0), result);
        Assert.Equal("new", File.ReadAllText(_temp.PathOf(@"dst\other.txt")));
        Assert.Equal(3, Directory.GetFiles(_dst).Length);
    }

    [Fact]
    public void 全件移動した場合だけクリップボードを消す()
    {
        Assert.True(FileOps.ShouldClearClipboard(new(FileOps.Done, 2, 0, 0), 2));
        Assert.False(FileOps.ShouldClearClipboard(new(FileOps.Done, 1, 1, 0), 2));
        Assert.False(FileOps.ShouldClearClipboard(new(FileOps.Done, 1, 0, 1), 2));
        Assert.False(FileOps.ShouldClearClipboard(new(FileOps.Aborted, 2, 0, 0), 2));
    }

}
