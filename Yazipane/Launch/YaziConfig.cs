using System.Text;
using Tomlyn;
using Tomlyn.Model;
using Tomlyn.Serialization;

namespace Yazipane.Launch;

/// <summary>NativeAOT（トリミング）に対応するため、TomlTable の (de)serialize はソース生成を使う。</summary>
[TomlSerializable(typeof(TomlTable))]
internal partial class TomlContext : TomlSerializerContext;

/// <summary>書き出し用: テーブルの配列は [[a.b]] の見出し形式にして読みやすくする</summary>
[TomlSourceGenerationOptions(
    TableArrayStyle = TomlTableArrayStyle.Headers,
    InlineTablePolicy = TomlInlineTablePolicy.WhenSmall,
    BlankLineBeforeTableHeaders = true)]
[TomlSerializable(typeof(TomlTable))]
internal partial class TomlWriteContext : TomlSerializerContext;

/// <summary>普段の yazi 設定を土台に、yazipane 用の設定を重ねた設定ディレクトリを組み立てる。</summary>
internal static class YaziConfig
{

    // ユーザーの yazi 設定をそのままコピーするファイル/ディレクトリ
    private static readonly string[] s_passthroughFiles = ["theme.toml", "vfs.toml", "package.toml"];
    private static readonly string[] s_passthroughDirs = ["flavors"];

    private const string OwnPlugin = "yazipane.yazi";

