using Yazipane.Common;
using Yazipane.Tests.Support;

namespace Yazipane.Tests.Commands;

public sealed class PathsTests : IDisposable
{
    private readonly TempDir _temp = new();
    public void Dispose() => _temp.Dispose();

    [Fact]
    public void 大文字小文字と末尾区切りが違っても同じフォルダと判定する()
    {
        var dir = _temp.Dir("Work");
        Assert.True(Files.SameDir(dir, dir.ToUpperInvariant() + "\\"));
    }

    [Fact]
    public void 異なるフォルダは同じと判定しない()
    {
        var left = _temp.Dir("left");
        var right = _temp.Dir("right");
        Assert.False(Files.SameDir(left, right));
    }
}
