using Yazipane.Tests.Support;

namespace Yazipane.Tests.Launch;

public sealed class LauncherTests : IDisposable
{
    private readonly TempDir _temp = new();

    public void Dispose() => _temp.Dispose();

    [Fact]
    public void スモークテストの状態は通常の状態と分離する()
    {
        var root = Path.Combine(_temp.Root, "yazipane");
        var id = Guid.NewGuid().ToString("N");
        Assert.Equal(root, Launcher.DataDir(_temp.Root, null));
        Assert.Equal(root, Launcher.DataDir(_temp.Root, @"..\outside"));
        Assert.Equal(Path.Combine(root, "smoke", id), Launcher.DataDir(_temp.Root, id));
    }

    // ---- ResolveDirs ----

    [Fact]
    public void ResolveDirs_引数が1つなら左右とも同じフォルダ()
    {
        var a = _temp.Dir("a");

        var (left, right) = Launcher.ResolveDirs([a], _temp.PathOf("state"));

        Assert.Equal(a, left);
        Assert.Equal(a, right);
    }

    [Fact]
    public void ResolveDirs_引数が2つなら左と右()
    {
        var a = _temp.Dir("a");
        var b = _temp.Dir("b");

        Assert.Equal((a, b), Launcher.ResolveDirs([a, b], _temp.PathOf("state")));
    }

    [Fact]
    public void ResolveDirs_引数が無ければ前回のフォルダを使う()
    {
        var a = _temp.Dir("a");
        var b = _temp.Dir("b");
        _temp.File(@"state\last-left.txt", a + "\n");
        _temp.File(@"state\last-right.txt", b);

        Assert.Equal((a, b), Launcher.ResolveDirs([], _temp.PathOf("state")));
    }

    [Fact]
    public void ResolveDirs_前回の右のフォルダが消えていたら左と同じにする()
    {
        var a = _temp.Dir("a");
        _temp.File(@"state\last-left.txt", a);
        _temp.File(@"state\last-right.txt", _temp.PathOf("deleted"));

        Assert.Equal((a, a), Launcher.ResolveDirs([], _temp.PathOf("state")));
    }

    // ---- CheckDir ----

    [Fact]
    public void CheckDir_ファイルを渡すとエラー()
    {
        var file = _temp.File("a.txt", "");

        var e = Assert.Throws<UserFacingException>(() => Launcher.CheckDir(file));
        Assert.Contains("ディレクトリではありません", e.Message);
    }

    [Fact]
    public void CheckDir_無いフォルダを渡すとエラー()
    {
        var e = Assert.Throws<UserFacingException>(() => Launcher.CheckDir(_temp.PathOf("missing")));
        Assert.Contains("ディレクトリが開けません", e.Message);
    }

    // ---- FindExe ----

    [Fact]
    public void FindExe_PATHの先頭から探し最初に見つかったものを使う()
    {
        _temp.Dir("empty");
        var first = _temp.File(@"a\tool.exe", "");
        _temp.File(@"b\tool.exe", "");
        var path = string.Join(';', _temp.PathOf("empty"), _temp.PathOf("a"), _temp.PathOf("b"));

        Assert.Equal(first, Launcher.FindExe("tool", path));
    }

    [Fact]
    public void FindExe_引用符で囲まれた項目と空の項目も扱う()
    {
        var exe = _temp.File(@"with space\tool.exe", "");
        var path = $";;\"{_temp.PathOf("with space")}\";";

        Assert.Equal(exe, Launcher.FindExe("tool", path));
    }

    [Fact]
    public void FindExe_scoopのshimなら実体のパス()
    {
        var real = _temp.File(@"apps\tool\tool.exe", "");
        _temp.File(@"shims\tool.exe", "");
        _temp.File(@"shims\tool.shim", $"path = \"{real}\"\n");

        Assert.Equal(real, Launcher.FindExe("tool", _temp.PathOf("shims")));
    }

    [Fact]
    public void FindExe_見つからなければnull()
    {
        Assert.Null(Launcher.FindExe("tool", _temp.Dir("empty")));
    }

    // ---- UserWeztermConfig ----

    private string Home => _temp.PathOf("home");

    [Fact]
    public void UserWeztermConfig_WEZTERM_CONFIG_FILEを優先する()
    {
        var file = _temp.File(@"conf\wez.lua", "");
        _temp.File(@"home\.wezterm.lua", "");
        var env = new Dictionary<string, string?> { ["WEZTERM_CONFIG_FILE"] = file };

        Assert.Equal(file, Launcher.UserWeztermConfig(_temp.PathOf("own.lua"), env.GetValueOrDefault, Home));
    }

    [Fact]
    public void UserWeztermConfig_無ければホームのconfigフォルダ次にホーム直下()
    {
        var dotConfig = _temp.File(@"home\.config\wezterm\wezterm.lua", "");
        var dotFile = _temp.File(@"home\.wezterm.lua", "");
        static string? NoEnv(string _) => null;

        Assert.Equal(dotConfig, Launcher.UserWeztermConfig(_temp.PathOf("own.lua"), NoEnv, Home));
        File.Delete(dotConfig);
        Assert.Equal(dotFile, Launcher.UserWeztermConfig(_temp.PathOf("own.lua"), NoEnv, Home));
    }

    [Fact]
    public void UserWeztermConfig_yazipaneのペインから起動されたら自分の設定は拾わず普段の設定を使う()
    {
        // yazipane のペインの中では WEZTERM_CONFIG_FILE が yazipane 自身の設定を指している
        var own = _temp.File("own.lua", "");
        var user = _temp.File(@"home\.wezterm.lua", "");
        var env = new Dictionary<string, string?> { ["WEZTERM_CONFIG_FILE"] = own };

        Assert.Equal(user, Launcher.UserWeztermConfig(own, env.GetValueOrDefault, Home));
    }

    [Fact]
    public void UserWeztermConfig_yazipaneから渡された普段の設定の場所を最優先する()
    {
        var own = _temp.File("own.lua", "");
        var user = _temp.File(@"conf\user.lua", "");
        var env = new Dictionary<string, string?> { ["YAZIPANE_USER_WEZTERM"] = user, ["WEZTERM_CONFIG_FILE"] = own };

        Assert.Equal(user, Launcher.UserWeztermConfig(own, env.GetValueOrDefault, Home));
    }

    [Fact]
    public void UserWeztermConfig_どこにも無ければnull()
    {
        var env = new Dictionary<string, string?> { ["WEZTERM_CONFIG_FILE"] = _temp.PathOf("missing.lua") };

        Assert.Null(Launcher.UserWeztermConfig(_temp.PathOf("own.lua"), env.GetValueOrDefault, Home));
    }

    // ---- ResolveShim ----

    [Fact]
    public void ResolveShim_scoopのshimなら実体のパス()
    {
        var real = _temp.File(@"apps\tool\tool.exe", "");
        var shim = _temp.File(@"shims\tool.exe", "");
        _temp.File(@"shims\tool.shim", $"path = \"{real}\"\n");

        Assert.Equal(real, Launcher.ResolveShim(shim));
    }

    [Fact]
    public void ResolveShim_shimでなければnull()
    {
        var exe = _temp.File(@"bin\tool.exe", "");

        Assert.Null(Launcher.ResolveShim(exe));
    }

    [Fact]
    public void ResolveShim_shimの指す実体が無ければnull()
    {
        var shim = _temp.File(@"shims\tool.exe", "");
        _temp.File(@"shims\tool.shim", $"path = \"{_temp.PathOf("missing.exe")}\"\n");

        Assert.Null(Launcher.ResolveShim(shim));
    }
}
