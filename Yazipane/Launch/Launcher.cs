using System.ComponentModel;
using System.Diagnostics;
using System.Text.RegularExpressions;

namespace Yazipane.Launch;

/// <summary>
/// ランチャー: 埋め込んだ WezTerm 設定と、普段の yazi 設定に yazipane 用の設定を重ねたものを
/// %LOCALAPPDATA%\yazipane に書き出し、専用設定で WezTerm を新しいプロセスとして起動して、終了まで待つ。
/// </summary>
internal static partial class Launcher
{
    /// <summary>--debug のログを残す起動回数</summary>
    private const int KeepLogSessions = 20;

    private sealed record Options(bool Debug, bool Reuse, string[] Dirs);

    public static void Run(string[] rawArgs)
    {
        var opts = new Options(
            rawArgs.Contains("--debug"),
            rawArgs.Contains("--reuse"),
            [.. rawArgs.Where(a => a is not ("--debug" or "--reuse"))]);

        var baseDir = DataDir();
        Directory.CreateDirectory(baseDir);
        var logDir = opts.Debug ? StartDebugLog(baseDir) : null;
        Log.Write($"yazipane {typeof(Launcher).Assembly.GetName().Version} args=[{string.Join(", ", rawArgs)}]");

        var instances = new Instances(baseDir);
        if (opts.Reuse && TryReuse(instances, opts.Dirs))
        {
            return;
        }

        var yaziDir = Path.Combine(baseDir, "yazi");
        var userYazi = YaziConfig.UserConfigDir(yaziDir);
        Log.Write($"user yazi config: {userYazi}");
        var warnings = GenerateConfig(baseDir, yaziDir, userYazi);

        var wezterm = FindExe("wezterm-gui") ?? throw new UserFacingException(
            "wezterm-gui.exe が見つかりません。\n\nscoop install wezterm\nまたは\nwinget install wez.wezterm\nでインストールしてください。");
        var yazi = FindExe("yazi") ?? throw new UserFacingException(
            "yazi.exe が見つかりません。\n\nscoop install yazi\nまたは\nwinget install sxyazi.yazi\nでインストールしてください。");

        var (left, right) = ResolveDirs(opts.Dirs, baseDir);

        // yazi の DDS クライアント ID。複数の yazipane を同時に起動しても衝突しないよう起動ごとに変える。
        // Lua の数値で正確に扱えるよう 2^52 未満にしておく。
        var id = (ulong)DateTime.UtcNow.Ticks % (1UL << 52) + 1;
        // 前回のウィンドウの位置があれば、WezTerm 側では最大化せずにこちらで復元する
        var restore = WindowPlacement.Load(baseDir);

        var psi = new ProcessStartInfo(wezterm)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = left,
        };
        foreach (var a in new[] { "--config-file", Path.Combine(baseDir, "wezterm.lua"), "start", "--always-new-process" })
        {
            psi.ArgumentList.Add(a);
        }
        if (Guid.TryParseExact(Environment.GetEnvironmentVariable("YAZIPANE_UI_TEST_SESSION"), "N", out var uiTestSession))
        {
            psi.ArgumentList.Add("--class");
            psi.ArgumentList.Add($"yazipane-test-{uiTestSession:N}");
        }
        SetEnvironment(psi, new Env(baseDir, yaziDir, userYazi, yazi, left, right, id, warnings, restore is not null, logDir));
        Log.Write($"start: {wezterm} {string.Join(" ", psi.ArgumentList)}");

