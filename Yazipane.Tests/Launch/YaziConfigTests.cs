using Tomlyn;
using Tomlyn.Model;
using Yazipane.Tests.Support;

namespace Yazipane.Tests.Launch;

public sealed class YaziConfigTests : IDisposable
{
    private readonly TempDir _temp = new();

    public void Dispose() => _temp.Dispose();

    private static TomlTable Parse(string merged) =>
        TomlSerializer.Deserialize(merged, TomlContext.Default.TomlTable)!;

    private static List<string> Keys(TomlTable t, string table, string array) =>
        [.. ((IEnumerable<object>)((TomlTable)t[table])[array])
            .Cast<TomlTable>()
            .Select(x => (string)x["on"])];

    // ---- MergeToml ----

    [Fact]
    public void MergeToml_prepend配列はoverlayが先頭に連結される()
    {
        const string user = """
            [mgr]
            prepend_keymap = [ { on = "<C-s>", run = "user" } ]
            """;
        const string overlay = """
            [mgr]
            prepend_keymap = [ { on = "<F5>", run = "ours" } ]
            """;

        var merged = Parse(YaziConfig.MergeToml(user, overlay, out var error));

        Assert.Null(error);
        Assert.Equal(["<F5>", "<C-s>"], Keys(merged, "mgr", "prepend_keymap"));
    }

    [Fact]
    public void MergeToml_append配列はoverlayが末尾に連結される()
    {
        const string user = """
            [mgr]
            append_keymap = [ { on = "a", run = "user" } ]
            """;
        const string overlay = """
            [mgr]
            append_keymap = [ { on = "b", run = "ours" } ]
            """;

        var merged = Parse(YaziConfig.MergeToml(user, overlay, out _));

        Assert.Equal(["a", "b"], Keys(merged, "mgr", "append_keymap"));
    }

    [Fact]
    public void MergeToml_通常の値はoverlayで上書きされ他の値は残る()
    {
        const string user = """
            [mgr]
            ratio = [1, 3, 4]
            sort_by = "natural"
            """;
        const string overlay = """
            [mgr]
            ratio = [0, 3, 2]
            """;

        var mgr = (TomlTable)Parse(YaziConfig.MergeToml(user, overlay, out _))["mgr"];

        Assert.Equal([0L, 3L, 2L], ((TomlArray)mgr["ratio"]).Cast<long>());
        Assert.Equal("natural", mgr["sort_by"]);
    }

    [Fact]
    public void MergeToml_片方にしかないテーブルもそのまま残る()
    {
        const string user = """
            [opener]
            edit = [ { run = "nvim %s", block = true } ]
            """;
        const string overlay = """
            [mgr]
            ratio = [0, 3, 2]
            """;

        var merged = Parse(YaziConfig.MergeToml(user, overlay, out _));

        Assert.True(merged.ContainsKey("opener"));
        Assert.True(merged.ContainsKey("mgr"));
    }

    [Fact]
    public void MergeToml_壊れたユーザー設定はoverlayだけを使いエラーを返す()
    {
        const string overlay = """
            [mgr]
            ratio = [0, 3, 2]
            """;

        var merged = Parse(YaziConfig.MergeToml("[mgr\nratio = ", overlay, out var error));

        Assert.NotNull(error);
        Assert.True(((TomlTable)merged["mgr"]).ContainsKey("ratio"));
    }

    [Fact]
    public void MergeToml_テーブルの配列は見出し形式で書き出される()
    {
        const string overlay = """
            [mgr]
            prepend_keymap = [ { on = "<F5>", run = "ours" } ]
            """;

        var text = YaziConfig.MergeToml("", overlay, out _);

        Assert.Contains("[[mgr.prepend_keymap]]", text);
    }

    // ---- UserConfigDir ----

    [Fact]
    public void UserConfigDir_YAZI_CONFIG_HOMEがあればそれを使う()
    {
        var env = new Dictionary<string, string?> { ["YAZI_CONFIG_HOME"] = @"C:\my\yazi" };

        Assert.Equal(@"C:\my\yazi", YaziConfig.UserConfigDir(@"C:\gen", env.GetValueOrDefault, @"C:\appdata"));
    }

    [Fact]
    public void UserConfigDir_無ければAPPDATAのyaziのconfig()
    {
        Assert.Equal(@"C:\appdata\yazi\config", YaziConfig.UserConfigDir(@"C:\gen", _ => null, @"C:\appdata"));
    }

    [Fact]
    public void UserConfigDir_yazipaneのペインから起動されたら生成先ではなく普段の設定の場所を使う()
    {
        // yazipane のペインの中では YAZI_CONFIG_HOME が生成先を指していて、普段の場所は YAZIPANE_USER_CONFIG_HOME にある
        var env = new Dictionary<string, string?>
        {
            ["YAZIPANE_USER_CONFIG_HOME"] = @"C:\my\yazi",
            ["YAZI_CONFIG_HOME"] = @"C:\gen\",
        };

        Assert.Equal(@"C:\my\yazi", YaziConfig.UserConfigDir(@"C:\gen", env.GetValueOrDefault, @"C:\appdata"));
    }

    [Fact]
    public void UserConfigDir_生成先を指していたら使わない()
    {
        var env = new Dictionary<string, string?> { ["YAZI_CONFIG_HOME"] = @"c:\GEN" };

        Assert.Equal(@"C:\appdata\yazi\config", YaziConfig.UserConfigDir(@"C:\gen", env.GetValueOrDefault, @"C:\appdata"));
    }

