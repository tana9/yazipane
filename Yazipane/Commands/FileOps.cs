using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using static Yazipane.Interop.Native;

namespace Yazipane.Commands;

/// <summary>
/// エクスプローラーと同じファイル操作（IFileOperation）でコピー / 移動する。
/// 進捗・同名ファイルの確認（置き換え / スキップ）・エラーはエクスプローラーと同じダイアログで表示され、元に戻す（Ctrl+Z）にも残る。
/// 進み具合の通知（IFileOperationProgressSink）を受け取り、渡した項目ごとに「できた / スキップ / 失敗」を数える。
/// </summary>
internal static unsafe partial class FileOps
{
    /// <summary>終了コード: 0 = 完了 / 1 = 失敗 / 4 = 途中で取り消された / 5 = 対象が無い</summary>
    public const int Done = 0, Failed = 1, Aborted = 4, Nothing = 5;

    /// <summary>コピー / 移動の結果。件数は渡した項目（フォルダならフォルダ 1 つ）を単位に数える。</summary>
    internal readonly record struct Result(int Code, int Succeeded, int Skipped, int Errors)
    {
        /// <summary>標準出力に書く形（"できた件数 スキップした件数 失敗した件数"）</summary>
        public string Counts => $"{Succeeded} {Skipped} {Errors}";
    }

    /// <summary>
    /// <c>--transfer copy|move &lt;コピー先&gt; &lt;パス...&gt;</c>: 反対ペインへのコピー / 移動（F5 / F6）。
    /// 実行したら（取り消された場合も）"できた件数 スキップした件数 失敗した件数" を標準出力に書く。
    /// </summary>
    public static int Transfer(string[] args)
    {
        if (args.Length < 3 || args[0] is not ("copy" or "move"))
        {
            Console.Error.Write("使い方: --transfer copy|move <コピー先> <パス...>");
            return Failed;
        }
        var result = Execute(args[0] == "move", args[1], args[2..]);
        if (result.Code is Done or Aborted)
        {
            Console.Out.Write(result.Counts);
        }
        return result.Code;
    }

    /// <summary>
    /// <c>--paste &lt;貼り付け先&gt;</c>: クリップボードのファイル（エクスプローラーでコピー / 切り取りしたもの）を貼り付ける。
    /// 実行したら（取り消された場合も）"copy|move できた件数 スキップした件数 失敗した件数" を標準出力に書く。
    /// </summary>
    public static int Paste(string[] args)
    {
        if (args.Length != 1)
        {
            Console.Error.Write("使い方: --paste <貼り付け先>");
            return Failed;
        }
        var (files, move, sequence) = Clipboard.ReadFiles();
        if (files.Count == 0)
        {
            Console.Error.Write("クリップボードにファイルがありません");
            return Nothing;
        }
        var result = Execute(move, args[0], files);
        if (result.Code is Done or Aborted)
        {
            // 切り取ったものは貼り付けた後には残っていないので、エクスプローラーと同じくクリップボードから消す
            if (move && ShouldClearClipboard(result, files.Count))
            {
                Clipboard.Clear(sequence);
            }
            Console.Out.Write($"{(move ? "move" : "copy")} {result.Counts}");
        }
        return result.Code;
    }

    /// <summary>
    /// paths を dest へコピー / 移動する。extraFlags はテスト用（ダイアログを出さない FOF_SILENT など）。
    /// エラーの説明は標準エラー出力に書く。
    /// </summary>
    internal static bool ShouldClearClipboard(Result result, int count) =>
        result.Code == Done && count > 0 && result.Succeeded == count && result.Skipped == 0 && result.Errors == 0;

    internal static Result Execute(bool move, string dest, IReadOnlyList<string> paths, uint extraFlags = 0)
    {
        var dst = Path.GetFullPath(dest);
        if (!Directory.Exists(dst))
        {
            Console.Error.Write($"コピー先のフォルダがありません: {dst}");
            return new Result(Failed, 0, 0, 0);
        }
        var fullPaths = paths.Select(Path.GetFullPath).ToList();
        var sources = fullPaths.Where(p => File.Exists(p) || Directory.Exists(p)).ToList();
        var missing = fullPaths.Count - sources.Count;
        var sameDir = sources.Where(p => IsIn(p, dst)).ToList();
        if (move)
        {
            sources = [.. sources.Except(sameDir)];
        }
        if (sources.Count == 0)
        {
            Console.Error.Write("コピー / 移動できるファイルがありません");
            return new Result(Nothing, 0, 0, missing);
        }

        // 同じフォルダへのコピーだけを別の操作に分け、別名にする。
        var groups = !move && sameDir.Count > 0
            ? new[] { [.. sources.Except(sameDir)], sameDir }
            : [sources];
        var succeeded = 0;
        var skipped = move ? sameDir.Count : 0;
        var errors = missing;
        foreach (var group in groups)
        {
            if (group.Count == 0) continue;
            var flags = FOF_ALLOWUNDO | FOF_NOCONFIRMMKDIR | FOFX_ADDUNDORECORD | extraFlags;
            if (!move && IsIn(group[0], dst)) flags |= FOF_RENAMEONCOLLISION;
            var result = ExecuteBatch(move, dst, group, flags);
            succeeded += result.Succeeded;
            skipped += result.Skipped;
            errors += result.Errors;
            if (result.Code != Done)
            {
                return new Result(result.Code, succeeded, skipped, errors);
            }
        }
        return new Result(Done, succeeded, skipped, errors);
    }

