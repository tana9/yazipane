using Yazipane.Tests.Support;

namespace Yazipane.Tests.Launch;

public sealed class InstancesTests : IDisposable
{
    private readonly TempDir _temp = new();

    public void Dispose() => _temp.Dispose();

    [Fact]
    public void 記録を読み戻せる()
    {
        var file = new Instances(_temp.Root).Add(100, 101, 4242);

        Assert.Equal(new Instances.Entry(file, 100, 101, 4242), Instances.Parse(file));
    }

    [Fact]
    public void 壊れた記録は読まない()
    {
        var file = _temp.File(@"instances\1.txt", "abc\n");

        Assert.Null(Instances.Parse(file));
    }

    [Fact]
    public void 終了済みの記録は消す()
    {
        var instances = new Instances(_temp.Root);
        // 存在しない PID（WezTerm ではない）を記録する
        var file = instances.Add(1, 2, int.MaxValue);

        Assert.Empty(instances.Alive());
        Assert.False(File.Exists(file));
    }

    [Fact]
    public void 生きていてもWezTermでないプロセスの記録は消す()
    {
        // PID が再利用されて、別のプロセスになっていた場合
        var instances = new Instances(_temp.Root);
        var file = instances.Add(1, 2, Environment.ProcessId);

        Assert.Empty(instances.Alive());
        Assert.False(File.Exists(file));
    }

    [Fact]
    public void 記録のフォルダが無ければ空()
    {
        Assert.Empty(new Instances(_temp.PathOf("missing")).Alive());
    }

    [Fact]
    public void Remove_無いファイルでも例外を外に出さない()
    {
        Instances.Remove(_temp.PathOf("missing.txt"));
    }
}
