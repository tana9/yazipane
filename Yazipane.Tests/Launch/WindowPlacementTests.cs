using Yazipane.Tests.Support;

namespace Yazipane.Tests.Launch;

public sealed class WindowPlacementTests : IDisposable
{
    private readonly TempDir _temp = new();

    public void Dispose() => _temp.Dispose();

    // ---- Saved.Parse ----

    [Fact]
    public void 記録した形式を読み戻せる()
    {
        var s = new WindowPlacement.Saved(true, 10, 20, 1210, 820);
        Assert.Equal(s, WindowPlacement.Saved.Parse(s.ToString()));
    }

    [Theory]
    [InlineData("")]
    [InlineData("1 2 3")]
    [InlineData("0 a 0 800 600")]
    [InlineData("0 0 0 50 50")]   // 小さすぎる
    public void 壊れた記録は使わない(string text)
    {
        Assert.Null(WindowPlacement.Saved.Parse(text));
    }

    // ---- Load ----

    [Fact]
    public void Load_画面の中の位置なら使う()
    {
        _temp.File("window.txt", "0 100 100 900 700\n");

        Assert.Equal(new WindowPlacement.Saved(false, 100, 100, 900, 700), WindowPlacement.Load(_temp.Root));
    }

    [Fact]
    public void Load_どのモニターにも映らない位置なら使わない()
    {
        // 外したモニターの位置などが残っていた場合
        _temp.File("window.txt", "0 -100000 -100000 -99000 -99000\n");

        Assert.Null(WindowPlacement.Load(_temp.Root));
    }

    [Fact]
    public void Load_記録が無ければnull()
    {
        Assert.Null(WindowPlacement.Load(_temp.Root));
    }

    [Fact]
    public void Save_Loadで読み戻せる()
    {
        var s = new WindowPlacement.Saved(true, 100, 100, 900, 700);

        WindowPlacement.Save(_temp.Root, s);

        Assert.Equal(s, WindowPlacement.Load(_temp.Root));
    }
}
