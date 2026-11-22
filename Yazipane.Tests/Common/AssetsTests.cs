using System.Text;
using Yazipane.Tests.Support;

namespace Yazipane.Tests.Common;

public sealed class AssetsTests : IDisposable
{
    private readonly TempDir _temp = new();

    public void Dispose() => _temp.Dispose();

    [Theory]
    [InlineData("assets/wezterm.lua", "wezterm.config_builder()")]
    [InlineData("assets/yazi/init.lua", "require(\"yazipane\"):setup()")]
    [InlineData("assets/yazi/keymap.toml", "prepend_keymap")]
    public void 埋め込んだファイルを読める(string name, string expected)
    {
        var text = Encoding.UTF8.GetString(Assets.Read(name));

        Assert.Contains(expected, text);
    }

    [Fact]
    public void 埋め込まれていない名前は例外()
    {
        Assert.Throws<FileNotFoundException>(() => Assets.Read("assets/missing.lua"));
    }

    [Fact]
    public void Extract_フォルダ以下をまとめて書き出す()
    {
        var dst = _temp.PathOf("plugins");

        Assets.Extract("assets/yazi/plugins", dst);

        Assert.True(File.Exists(Path.Combine(dst, "yazipane.yazi", "main.lua")));
    }
}