        StartAndWait(psi, instances, id, baseDir, restore);
    }

    private static string DataDir() => DataDir(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        Environment.GetEnvironmentVariable("YAZIPANE_TEST_SESSION"));

    /// <summary>スモークテスト用の状態は、専用の識別子を使って通常の保存先から分離する。</summary>
    internal static string DataDir(string local, string? testSession)
    {
        var root = Path.Combine(local, "yazipane");
        return Guid.TryParseExact(testSession, "N", out var id)
            ? Path.Combine(root, "smoke", id.ToString("N"))
            : root;
    }

    /// <summary>起動ごとのログフォルダを作って記録を始める。起動ごとにフォルダが増えるので、古いものは消す。</summary>
    private static string StartDebugLog(string baseDir)
    {
        var logsRoot = Path.Combine(baseDir, "logs");
        Log.Prune(logsRoot, KeepLogSessions - 1);
        var logDir = Path.Combine(logsRoot, $"{DateTime.Now:yyyyMMdd-HHmmss}-{Environment.ProcessId}-{Guid.NewGuid():N}");
        Log.Enable(logDir, "launcher");
        return logDir;
    }

    /// <summary>--reuse: 起動中の yazipane があれば、新しいウィンドウを開かずにそのウィンドウでフォルダを開く。開けたら true。</summary>
    private static bool TryReuse(Instances instances, string[] dirs)
    {
        if (instances.Alive().FirstOrDefault() is not { } running)
        {
            return false;
        }
        string? l = null, r = null;
        if (dirs.Length >= 1)
        {
            l = CheckDir(dirs[0]);
            r = dirs.Length >= 2 ? CheckDir(dirs[1]) : l;
        }
        if (Instances.Reuse(running, FindExe("ya"), l, r))
        {
            Log.Write($"reuse: wezterm pid={running.WeztermPid}");
            return true;
        }
        Log.Write("reuse: 起動中のウィンドウに伝えられないので、新しく起動する");
        return false;
    }

    /// <summary>
    /// WezTerm / yazi の設定を書き出す。普段の設定の問題（読めない TOML など）は警告として返す。
    /// 複数の yazipane を同時に起動したときに設定ファイルを同時に書き換えないよう、生成中は排他する。
    /// </summary>
    private static List<string> GenerateConfig(string baseDir, string yaziDir, string userYazi)
    {
        var warnings = new List<string>();
        using var mutex = new Mutex(false, @"Local\yazipane-config");
        bool owned;
        try
        {
            owned = mutex.WaitOne(TimeSpan.FromSeconds(10));
        }
        catch (AbandonedMutexException)
        {
            owned = true;
        }
        if (!owned)
        {
            throw new UserFacingException("設定の生成を待ちきれませんでした。別の yazipane の起動が終わってから再試行してください。");
        }
        try
        {
            Files.WriteIfChanged(Path.Combine(baseDir, "wezterm.lua"), Assets.Read("assets/wezterm.lua"));
            YaziConfig.Build(yaziDir, userYazi, warnings);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new UserFacingException($"設定の生成に失敗しました:\n{e.Message}");
        }
        finally
        {
            mutex.ReleaseMutex();
        }
        foreach (var w in warnings)
        {
            Log.Write($"warning: {w}");
        }
        return warnings;
    }

    private sealed record Env(
        string BaseDir, string YaziDir, string UserYazi, string Yazi, string Left, string Right,
        ulong Id, List<string> Warnings, bool RestoreWindow, string? LogDir);

    /// <summary>
    /// WezTerm（とその中の yazi）に渡す環境変数。wezterm.lua の pane_env が yazi へ渡し直す。
    /// 新しい変数を足すときは pane_env にも足す。
    /// </summary>
    private static void SetEnvironment(ProcessStartInfo psi, Env e)
    {
        var env = psi.Environment;
        // WezTerm (Windows) は起動時にレジストリのユーザー環境変数で自身の環境を上書きするため、
        // YAZI_CONFIG_HOME を直接渡すとユーザー設定値に戻されてしまう。別名で渡して Lua 側で詰め替える。
        env["YAZIPANE_CONFIG_HOME"] = e.YaziDir;
        // ペイン内から yazipane を再度起動したときに、普段の設定の場所が分かるようにする
        env["YAZIPANE_USER_CONFIG_HOME"] = e.UserYazi;
        env["YAZIPANE_YAZI"] = e.Yazi;
        // 普段の WezTerm 設定（フォントや配色など）を土台にするため、その場所を渡す
        env["YAZIPANE_USER_WEZTERM"] = UserWeztermConfig(Path.Combine(e.BaseDir, "wezterm.lua")) ?? "";
        // WezTerm から yazi へ 1 画面 / 2 画面の切り替えを伝えるのに使う（無ければその機能だけ無効）
        env["YAZIPANE_YA"] = FindExe("ya") ?? "";
        // 1 画面のときに使う、普段の yazi の列の比率
        env["YAZIPANE_NATIVE_RATIO"] = YaziConfig.NativeRatio(e.UserYazi);
        // 右クリックメニューなどのために yazi のプラグインから自分自身を呼ぶ
        env["YAZIPANE_EXE"] = Environment.ProcessPath ?? "";
        env["YAZIPANE_LEFT_DIR"] = e.Left;
        env["YAZIPANE_RIGHT_DIR"] = e.Right;
        env["YAZIPANE_LEFT_ID"] = e.Id.ToString();
        env["YAZIPANE_RIGHT_ID"] = (e.Id + 1).ToString();
        // 前回のフォルダを記録する場所
        env["YAZIPANE_STATE_DIR"] = e.BaseDir;
        // 設定の生成中に見つかった問題を yazi の通知で表示する
        env["YAZIPANE_WARNINGS"] = string.Join("\n", e.Warnings);
        env["YAZIPANE_RESTORE_WINDOW"] = e.RestoreWindow ? "1" : "";
        env.Remove("YAZIPANE_LOG_DIR");
        env.Remove("YAZIPANE_DEBUG");
        if (e.LogDir is not null)
        {
            env["YAZI_LOG"] = "debug";
            env["YAZIPANE_DEBUG"] = "1";
            env["YAZIPANE_LOG_DIR"] = e.LogDir;
        }

        foreach (var key in new[] { "YAZIPANE_YAZI", "YAZIPANE_YA", "YAZIPANE_USER_WEZTERM", "YAZIPANE_NATIVE_RATIO",
                     "YAZIPANE_LEFT_DIR", "YAZIPANE_RIGHT_DIR", "YAZIPANE_LEFT_ID", "YAZIPANE_RIGHT_ID" })
        {
            Log.Write($"{key}={env[key]}");
        }
    }

    /// <summary>WezTerm を起動し、ウィンドウに yazipane のアイコンを付けて、WezTerm が終了するまで待つ。</summary>
    private static void StartAndWait(ProcessStartInfo psi, Instances instances, ulong id, string baseDir, WindowPlacement.Saved? restore)
    {
        Process? wez;
        try
        {
            wez = Process.Start(psi);
        }
        // 実行ファイルが起動できない（Win32Exception）、起動の指定が不正（InvalidOperationException）
        catch (Exception e) when (e is Win32Exception or InvalidOperationException)
        {
            Log.Write($"start failed: {e}");
            throw new UserFacingException($"WezTerm の起動に失敗しました:\n{e.Message}");
        }
        if (wez is null)
        {
            return;
        }
        using (wez)
        {
            // --reuse で後から起動されたときに見つけられるよう、動いている間だけ記録しておく
            var record = instances.Add(id, id + 1, wez.Id);
            try
            {
                WindowIcon.ApplyAndWait(wez, baseDir, restore);
            }
            finally
            {
                Instances.Remove(record);
            }
        }
    }

    /// <summary>
    /// 普段の WezTerm 設定ファイルを探す（WezTerm と同じ優先順: WEZTERM_CONFIG_FILE → ~/.config/wezterm/wezterm.lua → ~/.wezterm.lua）。
    /// yazipane のペイン内から起動されたときに自分の設定を拾わないよう、own と同じなら無視する。
    /// </summary>
    private static string? UserWeztermConfig(string own) =>
        UserWeztermConfig(own, Environment.GetEnvironmentVariable, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));

    /// <summary>テスト用: 環境変数とホームフォルダを引数で受け取る</summary>
    internal static string? UserWeztermConfig(string own, Func<string, string?> getEnv, string home)
    {
        var candidates = new[]
        {
            getEnv("YAZIPANE_USER_WEZTERM"),
            getEnv("WEZTERM_CONFIG_FILE"),
            Path.Combine(home, ".config", "wezterm", "wezterm.lua"),
            Path.Combine(home, ".wezterm.lua"),
        };
        foreach (var c in candidates)
        {
            if (!string.IsNullOrEmpty(c) && File.Exists(c)
                && !string.Equals(Path.GetFullPath(c), Path.GetFullPath(own), StringComparison.OrdinalIgnoreCase))
            {
                return Path.GetFullPath(c);
            }
        }
        return null;
    }

    /// <summary>
    /// 左右のディレクトリを決める。
    /// 引数があればそれを使い、無ければ前回終了時のフォルダ（yazi のプラグインが記録したもの）を復元する。
    /// 前回のフォルダが無い・消えている場合はカレントディレクトリ（exe の場所ならホーム）。
    /// </summary>
    internal static (string Left, string Right) ResolveDirs(string[] dirs, string stateDir)
    {
        if (dirs.Length >= 1)
        {
            var l = CheckDir(dirs[0]);
            return (l, dirs.Length >= 2 ? CheckDir(dirs[1]) : l);
        }

        var cwd = Environment.CurrentDirectory;
        // ダブルクリック起動などで exe の場所が cwd になっている場合はホームを使う
        var exeDir = Path.GetDirectoryName(Environment.ProcessPath);
        if (exeDir is not null && Files.SameDir(exeDir, cwd))
        {
            cwd = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }
        return (LastDir(stateDir, "left") ?? cwd, LastDir(stateDir, "right") ?? LastDir(stateDir, "left") ?? cwd);
    }

    private static string? LastDir(string stateDir, string side)
    {
        try
        {
            var dir = File.ReadAllText(Path.Combine(stateDir, $"last-{side}.txt")).Trim();
            return dir.Length > 0 && Directory.Exists(dir) ? Path.GetFullPath(dir) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    internal static string CheckDir(string p)
    {
        var abs = Path.GetFullPath(p);
        if (File.Exists(abs))
        {
            throw new UserFacingException($"ディレクトリではありません: {p}");
        }
        if (!Directory.Exists(abs))
        {
            throw new UserFacingException($"ディレクトリが開けません: {p}");
        }
        return abs;
    }

    [GeneratedRegex("""^\s*path\s*=\s*"?([^"\r\n]+?)"?\s*$""", RegexOptions.Multiline)]
    private static partial Regex ShimPath();

    /// <summary>
    /// PATH から実行ファイルを探す。scoop の shim だった場合は実体のパスを返す
    /// （shim はコンソールアプリなので、GUI を shim 経由で起動すると黒い窓が出るため）。
    /// </summary>
    private static string? FindExe(string name) => FindExe(name, Environment.GetEnvironmentVariable("PATH") ?? "");

    /// <summary>テスト用: PATH を引数で受け取る</summary>
    internal static string? FindExe(string name, string path)
    {
        foreach (var dir in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            string candidate;
            try
            {
                candidate = Path.Combine(dir.Trim('"'), name + ".exe");
            }
            catch (ArgumentException)
            {
                continue;
            }
            if (File.Exists(candidate))
            {
                return ResolveShim(candidate) ?? candidate;
            }
        }
        return null;
    }

    /// <summary>scoop の shim なら実体のパスを返す。shim でない・読めない場合は null（shim の exe をそのまま使う）。</summary>
    internal static string? ResolveShim(string exe)
    {
        var shim = Path.ChangeExtension(exe, ".shim");
        try
        {
            if (!File.Exists(shim))
            {
                return null;
            }
            var m = ShimPath().Match(File.ReadAllText(shim));
            var target = m.Success ? m.Groups[1].Value.Trim() : null;
            return target is not null && File.Exists(target) ? target : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Write($"shim を読めません: {shim}: {e.Message}");
            return null;
        }
    }
}