    /// <summary>
    /// 普段使っている yazi の設定ディレクトリを返す。
    /// yazipane のペイン内から起動された場合に自分の生成ディレクトリを拾わないよう、
    /// YAZIPANE_USER_CONFIG_HOME を優先し、生成先と同じなら無視する。
    /// </summary>
    public static string UserConfigDir(string generated) =>
        UserConfigDir(generated, Environment.GetEnvironmentVariable, Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData));

    /// <summary>テスト用: 環境変数と %APPDATA% を引数で受け取る</summary>
    internal static string UserConfigDir(string generated, Func<string, string?> getEnv, string appData)
    {
        foreach (var key in new[] { "YAZIPANE_USER_CONFIG_HOME", "YAZI_CONFIG_HOME" })
        {
            var d = getEnv(key);
            if (!string.IsNullOrEmpty(d) && !Files.SameDir(d, generated))
            {
                return d;
            }
        }
        return Path.Combine(appData, "yazi", "config");
    }

    /// <summary>
    /// 普段の yazi.toml の [mgr] ratio を "1,3,4" の形で返す（1 画面表示に戻すときに使う）。
    /// 設定が無い・読めない場合は yazi の既定値。
    /// </summary>
    public static string NativeRatio(string user)
    {
        const string fallback = "1,4,3";
        var file = Path.Combine(user, "yazi.toml");
        if (!File.Exists(file))
        {
            return fallback;
        }
        try
        {
            var table = TomlSerializer.Deserialize(File.ReadAllText(file), TomlContext.Default.TomlTable);
            if (table is not null
                && table.TryGetValue("mgr", out var mgr) && mgr is TomlTable mgrTable
                && mgrTable.TryGetValue("ratio", out var ratio) && ratio is TomlArray arr && arr.Count == 3)
            {
                return string.Join(",", arr.Select(v => Convert.ToInt64(v)));
            }
        }
        catch (Exception e) when (e is TomlException or IOException or UnauthorizedAccessException
                                      or InvalidCastException or FormatException or OverflowException)
        {
        }
        return fallback;
    }

    /// <summary>設定を組み立てる。ユーザー設定の問題（読めない TOML など）は warnings に追加して続行する。</summary>
    public static void Build(string dst, string user, List<string> warnings)
    {
        Directory.CreateDirectory(dst);
        BuildPlugins(dst, user);

        foreach (var name in s_passthroughDirs)
        {
            string src = Path.Combine(user, name), outDir = Path.Combine(dst, name);
            if (Directory.Exists(src))
            {
                Files.SyncDir(src, outDir);
            }
            else if (Directory.Exists(outDir))
            {
                Directory.Delete(outDir, recursive: true);
            }
        }
        foreach (var name in s_passthroughFiles)
        {
            string src = Path.Combine(user, name), outFile = Path.Combine(dst, name);
            if (File.Exists(src))
            {
                Files.WriteIfChanged(outFile, File.ReadAllBytes(src));
            }
            else
            {
                File.Delete(outFile);
            }
        }

        // init.lua: yazipane の初期化を先に行い、その後にユーザーの init.lua を続ける
        var init = new StringBuilder(Encoding.UTF8.GetString(Assets.Read("assets/yazi/init.lua")));
        var userInit = Path.Combine(user, "init.lua");
        if (File.Exists(userInit))
        {
            init.Append($"\n-- ===== {userInit} =====\n");
            init.Append(File.ReadAllText(userInit));
        }
        Files.WriteIfChanged(Path.Combine(dst, "init.lua"), Encoding.UTF8.GetBytes(init.ToString()));

        // yazi.toml / keymap.toml: TOML としてマージ
        foreach (var name in new[] { "yazi.toml", "keymap.toml" })
        {
            var overlay = Encoding.UTF8.GetString(Assets.Read($"assets/yazi/{name}"));
            var userFile = Path.Combine(user, name);
            var baseText = "";
            try
            {
                if (File.Exists(userFile)) baseText = File.ReadAllText(userFile);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                warnings.Add($"{userFile} を読み込めないため、yazipane の設定だけを使います: {e.Message}");
            }
            var merged = MergeToml(baseText, overlay, out var error);
            if (error is not null)
            {
                warnings.Add($"{userFile} を読み込めないため、yazipane の設定だけを使います: {error}");
            }
            Files.WriteIfChanged(Path.Combine(dst, name), Encoding.UTF8.GetBytes(merged));
        }
    }

    /// <summary>ユーザーのプラグイン + yazipane.yazi を dst/plugins に揃える。</summary>
    private static void BuildPlugins(string dst, string user)
    {
        var plugins = Path.Combine(dst, "plugins");
        HashSet<string> keep = [with(StringComparer.OrdinalIgnoreCase), OwnPlugin];

        var userPlugins = Path.Combine(user, "plugins");
        if (Directory.Exists(userPlugins))
        {
            foreach (var dir in Directory.EnumerateDirectories(userPlugins))
            {
                var name = Path.GetFileName(dir);
                if (name.Equals(OwnPlugin, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                keep.Add(name);
                Files.SyncDir(dir, Path.Combine(plugins, name));
            }
        }
        Assets.Extract("assets/yazi/plugins", plugins);

        // ユーザー側で削除されたプラグインを消す
        foreach (var entry in Directory.EnumerateFileSystemEntries(plugins))
        {
            if (keep.Contains(Path.GetFileName(entry)))
            {
                continue;
            }
            if (Directory.Exists(entry))
            {
                Directory.Delete(entry, recursive: true);
            }
            else
            {
                File.Delete(entry);
            }
        }
    }

    private const string GeneratedHeader =
        "# yazipane が生成したファイル（普段の設定 + yazipane 用設定）。編集しても次回起動時に上書きされる。\n";

    /// <summary>
    /// baseText に overlay を重ねる。baseText が空か壊れている場合は overlay だけを使い、
    /// 壊れていた場合はその理由を error に返す。
    /// </summary>
    public static string MergeToml(string baseText, string overlayText, out string? error)
    {
        error = null;
        var overlay = TomlSerializer.Deserialize(overlayText, TomlContext.Default.TomlTable)!;
        TomlTable baseTable;
        try
        {
            baseTable = string.IsNullOrWhiteSpace(baseText)
                ? []
                : TomlSerializer.Deserialize(baseText, TomlContext.Default.TomlTable) ?? [];
        }
        catch (TomlException e)
        {
            // ユーザー設定が壊れている場合は yazipane の設定だけで起動する
            // （メッセージは "... Reason: (行,列) : error : 理由" の形なので、位置と理由だけを残す）
            var reason = e.Message.IndexOf("Reason: ", StringComparison.Ordinal);
            error = reason >= 0 ? e.Message[(reason + "Reason: ".Length)..] : e.Message;
            baseTable = [];
        }

        Merge(baseTable, overlay);
        Normalize(baseTable);
        return GeneratedHeader + TomlSerializer.Serialize(baseTable, TomlWriteContext.Default.TomlTable);
    }

    /// <summary>
    /// テーブルだけを並べた配列（x = [{...}, {...}]）を [[x]] 形式（TomlTableArray）にそろえ、書き出したときに読みやすくする。
    /// </summary>
    private static void Normalize(TomlTable table)
    {
        foreach (var key in table.Keys.ToList())
        {
            switch (table[key])
            {
                case TomlTable child:
                    Normalize(child);
                    break;
                case TomlArray arr when arr.Count > 0 && arr.All(i => i is TomlTable):
                    var ta = (TomlTableArray)ToTomlArray([.. arr]);
                    foreach (var t in ta)
                    {
                        Normalize(t);
                    }
                    table[key] = ta;
                    break;
                case TomlTableArray tableArray:
                    foreach (var t in tableArray)
                    {
                        Normalize(t);
                    }
                    break;
            }
        }
    }

    /// <summary>
    /// テーブルを再帰的にマージする。prepend_* の配列は overlay を先頭に、append_* の配列は overlay を末尾に連結し、
    /// それ以外の値は overlay で上書きする。
    /// </summary>
    private static void Merge(TomlTable target, TomlTable overlay)
    {
        foreach (var (key, ov) in overlay)
        {
            target.TryGetValue(key, out var bv);

            if (ov is TomlTable ot && bv is TomlTable bt)
            {
                Merge(bt, ot);
                continue;
            }

            if (AsList(ov) is { } oList && AsList(bv) is { } bList)
            {
                if (key.StartsWith("prepend_", StringComparison.Ordinal))
                {
                    target[key] = ToTomlArray([.. oList, .. bList]);
                    continue;
                }
                if (key.StartsWith("append_", StringComparison.Ordinal))
                {
                    target[key] = ToTomlArray([.. bList, .. oList]);
                    continue;
                }
            }

            target[key] = ov;
        }
    }

    // [[x]] は TomlTableArray、x = [ ... ] は TomlArray になるので、どちらも同じように扱う
    private static List<object?>? AsList(object? v) => v switch
    {
        TomlTableArray ta => [.. ta.Cast<object?>()],
        TomlArray a => [.. a],
        _ => null,
    };

    private static object ToTomlArray(List<object?> items)
    {
        if (items.All(i => i is TomlTable))
        {
            var ta = new TomlTableArray();
            foreach (var i in items)
            {
                ta.Add((TomlTable)i!);
            }
            return ta;
        }
        var a = new TomlArray();
        foreach (var i in items)
        {
            a.Add(i);
        }
        return a;
    }
}
