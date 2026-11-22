using Microsoft.Win32;
using static Yazipane.Interop.Native;

namespace Yazipane.Commands;

/// <summary>エクスプローラーの右クリックメニューへの登録（エクスプローラーで開くのは yazi の shell に任せている）。</summary>
internal static class Explorer
{
    private const string MenuKey = "yazipane";
    private const string MenuLabel = "yazipane で開く";

    // フォルダ / フォルダの背景（中を開いた状態で何もないところ）/ ドライブ の右クリックメニュー
    private static readonly string[] s_menuParents =
    [
        @"Software\Classes\Directory\shell",
        @"Software\Classes\Directory\Background\shell",
        @"Software\Classes\Drive\shell",
    ];

    /// <summary>
    /// <c>--register</c>: エクスプローラーの右クリックメニューに「yazipane で開く」を追加する（現在のユーザーのみ。管理者権限は不要）。
    /// 登録するのはこの exe の場所なので、exe を移動したら登録し直す。
    /// </summary>
    public static void Register()
    {
        var exe = Environment.ProcessPath ?? throw new UserFacingException("exe の場所が分かりません。");
        foreach (var parent in s_menuParents)
        {
            using var key = Registry.CurrentUser.CreateSubKey($@"{parent}\{MenuKey}");
            key.SetValue("", MenuLabel);
            key.SetValue("Icon", $"\"{exe}\",0");
            using var command = key.CreateSubKey("command");
            command.SetValue("", $"\"{exe}\" \"%V\"");
        }
        ShowInfo($"エクスプローラーの右クリックメニューに「{MenuLabel}」を追加しました。\n\n" +
                 "Windows 11 では「その他のオプションを確認」の中に表示されます。\n" +
                 $"登録した exe: {exe}\n（exe を移動したら、もう一度 --register を実行してください）");
    }

    /// <summary><c>--unregister</c>: <see cref="Register"/> で追加したメニューを消す。</summary>
    public static void Unregister()
    {
        foreach (var parent in s_menuParents)
        {
            Registry.CurrentUser.DeleteSubKeyTree($@"{parent}\{MenuKey}", throwOnMissingSubKey: false);
        }
        ShowInfo($"エクスプローラーの右クリックメニューから「{MenuLabel}」を削除しました。");
    }
}