    private static Result ExecuteBatch(bool move, string dst, List<string> sources, uint flags)
    {
        OleInitialize(0);
        var owner = OwnerWindow.Create();
        nint op = 0, destItem = 0;
        var items = new List<nint>();
        Sink.Begin(sources);
        try
        {
            var clsid = CLSID_FileOperation;
            var iid = IID_IFileOperation;
            Com.Check(CoCreateInstance(&clsid, 0, CLSCTX_ALL, &iid, &op));
            Com.Check(FileOperation_SetOperationFlags(op, flags));
            Com.Check(FileOperation_SetOwnerWindow(op, owner));
            uint cookie;
            Com.Check(FileOperation_Advise(op, Sink.Pointer, &cookie));

            destItem = ShellItem(dst);
            foreach (var s in sources)
            {
                var item = ShellItem(s);
                items.Add(item);
                Com.Check(move
                    ? FileOperation_MoveItem(op, item, destItem, null, 0)
                    : FileOperation_CopyItem(op, item, destItem, null, 0));
            }

            // ダイアログを WezTerm のウィンドウの中央に、前面に出す
            var previous = GetForegroundWindow();
            OwnerWindow.CenterOn(owner, previous);
            OwnerWindow.ForceForeground(owner, previous);
            var hr = FileOperation_PerformOperations(op);
            int aborted;
            FileOperation_GetAnyOperationsAborted(op, &aborted);
            SetForegroundWindow(previous);

            var (succeeded, skipped, errors) = Sink.Counts;
            Log.Write($"fileop: {(move ? "move" : "copy")} {sources.Count} -> {dst} hr=0x{hr:X8} aborted={aborted} " +
                      $"succeeded={succeeded} skipped={skipped} errors={errors}");
            if (aborted != 0 || hr is E_USER_CANCELLED or HRESULT_ERROR_CANCELLED)
            {
                return new Result(Aborted, succeeded, skipped, errors);
            }
            if (hr < 0 && succeeded == 0 && skipped == 0)
            {
                // 失敗の内容はエクスプローラーのダイアログで表示済み
                Console.Error.Write($"コピー / 移動に失敗しました (0x{hr:X8})");
                return new Result(Failed, succeeded, skipped, errors);
            }
            return new Result(Done, succeeded, skipped, errors);
        }
        catch (COMException e)
        {
            Console.Error.Write(e.Message);
            return new Result(Failed, 0, 0, 0);
        }
        finally
        {
            Sink.End();
            foreach (var item in items)
            {
                Com.Release(item);
            }
            if (destItem != 0) Com.Release(destItem);
            if (op != 0) Com.Release(op);
            DestroyWindow(owner);
            OleUninitialize();
        }
    }

