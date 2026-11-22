using System.Diagnostics;

namespace Yazipane.Commands;

/// <summary>指定した左右のフォルダで、新しい yazipane を起動する。</summary>
internal static class NewWindow
{
    public static int Run(string[] args)
    {
        if (args.Length != 2)
        {
            throw new UserFacingException("左右のフォルダを指定してください");
        }

        var exe = Environment.ProcessPath ?? throw new UserFacingException("実行ファイルの場所が分かりません");
        // プラグインの出力パイプを新しいプロセスが保持すると、ウィンドウ終了まで yazi が待ち続ける。
        var start = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.ArgumentList.Add(args[0]);
        start.ArgumentList.Add(args[1]);
        using var process = Process.Start(start) ?? throw new UserFacingException("新しいウィンドウを起動できません");
        return 0;
    }
}