    // ---- NativeRatio ----

    [Fact]
    public void NativeRatio_設定ファイルのratioを返す()
    {
        _temp.File("yazi.toml", "[mgr]\nratio = [1, 3, 4]\n");
        Assert.Equal("1,3,4", YaziConfig.NativeRatio(_temp.Root));
    }

    [Theory]
    [InlineData(null)]                              // 設定ファイルが無い
    [InlineData("[mgr\nratio = ")]                  // 壊れている
    [InlineData("[mgr]\nratio = [1, 3, 1e30]\n")]   // 範囲外の値
    [InlineData("[mgr]\nratio = [1, 3]\n")]         // 数が足りない
    public void NativeRatio_読めなければyaziの既定値(string? content)
    {
        if (content is not null)
        {
            _temp.File("yazi.toml", content);
        }
        Assert.Equal("1,4,3", YaziConfig.NativeRatio(_temp.Root));
    }

    // ---- Build ----

    [Fact]
    public void Build_普段の設定にyazipaneの設定を重ねて組み立てる()
    {
        // 普段の設定
        _temp.File(@"user\yazi.toml", "[mgr]\nsort_by = \"natural\"\n");
        _temp.File(@"user\init.lua", "-- user init");
        _temp.File(@"user\theme.toml", "[which]\ncols = 3\nseparator = ' > '\n");
        _temp.File(@"user\plugins\foo.yazi\main.lua", "-- foo");
        _temp.File(@"user\flavors\x.yazi\flavor.toml", "# flavor");
        // 前回の生成物の残り（普段の設定から消えたもの）
        _temp.File(@"out\plugins\old.yazi\main.lua", "-- old");
        _temp.File(@"out\vfs.toml", "# old vfs");
        var warnings = new List<string>();

        YaziConfig.Build(_temp.PathOf("out"), _temp.PathOf("user"), warnings);

        Assert.Empty(warnings);
        // プラグイン: 普段のもの + yazipane.yazi。普段の設定から消えたものは消す
        Assert.True(File.Exists(_temp.PathOf(@"out\plugins\foo.yazi\main.lua")));
        Assert.True(File.Exists(_temp.PathOf(@"out\plugins\yazipane.yazi\main.lua")));
        Assert.False(Directory.Exists(_temp.PathOf(@"out\plugins\old.yazi")));
        // そのままコピーするもの
        Assert.True(File.Exists(_temp.PathOf(@"out\flavors\x.yazi\flavor.toml")));
        var which = (TomlTable)Parse(File.ReadAllText(_temp.PathOf(@"out\theme.toml")))["which"];
        Assert.Equal(1L, which["cols"]);
        Assert.Equal(" > ", which["separator"]);
        Assert.False(File.Exists(_temp.PathOf(@"out\vfs.toml")));
        // init.lua: yazipane の初期化の後に普段の init.lua
        var init = File.ReadAllText(_temp.PathOf(@"out\init.lua"));
        Assert.StartsWith("require(\"yazipane\"):setup()", init);
        Assert.EndsWith("-- user init", init);
        // yazi.toml / keymap.toml: TOML として重ねる
        var yazi = (TomlTable)Parse(File.ReadAllText(_temp.PathOf(@"out\yazi.toml")))["mgr"];
        Assert.Equal("natural", yazi["sort_by"]);
        Assert.True(yazi.ContainsKey("ratio"));
        var keymap = Parse(File.ReadAllText(_temp.PathOf(@"out\keymap.toml")));
        Assert.Contains("<F5>", Keys(keymap, "mgr", "prepend_keymap"));
    }

    [Fact]
    public void Build_読めない設定は警告にしてyazipaneの設定だけを使う()
    {
        _temp.File(@"user\keymap.toml", "[mgr\nbroken = ");
        var warnings = new List<string>();

        YaziConfig.Build(_temp.PathOf("out"), _temp.PathOf("user"), warnings);

        var warning = Assert.Single(warnings);
        Assert.Contains("keymap.toml", warning);
        Assert.Contains("<F5>", Keys(Parse(File.ReadAllText(_temp.PathOf(@"out\keymap.toml"))), "mgr", "prepend_keymap"));
    }

    [Fact]
    public void Build_設定ファイルを開けなければ警告して既定の設定を使う()
    {
        var path = _temp.File(@"user\keymap.toml", "[mgr]\n");
        using var locked = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        var warnings = new List<string>();

        YaziConfig.Build(_temp.PathOf("out"), _temp.PathOf("user"), warnings);

        Assert.Contains("keymap.toml", Assert.Single(warnings));
        Assert.Contains("<F5>", Keys(Parse(File.ReadAllText(_temp.PathOf(@"out\keymap.toml"))), "mgr", "prepend_keymap"));
    }

    [Fact]
    public void Build_普段の設定にyazipaneyaziがあっても埋め込みのものを使う()
    {
        _temp.File(@"user\plugins\yazipane.yazi\main.lua", "-- 古いコピー");

        YaziConfig.Build(_temp.PathOf("out"), _temp.PathOf("user"), []);

        Assert.DoesNotContain("古いコピー", File.ReadAllText(_temp.PathOf(@"out\plugins\yazipane.yazi\main.lua")));
    }
}
