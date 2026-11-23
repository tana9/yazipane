namespace Yazipane.Commands;

/// <summary>Windows のファイルシステムパスを比較する。</summary>
internal static class Paths
{
    /// <summary>大文字小文字や区切り文字が異なっても同じフォルダなら 1 を返す。</summary>
    public static int SameDir(string[] args)
    {
        if (args.Length != 2)
        {
            Console.Error.Write("使い方: --same-dir <パス1> <パス2>");
            return 1;
        }
        Console.Out.Write(Files.SameDir(args[0], args[1]) ? '1' : '0');
        return 0;
    }
}
