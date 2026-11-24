# AGENTS.md

yazipane のコードを変更するエージェント向けの注意点。プロジェクトの目的・使い方・仕組みは README.md を参照（ここには README に無い制約だけを書く）。
今後の改善候補は TODO.md にある。

## ビルド・テスト

- 起動中の yazipane は WezTerm の終了まで exe をロックしているので、`task build` / `dotnet publish -o publish` は失敗することがある。
  - 動作確認込みなら `task restart`（終了 → ビルド → 起動）。
  - ビルドが通るかだけ確かめるなら、別の出力先へ: `dotnet publish Yazipane -c Release -o <一時フォルダ>`。NativeAOT の警告もここで確認する。
- 単体テストは `task test`（`tools/test.ps1`。C# の xUnit と、プラグインの Lua テストを実行する）。
- C# のテストは本体と同じフォルダ構成（`Yazipane.Tests/Commands` / `Common` / `Interop` / `Launch`）で、対象のクラスごとに `<クラス名>Tests` の 1 ファイル。
  - 環境変数・PATH・ホームフォルダを読む処理は、それらを引数で受け取る internal の形（`FindExe(name, path)` など）を作ってテストする。
  - 一時フォルダは `Support/TempDir`、シェルの COM（IFileOperation など）は `Support/Sta.Run` で STA のスレッドから使う。
  - クリップボードや環境変数など、プロセス全体で共有されるものはテストで書き換えない（テストは並列に動く）。
  - テストしたい private のメソッドは internal にする（`InternalsVisibleTo` でテストから見える）。
  - カバレッジは `task coverage`（単体テストだけ。coverlet）と `task coverage-all`（スモークテストも。`tools/coverage.ps1 -Smoke`）。
    スモークテストは NativeAOT の exe では測れないので、Debug のビルドの exe（`smoke.ps1 -Exe`）を dotnet-coverage（`dotnet-tools.json`）で
    動かし、WezTerm → yazi → yazipane.exe と起動された子プロセスも含めて測る。右クリックメニューやドラッグなど、どちらでも動かないものは対象外。
- `wezterm.lua` は `Yazipane.Tests/lua/wezterm_test.lua` で、WezTerm の API を偽物に差し替えてイベント（gui-startup / update-status など）やキーの処理を確かめる。
- Lua のテストの枠組み（`test` / `eq` / `finish`）は `Yazipane.Tests/lua/testing.lua`。
- `main.lua` は `Yazipane.Tests/lua/plugin_test.lua` で、yazi の API を偽物に差し替えて操作ごとの動き（呼ぶサブコマンド・emit・通知）を確かめる。操作を足したり変えたりしたらテストも足す。
  - キーを足したら、HELP と keymap.toml がそろっているかのテストのため、テスト内の `names` にもキーの表記を足す。
- yazi 本体での表示・動作と、`init.lua` / `wezterm.lua` は単体テストできない。変更したら `task smoke` で確かめる。
- Lua や C# を変更したら `task lint` も通す。
  - Lua は lua-language-server で、yazi / WezTerm の型定義（`tools/lua-check.ps1` でコミットを固定して `.cache/` に取得）を使い、未定義の変数や存在しない API を調べる。
  - yazi の型定義に無い UI の部品（`Status`、`Current` など）は、スクリプトの `$yaziGlobals` に足す。
  - C# の書式は `.editorconfig`（dotnet/runtime のもの。var は許可）に従う。直すときは `dotnet format yazipane.slnx`。
    提案レベルの項目も 0 件に保つ（確認: `dotnet format style yazipane.slnx --severity info --verify-no-changes`）。
  - 名前の付け方: static フィールドは `s_camelCase`、インスタンスのフィールドは `_camelCase`。
    Win32 の識別子（`IID_...` の GUID など）は名前を変えず、static readonly フィールドではなくプロパティにする。
  - 名前空間はフォルダごと（`Yazipane.Commands` / `.Common` / `.Interop` / `.Launch`）。csproj でプロジェクト全体に using している。
  - smoke は WezTerm のウィンドウを実際に開き、普段の `%LOCALAPPDATA%\yazipane` を使う（ユーザーに確認してから実行する）。
  - 右クリックメニュー・ドラッグ・キー操作そのものは smoke の対象外。変更したらユーザーに手動確認を頼む。
  - 手動確認を頼む前に、自分で `task restart` して変更後の版を起動しておく（ユーザーに再起動を任せない）。
