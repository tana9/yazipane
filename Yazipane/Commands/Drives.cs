using System.Runtime.InteropServices;

namespace Yazipane.Commands;

/// <summary>
/// <c>--drives</c>: ドライブの一覧を「ドライブ\t説明」の行で標準出力に書く（yazi のプラグインがドライブの切り替えに使う）。
/// ネットワークドライブは接続先の取得だけにとどめ、応答を待つ操作（ボリューム名・空き容量）はしない。
/// </summary>
internal static unsafe partial class Drives
{
    public static int List(string[] _)
    {
        // メディアの無いドライブで「ディスクを挿入してください」のダイアログを出さない
        SetErrorMode(SEM_FAILCRITICALERRORS);
        var mask = GetLogicalDrives();
        for (var i = 0; i < 26; i++)
        {
            if ((mask & (1u << i)) == 0)
            {
                continue;
            }
            var root = $"{(char)('A' + i)}:\\";
            Console.Out.Write($"{root}\t{Describe(root)}\n");
        }
        return 0;
    }

    /// <summary><c>--free &lt;パス&gt;</c>: そのパスのドライブの空き容量を「空き 120 GB / 500 GB」の形で書く（ステータスバー用）。</summary>
    public static int Free(string[] args)
    {
        if (args.Length != 1)
        {
            Console.Error.Write("使い方: --free <パス>");
            return 1;
        }
        SetErrorMode(SEM_FAILCRITICALERRORS);
        ulong free, total;
        if (GetDiskFreeSpaceExW(args[0], &free, &total, null) == 0 || total == 0)
        {
            Console.Error.Write($"空き容量を取得できません: {args[0]}");
            return 1;
        }
        Console.Out.Write($"空き {FormatSize(free)} / {FormatSize(total)}");
        return 0;
    }

    internal static string Describe(string root)
    {
        var type = GetDriveTypeW(root);
        var kind = type switch
        {
            DRIVE_REMOVABLE => "リムーバブル",
            DRIVE_FIXED => "ローカル ディスク",
            DRIVE_REMOTE => "ネットワーク",
            DRIVE_CDROM => "CD / DVD",
            DRIVE_RAMDISK => "RAM ディスク",
            _ => "ドライブ",
        };
        if (type == DRIVE_REMOTE)
        {
            return RemoteName(root) is { } unc ? $"{kind}  {unc}" : kind;
        }

        var label = VolumeLabel(root);
        if (label is null)
        {
            return $"{kind}（メディアなし）";
        }
        var name = label.Length > 0 ? label : kind;
        ulong free, total;
        if (GetDiskFreeSpaceExW(root, &free, &total, null) != 0 && total > 0)
        {
            name = $"空き {FormatSize(free)} / {FormatSize(total)}  {name}";
        }
        return name;
    }

    internal static string FormatSize(ulong bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB", "PB"];
        double v = bytes;
        var u = 0;
        while (v >= 1024 && u < units.Length - 1)
        {
            v /= 1024;
            u++;
        }
        return u == 0 ? $"{bytes} B" : $"{v:0.#} {units[u]}";
    }

    private static string? VolumeLabel(string root)
    {
        var buf = stackalloc char[261];
        return GetVolumeInformationW(root, buf, 261, null, null, null, null, 0) != 0 ? new string(buf) : null;
    }

    private static string? RemoteName(string root)
    {
        var buf = stackalloc char[1024];
        uint len = 1024;
        return WNetGetConnectionW(root.TrimEnd('\\'), buf, &len) == 0 ? new string(buf) : null;
    }

    private const uint DRIVE_REMOVABLE = 2, DRIVE_FIXED = 3, DRIVE_REMOTE = 4, DRIVE_CDROM = 5, DRIVE_RAMDISK = 6;
    private const uint SEM_FAILCRITICALERRORS = 0x1;

    [LibraryImport("kernel32.dll")] private static partial uint GetLogicalDrives();
    [LibraryImport("kernel32.dll")] private static partial uint SetErrorMode(uint mode);
    [LibraryImport("kernel32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial uint GetDriveTypeW(string root);
    [LibraryImport("kernel32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int GetVolumeInformationW(string root, char* name, uint nameSize, uint* serial, uint* maxComponent, uint* flags, char* fsName, uint fsNameSize);
    [LibraryImport("kernel32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int GetDiskFreeSpaceExW(string dir, ulong* freeToCaller, ulong* total, ulong* totalFree);
    [LibraryImport("mpr.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial uint WNetGetConnectionW(string local, char* remote, uint* length);
}
