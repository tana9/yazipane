using Yazipane.Tests.Support;

namespace Yazipane.Tests.Common;

public sealed class FilesTests : IDisposable
{
    private readonly TempDir _temp = new();

    public void Dispose() => _temp.Dispose();

    // ---- SyncDir ----

    [Fact]
    public void SyncDir_コピーしsrcに無いものは消す()
    {
        _temp.File(@"src\a.txt", "a");
        _temp.File(@"src\sub\b.txt", "b");
        _temp.Dir(@"dst\stale-dir");
        _temp.File(@"dst\stale.txt", "x");

        Files.SyncDir(_temp.PathOf("src"), _temp.PathOf("dst"));

        Assert.Equal("a", File.ReadAllText(_temp.PathOf(@"dst\a.txt")));
        Assert.Equal("b", File.ReadAllText(_temp.PathOf(@"dst\sub\b.txt")));
        Assert.False(File.Exists(_temp.PathOf(@"dst\stale.txt")));
        Assert.False(Directory.Exists(_temp.PathOf(@"dst\stale-dir")));
    }

    [Fact]
    public void SyncDir_ファイルとフォルダの種類が違えば置き換える()
    {
        _temp.File(@"src\was-file", "now file");
        _temp.File(@"src\was-dir\child.txt", "c");
        // dst では逆の種類になっている
        _temp.Dir(@"dst\was-file\old");
        _temp.File(@"dst\was-dir", "old file");

        Files.SyncDir(_temp.PathOf("src"), _temp.PathOf("dst"));

        Assert.Equal("now file", File.ReadAllText(_temp.PathOf(@"dst\was-file")));
        Assert.Equal("c", File.ReadAllText(_temp.PathOf(@"dst\was-dir\child.txt")));
    }

    [Fact]
    public void SyncDir_dst自体がファイルならフォルダに置き換える()
    {
        _temp.File(@"src\a.txt", "a");
        _temp.File("dst", "file");

        Files.SyncDir(_temp.PathOf("src"), _temp.PathOf("dst"));

        Assert.Equal("a", File.ReadAllText(_temp.PathOf(@"dst\a.txt")));
    }

    // ---- WriteIfChanged ----

    [Fact]
    public void WriteIfChanged_内容が同じなら書き換えない()
    {
        var path = _temp.File("x.txt", "same");
        var before = new DateTime(2000, 1, 1);
        File.SetLastWriteTime(path, before);

        Files.WriteIfChanged(path, "same"u8.ToArray());

        Assert.Equal(before, File.GetLastWriteTime(path));
    }

    [Fact]
    public void WriteIfChanged_内容が違えば書き換え途中のフォルダも作る()
    {
        var path = _temp.PathOf(@"new\dir\x.txt");

        Files.WriteIfChanged(path, "first"u8.ToArray());
        Files.WriteIfChanged(path, "second"u8.ToArray());

        Assert.Equal("second", File.ReadAllText(path));
    }

    // ---- SameDir ----

    [Theory]
    [InlineData(@"C:\Work", @"c:\work\")]
    [InlineData(@"C:\Work\.", @"C:\work")]
    public void SameDir_大文字小文字と末尾の区切りの違いは同じとみなす(string a, string b)
    {
        Assert.True(Files.SameDir(a, b));
    }

    [Fact]
    public void SameDir_違うフォルダは違う()
    {
        Assert.False(Files.SameDir(@"C:\work", @"C:\work2"));
    }
}