- exe のサブコマンド（`--transfer` など）は、Debug ビルドの `Yazipane/bin/Debug/net11.0-windows/win-x64/yazipane.exe` を一時フォルダの小さなファイルに対して直接呼んで確かめられる。

## NativeAOT の制約

- リフレクションに頼るコードを書かない（トリミングで壊れる）。
- TOML は Tomlyn のソース生成（`TomlContext` / `TomlWriteContext`）経由で読み書きする。
- COM は vtable を直接呼ぶ（`Com` クラス: `Vtbl` / `QueryInterface` / `Release` / `Check`）。`[ComImport]` や組み込みの COM 相互運用は使わない。
- P/Invoke は `LibraryImport`。複数のクラスで使う Win32 API・構造体（`POINT` / `RECT`）は `Interop/Native.cs` に置き、クラス固有のものだけ各クラスに置く。
- ダイアログやメニューの持ち主になる見えないウィンドウは `OwnerWindow`（前面化・中央寄せも）を使う。
- 起動速度（約 0.15 秒）が重要。右クリックのたびに exe が起動されるため、起動時に重いライブラリ（DI、ロギング基盤など）を足さない。

## 方針: yazi / WezTerm でできることはそちらに任せる

- 機能を足す前に、yazi（既定のキー・コマンド・opener・組み込みのプラグイン）と WezTerm（既定のキー・アクション・設定項目）で
  できないかを確かめる（`wezterm -n show-keys` で WezTerm の既定のキー、yazi の既定の設定は yazi リポジトリの
  `yazi-config/preset/*.toml`）。できるなら、yazipane はキーを割り当てるか呼び出すだけにする。
  - 例: Enter で開く（yazi の opener）、y / p の共有（yazi の session プラグイン）、Alt+E（yazi の shell で reveal と同じコマンド）、
    Ctrl+Shift+Z の 1 画面（WezTerm の TogglePaneZoomState）、幅の調整（WezTerm 既定の Ctrl+Shift+Alt+矢印）。
- 自前で作るのは、どちらにも無いもの（Windows のシェルとの連携、2 つのペインの連携、ウィンドウのアイコンなど）だけ。
- 例外: F5 / F6 は yazi の yank / paste を使わず IFileOperation で行う（yank の内容を消さないため。yazi にはヤンクを元に戻す API が無い）。
- yazi / WezTerm に任せた結果、yazipane の状態（1 画面 / 2 画面など）と食い違う場合は、キーを横取りせず、変化を見つけて合わせる（`wezterm.lua` の定期的な確認）。

## 守ること

- ユーザーの普段の yazi / WezTerm 設定には書き込まない。生成先は `%LOCALAPPDATA%\yazipane` 以下だけ。
- `assets/` は exe にそのまま埋め込まれる。改行は LF（`.gitattributes`）。
- `--context-menu` / `--clipboard` / `--drag` / `--transfer` / `--paste` / `--drives` / `--free` は yazi のプラグインから呼ばれ、標準出力（UTF-8）で結果を返す（`Program.s_pluginCommands` に一覧があり、実装は `Commands/`）。新しいサブコマンドは `s_pluginCommands` に 1 行足す。出力の形式や終了コードを変えるときは `main.lua` 側も合わせる。エラーは stderr にメッセージだけを書き、終了コードで知らせる。
- ファイルのコピー / 移動（F5 / F6 / Ctrl+V）は yazi の yank / paste ではなく `FileOps`（IFileOperation）で行う。ユーザーの yank の内容に触れないため。
  - 件数は進み具合の通知（`IFileOperationProgressSink`。`FileOps.Sink` で vtable を自前で組み立てている）で、渡した項目ごとに「できた / スキップ / 失敗」を数える。
  - IFileOperation は STA のスレッドでしか動かない。テスト（`FileOpsTests`）は STA のスレッドを作り、ダイアログを出さないフラグ（`FOF_SILENT` など）を付けて実行する。
