using Yazipane.Tests.Support;

namespace Yazipane.Tests.Commands;

public sealed class FolderPairsTests : IDisposable
{
    private readonly TempDir _temp = new();
    public void Dispose() => _temp.Dispose();

    [Fact]
    public void 名前付きで保存し上書きと削除ができる()
    {
        var left = _temp.Dir("left");
        var right = _temp.Dir("right");
        var dir = _temp.PathOf("pairs");
        FolderPairs.Save(dir, "仕事", left, right);
        Assert.Equal(new FolderPairs.Pair("仕事", left, right), Assert.Single(FolderPairs.List(dir)));
        FolderPairs.Save(dir, "仕事", right, left);
        Assert.Equal(new FolderPairs.Pair("仕事", right, left), Assert.Single(FolderPairs.List(dir)));
        FolderPairs.Delete(dir, "仕事");
        Assert.Empty(FolderPairs.List(dir));
    }

    [Fact]
    public void 不正な名前や存在しないフォルダは保存しない()
    {
        var dir = _temp.PathOf("pairs");
        Assert.Throws<UserFacingException>(() => FolderPairs.Save(dir, "名前\n改行", _temp.Root, _temp.Root));
        Assert.Throws<UserFacingException>(() => FolderPairs.Save(dir, "名前", _temp.Root, _temp.PathOf("missing")));
        Assert.False(Directory.Exists(dir));
    }

    [Fact]
    public void 名前をファイルパスとして扱わない()
    {
        var dir = _temp.PathOf("pairs");
        FolderPairs.Save(dir, @"..\外側", _temp.Root, _temp.Root);
        Assert.Equal(@"..\外側", Assert.Single(FolderPairs.List(dir)).Name);
        Assert.False(File.Exists(_temp.PathOf("外側")));
    }

    [Fact]
    public void 上限を超える新規保存は失敗し既存の上書きはできる()
    {
        var dir = _temp.PathOf("pairs");
        for (var i = 0; i < FolderPairs.MaxPairs; i++) FolderPairs.Save(dir, $"組{i}", _temp.Root, _temp.Root);
        Assert.Throws<UserFacingException>(() => FolderPairs.Save(dir, "追加", _temp.Root, _temp.Root));
        FolderPairs.Save(dir, "組0", _temp.Root, _temp.Root);
        Assert.Equal(FolderPairs.MaxPairs, FolderPairs.List(dir).Count);
    }
}
