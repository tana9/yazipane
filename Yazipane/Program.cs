// yazipane: WezTerm 上で yazi を左右 2 画面に並べて起動するランチャー。
//
// 使い方:
//   yazipane [--debug] [--reuse] [左ペインのディレクトリ] [右ペインのディレクトリ]
//   yazipane --register | --unregister
//
// 引数の先頭が下の s_pluginCommands にあるものは、yazi のプラグインから呼ばれるサブコマンド（Commands/ 以下）。
// それ以外はランチャーとして WezTerm を起動する（Launch/ 以下）。

namespace Yazipane;

/// <summary>ユーザーにそのまま表示するエラー。</summary>
internal sealed class UserFacingException(string message) : Exception(message);

internal static class Program
{
    /// <summary>
    /// yazi のプラグイン（main.lua）から呼ばれるサブコマンド。結果は標準出力、エラーは標準エラー出力と終了コードで返す。
    /// </summary>
    private static readonly Dictionary<string, Func<string[], int>> s_pluginCommands = new()
    {
        ["--context-menu"] = ShellMenu.Run,          // 右クリックメニュー
        ["--clipboard"] = ShellData.CopyToClipboard,  // クリップボードへコピー
        ["--clipboard-cut"] = ShellData.CutToClipboard,  // クリップボードへ切り取り
        ["--drag"] = ShellData.Drag,                  // ほかのアプリへドラッグ
        ["--transfer"] = FileOps.Transfer,            // 反対ペインへコピー / 移動（F5 / F6）
        ["--paste"] = FileOps.Paste,                  // クリップボードから貼り付け（Ctrl+V）
        ["--drives"] = Drives.List,                   // ドライブの一覧（Alt+D）
        ["--free"] = Drives.Free,                     // ドライブの空き容量（ステータスバー）
        ["--new-window"] = NewWindow.Run,              // 同じ左右のフォルダで新しいウィンドウ
        ["--pairs"] = FolderPairs.Run,                 // 左右のフォルダの組
        ["--same-dir"] = Paths.SameDir,                // Windows のパス比較（プラグイン内部）
    };

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length >= 1 && s_pluginCommands.TryGetValue(args[0], out var command))
        {
            return RunPluginCommand(args[0], command, args[1..]);
        }

        try
        {
            switch (args.FirstOrDefault())
            {
                case "--register":
                    Explorer.Register();
                    break;
                case "--unregister":
                    Explorer.Unregister();
                    break;
                default:
                    Launcher.Run(args);
                    break;
            }
            return 0;
        }
        catch (UserFacingException e)
        {
            Native.ShowError(e.Message);
            return 1;
        }
        catch (Exception e)
        {
            Native.ShowError($"予期しないエラーが発生しました。\n\n{e}");
            return 1;
        }
    }

    private static int RunPluginCommand(string name, Func<string[], int> command, string[] args)
    {
        // yazi は出力を UTF-8 として読むので、コンソールのコードページ（CP932）ではなく UTF-8 で書く
        var utf8 = new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
        Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), utf8) { AutoFlush = true });
        Console.SetError(new StreamWriter(Console.OpenStandardError(), utf8) { AutoFlush = true });
        // --debug で起動したペインから呼ばれたときは、同じセッションの別ファイルに記録する
        var logDir = Environment.GetEnvironmentVariable("YAZIPANE_LOG_DIR");
        if (Environment.GetEnvironmentVariable("YAZIPANE_DEBUG") == "1" && !string.IsNullOrEmpty(logDir))
        {
            Log.Enable(logDir, name.TrimStart('-'));
            Log.Write($"args=[{string.Join(", ", args)}]");
        }
        try
        {
            return command(args);
        }
        catch (Exception e)
        {
            // 想定外の例外でもスタックトレースではなくメッセージだけを yazi に返す
            Log.Write($"unhandled: {e}");
            Console.Error.Write(e.Message);
            return 1;
        }
    }
}