- 新しいキーを足したら、`keymap.toml`、README のショートカット表、`main.lua` の `HELP`（Alt+H の一覧）の 3 か所を更新する。
- ログは `--debug` のときだけ（`Log`）。ログの失敗でアプリ本体の操作を失敗させない。

## はまりどころ

- WezTerm (Windows) は起動時にレジストリのユーザー環境変数で自身の環境を上書きする。WezTerm 経由で yazi に渡す環境変数は `YAZIPANE_*` の別名で渡し、`wezterm.lua` の `pane_env` で詰め替える（新しい変数を足すときは `Launcher.SetEnvironment` と `pane_env` の両方に足す）。
- `wezterm.lua` の定期的な確認（1 画面 / 2 画面の検知、エディタを開いている間の自動 1 画面）について:
  - タブバーを隠しているので `update-status` は定期的には呼ばれない。`update-status` の中から `wezterm.time.call_after` のタイマーを始めて回している（`gui-startup` の中で始めたタイマーは動かなかった）。
  - 設定の Lua が作り直されるとタイマーも止まる。`automatically_reload_config = false` は、同じフォルダの `last-*.txt` などが cd のたびに書き換わって再読み込みが何度も起き、タイマーが止まるのを防ぐため。外さない。
  - 状態は `wezterm.GLOBAL` に置き、中身を書き換えずに毎回新しい表を入れ直す。
  - Windows の WezTerm は終了したプロセスを前面として報告し続けることがあるので、`wezterm.procinfo.get_info_for_pid` で生きているかも確かめる。yazi が一瞬だけ起動するもの（`file.exe`、`git.exe` など）は `BACKGROUND` に入れて数えない。
  - `--debug` のときは `wezterm.log`（`task log` で見られる）に前面のプロセスの変化を書く。
- プラグインから反対ペインへの送信は `main.lua` の `pub()` を使う（相手が未接続・終了済みでもエラーにしない）。`ps.pub_to` を直接呼ばない。
- `init.lua` は yazi の内部フィールド（`Current` の `_area` / `_folder.window`）に依存している。読めない場合は yazi の既定の動作に戻す作りを保つ。
- Shell の UI オブジェクト（右クリックメニュー / IDataObject）は 1 つのフォルダの中身にしか作れない（`ShellItems`）。
- yazi のテーマ `th` の各部（`th.which`、`th.pick` など）は Lua の table ではなく userdata のことがある。`type(...) == "table"` で判定せず、
  `pcall` で項目を読み、読めなければ色なし（`ui.Style()`）にする（例: `yazipane-picker` の `theme()`）。
- 描画（`ya.sync` の中や部品の `redraw`）で別のプラグインを `require` しない。yazi では失敗し、`yazipane-report` が一覧を出せずに
  代わりの確認の画面になった（偽物の yazi を使うテストでは通ってしまう）。共通にしたい描画の関数は、各プラグインに同じものを置く。
- 独自の一覧などの画面は、自前の色を決めずにテーマの対応する項目（選択の一覧なら `[pick]`、キー候補なら `[which]`）を使う。

## コーディング方針

- コメント、ユーザー向けのメッセージ、README は日本語。
- テストは xUnit、メソッド名は日本語（例: `内容が同じなら書き換えない`）。
- 例外は想定するものだけを `catch (...) when (e is ...)` で捕まえる。ユーザーにそのまま見せるエラーは `UserFacingException`。
- 挙動を変えたら README の該当箇所（ショートカット表、仕組み）も更新する。