    private static bool IsIn(string path, string dir) =>
        Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(path)) is { } parent && Files.SameDir(parent, dir);

    private static nint ShellItem(string path)
    {
        var iid = IID_IShellItem;
        nint item;
        var hr = SHCreateItemFromParsingName(path, 0, &iid, &item);
        if (hr < 0)
        {
            throw new COMException($"パスを解決できません: {path} (0x{hr:X8})", hr);
        }
        return item;
    }

    /// <summary>IShellItem のファイルシステム上のパス。取れなければ null。</summary>
    private static string? ItemPath(nint item)
    {
        if (item == 0)
        {
            return null;
        }
        char* name;
        // IShellItem::GetDisplayName (vtable 5)
        var hr = ((delegate* unmanaged[Stdcall]<nint, uint, char**, int>)Com.Vtbl(item)[5])(item, SIGDN_FILESYSPATH, &name);
        if (hr < 0)
        {
            return null;
        }
        try
        {
            return new string(name);
        }
        finally
        {
            CoTaskMemFree((nint)name);
        }
    }

    // ---- 進み具合の通知（IFileOperationProgressSink を自前の vtable で実装する。NativeAOT でも壊れない） ----

    private static class Sink
    {
        private static HashSet<string> s_sources = [];
        private static int s_succeeded, s_skipped, s_errors;

        /// <summary>進み具合の通知を受け取る COM のオブジェクト（IFileOperation::Advise に渡す）</summary>
        public static nint Pointer { get; private set; }
        public static (int Succeeded, int Skipped, int Errors) Counts => (s_succeeded, s_skipped, s_errors);

        public static void Begin(IEnumerable<string> sources)
        {
            s_sources = new HashSet<string>(sources.Select(Normalize), StringComparer.OrdinalIgnoreCase);
            s_succeeded = s_skipped = s_errors = 0;
            if (Pointer == 0)
            {
                // IUnknown (3) + IFileOperationProgressSink (16) = 19 個の関数
                var vtbl = (nint*)NativeMemory.Alloc(19, (nuint)sizeof(nint));
                vtbl[0] = (nint)(delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)&QueryInterface;
                vtbl[1] = (nint)(delegate* unmanaged[Stdcall]<nint, uint>)&AddRef;
                vtbl[2] = (nint)(delegate* unmanaged[Stdcall]<nint, uint>)&Release;
                vtbl[3] = (nint)(delegate* unmanaged[Stdcall]<nint, int>)&Ok;                                   // StartOperations
                vtbl[4] = (nint)(delegate* unmanaged[Stdcall]<nint, int, int>)&OkHr;                            // FinishOperations
                vtbl[5] = (nint)(delegate* unmanaged[Stdcall]<nint, uint, nint, char*, int>)&PreRename;         // PreRenameItem
                vtbl[6] = (nint)(delegate* unmanaged[Stdcall]<nint, uint, nint, char*, int, nint, int>)&PostRename; // PostRenameItem
                vtbl[7] = (nint)(delegate* unmanaged[Stdcall]<nint, uint, nint, nint, char*, int>)&PreTransfer;  // PreMoveItem
                vtbl[8] = (nint)(delegate* unmanaged[Stdcall]<nint, uint, nint, nint, char*, int, nint, int>)&PostTransfer; // PostMoveItem
                vtbl[9] = (nint)(delegate* unmanaged[Stdcall]<nint, uint, nint, nint, char*, int>)&PreTransfer;  // PreCopyItem
                vtbl[10] = (nint)(delegate* unmanaged[Stdcall]<nint, uint, nint, nint, char*, int, nint, int>)&PostTransfer; // PostCopyItem
                vtbl[11] = (nint)(delegate* unmanaged[Stdcall]<nint, uint, nint, int>)&PreDelete;               // PreDeleteItem
                vtbl[12] = (nint)(delegate* unmanaged[Stdcall]<nint, uint, nint, int, nint, int>)&PostDelete;   // PostDeleteItem
                vtbl[13] = (nint)(delegate* unmanaged[Stdcall]<nint, uint, nint, char*, int>)&PreRename;        // PreNewItem
                vtbl[14] = (nint)(delegate* unmanaged[Stdcall]<nint, uint, nint, char*, char*, uint, int, nint, int>)&PostNew; // PostNewItem
                vtbl[15] = (nint)(delegate* unmanaged[Stdcall]<nint, uint, uint, int>)&UpdateProgress;          // UpdateProgress
                vtbl[16] = (nint)(delegate* unmanaged[Stdcall]<nint, int>)&Ok;                                  // ResetTimer
                vtbl[17] = (nint)(delegate* unmanaged[Stdcall]<nint, int>)&Ok;                                  // PauseTimer
                vtbl[18] = (nint)(delegate* unmanaged[Stdcall]<nint, int>)&Ok;                                  // ResumeTimer
                // COM のオブジェクト = 先頭に vtable へのポインタを持つメモリ（プロセスの終了まで使い回す）
                var obj = (nint*)NativeMemory.Alloc(1, (nuint)sizeof(nint));
                *obj = (nint)vtbl;
                Pointer = (nint)obj;
            }
        }

        public static void End() => s_sources = [];

        private static string Normalize(string path) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

        /// <summary>コピー / 移動を終えた項目を数える。渡した項目（フォルダの中身ではなく）だけを数える。</summary>
        private static void Record(nint item, int hr, nint created)
        {
            var path = ItemPath(item);
            if (path is null || !s_sources.Contains(Normalize(path)))
            {
                return;
            }
            if (hr is E_USER_CANCELLED or HRESULT_ERROR_CANCELLED)
            {
                // 取り消されたものはどれにも数えない
            }
            else if (hr < 0)
            {
                s_errors++;
            }
            else if (hr == NOERROR || created != 0)
            {
                s_succeeded++;
            }
            else
            {
                // COPYENGINE_S_USER_IGNORED（同名ファイルのダイアログでスキップ）など、何もせずに成功扱いになったもの
                s_skipped++;
            }
        }

        private const int E_NOINTERFACE = unchecked((int)0x80004002);

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
        private static int QueryInterface(nint self, Guid* riid, nint* ppv)
        {
            if (*riid == IID_IUnknown || *riid == IID_IFileOperationProgressSink)
            {
                *ppv = self;
                return NOERROR;
            }
            *ppv = 0;
            return E_NOINTERFACE;
        }

        // プロセスの終了まで残すので、参照の数は数えない
        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
        private static uint AddRef(nint self) => 1;

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
        private static uint Release(nint self) => 1;

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
        private static int Ok(nint self) => NOERROR;

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
        private static int OkHr(nint self, int hr) => NOERROR;

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
        private static int PreRename(nint self, uint flags, nint item, char* name) => NOERROR;

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
        private static int PostRename(nint self, uint flags, nint item, char* name, int hr, nint created) => NOERROR;

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
        private static int PreTransfer(nint self, uint flags, nint item, nint destFolder, char* name) => NOERROR;

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
        private static int PostTransfer(nint self, uint flags, nint item, nint destFolder, char* name, int hr, nint created)
        {
            try
            {
                Record(item, hr, created);
            }
            catch (Exception e)
            {
                // 例外をネイティブ側へ投げると落ちるので、記録だけして続ける
                Log.Write($"fileop sink: {e}");
            }
            return NOERROR;
        }

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
        private static int PreDelete(nint self, uint flags, nint item) => NOERROR;

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
        private static int PostDelete(nint self, uint flags, nint item, int hr, nint created) => NOERROR;

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
        private static int PostNew(nint self, uint flags, nint folder, char* name, char* template, uint attrs, int hr, nint created) => NOERROR;

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
        private static int UpdateProgress(nint self, uint total, uint done) => NOERROR;
    }

    // ---- IFileOperation（vtable を直接呼ぶ） ----

    private static Guid CLSID_FileOperation => new("3AD05575-8857-4850-9277-11B85BDB8E09");
    private static Guid IID_IFileOperation => new("947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8");
    private static Guid IID_IShellItem => new("43826D1E-E718-42EE-BC55-A1E261C37BFE");
    private static Guid IID_IFileOperationProgressSink => new("04B0F1A7-9490-44BC-96E1-4296A31252E2");
    private static Guid IID_IUnknown => new("00000000-0000-0000-C000-000000000046");

    // IFileOperation: Advise (3), SetOperationFlags (5), SetOwnerWindow (9), MoveItem (14), CopyItem (16),
    // PerformOperations (21), GetAnyOperationsAborted (22)
    private static int FileOperation_Advise(nint p, nint sink, uint* cookie) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, uint*, int>)Com.Vtbl(p)[3])(p, sink, cookie);

    private static int FileOperation_SetOperationFlags(nint p, uint flags) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, int>)Com.Vtbl(p)[5])(p, flags);

    private static int FileOperation_SetOwnerWindow(nint p, nint hwnd) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, int>)Com.Vtbl(p)[9])(p, hwnd);

    private static int FileOperation_MoveItem(nint p, nint item, nint dest, char* newName, nint sink) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, nint, char*, nint, int>)Com.Vtbl(p)[14])(p, item, dest, newName, sink);

    private static int FileOperation_CopyItem(nint p, nint item, nint dest, char* newName, nint sink) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, nint, char*, nint, int>)Com.Vtbl(p)[16])(p, item, dest, newName, sink);

    private static int FileOperation_PerformOperations(nint p) =>
        ((delegate* unmanaged[Stdcall]<nint, int>)Com.Vtbl(p)[21])(p);

    private static int FileOperation_GetAnyOperationsAborted(nint p, int* aborted) =>
        ((delegate* unmanaged[Stdcall]<nint, int*, int>)Com.Vtbl(p)[22])(p, aborted);

    private const int NOERROR = 0;                                     // S_OK と同じ
    private const int E_USER_CANCELLED = unchecked((int)0x80270000);        // COPYENGINE_E_USER_CANCELLED
    private const int HRESULT_ERROR_CANCELLED = unchecked((int)0x800704C7); // HRESULT_FROM_WIN32(ERROR_CANCELLED)
    private const uint CLSCTX_ALL = 0x17;
    private const uint SIGDN_FILESYSPATH = 0x80058000;

    internal const uint FOF_SILENT = 0x4, FOF_RENAMEONCOLLISION = 0x8, FOF_NOCONFIRMATION = 0x10, FOF_ALLOWUNDO = 0x40,
        FOF_NOCONFIRMMKDIR = 0x200, FOF_NOERRORUI = 0x400, FOFX_KEEPNEWERFILE = 0x00400000, FOFX_ADDUNDORECORD = 0x20000000;

    [LibraryImport("ole32.dll")]
    private static partial int CoCreateInstance(Guid* clsid, nint outer, uint context, Guid* iid, nint* ppv);

    [LibraryImport("shell32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int SHCreateItemFromParsingName(string path, nint bindCtx, Guid* riid, nint* ppv);
}
