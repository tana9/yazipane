# yazipane

WezTerm 上で [yazi](https://github.com/sxyazi/yazi) を左右 2 画面に並べて起動する、Windows 用のランチャー（非公式）。

## 必要なもの

- [WezTerm](https://wezterm.org/)（`wezterm-gui.exe` が PATH 上にあること）
- [yazi](https://yazi-rs.github.io/)（`yazi.exe` が PATH 上にあること）

動作を確認した組み合わせは Windows 上の yazi `26.9.1` と WezTerm `20240203-110809-5046fc22`。ほかの版では yazi の内部 UI や WezTerm の動作が異なる場合がある。

## ビルド

.NET SDK 11 と、NativeAOT 用に Visual Studio Build Tools の C++ ワークロードが必要。

```powershell
winget install Microsoft.VisualStudio.BuildTools --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
dotnet publish Yazipane -c Release -o publish
```

テストは `task test`。C# の単体テスト（`dotnet test yazipane.slnx`）に加えて、yazi のプラグインのテスト
（`Yazipane.Tests/lua/plugin_test.lua`。yazi の API を偽物に差し替えて操作ごとの動きを確かめる。`lua` が必要: `scoop install lua`）も実行する。

GitHub Actions の CI は push とプルリクエストで Windows 上の C# / Lua テスト、書式・静的チェック、NativeAOT ビルドを実行する。WezTerm を開くスモークテストと手動操作の確認は含まない。

```
yazipane.slnx
├─ Yazipane/               アプリ（Yazipane.csproj、app.manifest、assets/ = exe に埋め込む WezTerm / yazi の設定とプラグイン、
│                          icon/ = アイコン（tools/make-icon.ps1 で生成））
├─ Yazipane.Tests/         単体テスト（xUnit）
└─ tools/                  開発用スクリプト（Taskfile から呼ぶ）
```

[Task](https://taskfile.dev)（`scoop install task`）を使う場合:

| コマンド | 内容 |
|---|---|
| `task restart [-- 左 右]` | 起動中の yazipane を終了 → ビルド → 起動（開発中はこれ） |
| `task build` | ビルド（変更が無ければ省略） |
| `task test` | 単体テスト |
| `task coverage` | C# の単体テストのカバレッジ（ファイルごとの行カバレッジ） |
| `task coverage-all` | 単体テストとスモークテストのカバレッジを合算する（スモークテストは Debug のビルドで動かし、dotnet-coverage で子プロセスも含めて測る。WezTerm のウィンドウが開く） |
| `task ui-smoke` | 実際のキー入力でコピー・移動・クリップボード・メニュー操作を試す（ウィンドウが前面になり、クリップボードを一時的に使う） |
| `task lint` | 書式と静的チェック（C# が `.editorconfig` のとおりか、Lua を lua-language-server と yazi / WezTerm の型定義で。`scoop install lua-language-server` が必要） |
| `task smoke` | テスト専用の状態フォルダで起動し、ペイン間の連携などを `ya emit-to` で確かめる（WezTerm のウィンドウが開く） |
| `task run [-- 左 右]` / `task debug` | 起動 / `--debug` 付きで起動 |
| `task log` | `--debug` 時のログを表示 |
| `task stop` | 起動中の yazipane を終了（普段使いの WezTerm / yazi には触れない） |
| `task icon` / `task clean` | アイコンの再生成 / ビルド成果物の削除 |

yazipane.exe は WezTerm の終了まで待機するため、起動中は exe を上書きできない。ビルドし直すときは `task restart` を使う。

`publish\yazipane.exe`（NativeAOT のネイティブ exe 1 つ、約 3MB）ができる。.NET ランタイムのインストールは不要。
右クリックのたびに起動されるため、起動の速い NativeAOT にしている。

## 使い方

```powershell
yazipane                 # 前回終了時のフォルダを開く（初回はカレントディレクトリ、ダブルクリック時はホーム）
yazipane .               # 両ペインともカレントディレクトリ
yazipane C:\work         # 両ペインとも C:\work
yazipane C:\src D:\dst   # 左 C:\src / 右 D:\dst
yazipane --debug ...     # %LOCALAPPDATA%\yazipane\logs に起動ごとのログを書き、yazi のログも有効にする
yazipane --reuse ...     # yazipane が起動中なら、新しいウィンドウを開かずにそのウィンドウで開く（フォルダの指定が無ければ前面に出すだけ）
yazipane --register      # エクスプローラーの右クリックメニューに「yazipane で開く」を追加する
yazipane --unregister    # 上で追加したメニューを消す
```

ウィンドウの位置・大きさ（最大化しているかどうかも）は終了時の状態を覚えておき、次回の起動時に戻す（初回は最大化）。
複数起動している場合は、最後に動かしたウィンドウの状態が残る。

`--reuse` は、起動中のウィンドウが複数あるときは最後に起動したものを使う。`ya.exe` が見つからないときは、フォルダを指定しても新しく起動する。

`--register` は現在のユーザーだけに登録する（管理者権限は不要）。フォルダ・フォルダの背景・ドライブの右クリックメニューに出る
（Windows 11 では「その他のオプションを確認」の中）。登録されるのは実行した exe の場所なので、exe を移動したら登録し直す。

`task log` は最新のデバッグ起動のログを表示する。ログは起動ごとのフォルダ内でプロセスとペイン別に保存される。
ログのフォルダは新しいもの 20 回分だけを残し、それより古いものは `--debug` で起動したときに消す。
ログにはユーザー名を含むパスや操作したファイル名が記録されるため、共有する前に内容を確認する。

普段の `yazi.toml` / `keymap.toml` が読めない場合は、yazipane の設定だけで起動し、左ペインに警告を表示する。

## ショートカット

### ペインの操作（WezTerm）

| キー | 動作 |
|---|---|
| `Ctrl+Tab` | 次のペインへ移動 |
| `Ctrl+Shift+Tab` | 前のペインへ移動 |
| `Ctrl+Shift+Z` | 1 画面（今のペインを最大化）/ 2 画面を切り替える（WezTerm の既定のキー） |
| `Ctrl+Shift+Alt+←` / `→` | ペインの境目を左右に動かす（WezTerm の既定のキー） |
| `Ctrl+Shift+E` | 左右のペインを同じ幅に戻す |

- マウスでペインをクリックしても切り替えられる。非アクティブなペインは暗く表示され、アクティブなペインのステータスバーに `▶` が付く（目印には `ya.exe` が必要）。
- ウィンドウタイトルに左右のフォルダ名（1 画面のときは `[1画面]` と表示中のフォルダ名）が出る。
- 1 画面のときは yazi が普段の 3 列表示（普段の `yazi.toml` の `ratio`）になり、2 画面に戻すと 2 画面用の表示に戻る。
- 1 画面のときに `Ctrl+Tab` を押すと 2 画面に戻ってからペインを移動する。
- yazi からエディタなど（普段の `yazi.toml` の opener で `block = true` のもの。nvim など）を開くと、開いている間だけそのペインが 1 画面になり、閉じると 2 画面に戻る。
  - 開く前から自分で 1 画面にしていた場合と、開いている途中で自分で 2 画面に戻した場合は、閉じてもそのまま。
  - 画像や PDF など別のアプリで開くもの（`orphan = true`）では切り替わらない。
- yazipane のウィンドウでは、普段の WezTerm 設定を書き換えても自動では読み直さない（`Ctrl+Shift+R` で読み直せる）。
- `Ctrl+Tab` / `Ctrl+Shift+Tab` / `Ctrl+Shift+E` は WezTerm が処理するため、ペイン内で開いたエディタでもペイン操作になる。
- 1 画面のときも反対ペインは裏で動いているので、F5 / F6 で見えていない反対ペインへコピー / 移動できる。

### 2 画面の連携（yazipane プラグイン）

| キー | 動作 |
|---|---|
| `q` | 両方のペインを終了する（片方だけ残らないように） |
| `F5` | 選択ファイル（選択がなければカーソル位置）を反対ペインへコピー（件数とコピー先を確認してから） |
| `F6` | 同じく反対ペインへ移動 |
| `=` | 反対ペインを、こちらと同じフォルダで開く |
| `Alt+O` | こちらを、反対ペインと同じフォルダにする |
| `Alt+S` | 左右のフォルダを入れ替える |
| `Alt+I` | カーソル位置のフォルダを反対ペインで開く |
| `Alt+N` | 同じ左右のフォルダで新しいウィンドウを開く |
| `Alt+B` | 左右のフォルダの組に名前を付けて保存 / 復元 / 削除する（最大 36 件） |
| `Alt+D` | ドライブの一覧を表示し、英字キーまたは `↑` / `↓` と `Enter` で選んで移動する |
| `Alt+E` | 今のフォルダをエクスプローラーで開く（カーソル位置の項目を選択した状態で。yazi の既定の opener の reveal と同じ `explorer /select,…`） |
| `!` | 今のフォルダで Windows Terminal を開く（yazi の shell で `wt -d .` を実行する。Windows Terminal が必要）。新しいウィンドウにするか、開いているウィンドウのタブにするかは Windows Terminal の設定（スタートアップ →「新しいインスタンスの動作」）に従う |
| `Ctrl+C` | 選択ファイル（選択がなければカーソル位置）をクリップボードにコピー（エクスプローラーや Teams などで `Ctrl+V`） |
| `Alt+X` | 選択ファイルをクリップボードに切り取り（エクスプローラーなどで貼り付けると移動） |
| `Ctrl+V` | エクスプローラーなどでコピー / 切り取りしたファイルを今のフォルダに貼り付け |
| ドラッグ | ファイルをほかのアプリへドラッグ&ドロップ（試作。コピーかショートカットの作成のみで、移動はしない） |
| `Alt+L` | 列の表示を「2 画面用（親フォルダ列なし）」/「yazi 本来の 3 列」で切り替え（このペインのみ） |
| `Alt+P` | プレビュー列（各ペインの右の列）の表示 / 非表示を切り替え（両ペイン同時） |
| `Alt+C` | 左右の違いを一覧表示する。`S` でこちらにしかない項目・こちらの方が新しいファイルを選択できる |
| `Alt+H` | yazipane のキーの一覧を表示する（WezTerm 側のキーも含む。yazi のキーは `F1`） |
| 右クリック / `Shift+F10` | Windows の右クリックメニュー（先頭に「反対ペインへコピー / 移動」「パスをコピー」） |

- `Alt+B` では `s` で保存、`o` で復元、`d` で削除を選ぶ。保存先は `%LOCALAPPDATA%\yazipane\pairs`。復元時は両方のフォルダが存在するか確かめる。
- `Alt+C` の一覧は `↑` / `↓` と `PageUp` / `PageDown` でスクロールし、`Esc` または `Enter` で閉じる。`S` を押すと表示中のこちら側の「こちらのみ」「こちらが新しい」を選び、`F5` でコピーできる。隠しファイルを含む直下を比較する。ファイルは名前・種類・更新日時・サイズを比べ、フォルダは名前と種類（存在するか）だけを比べる。ファイルの内容やサブフォルダの中は比較しない。選択の対象は現在の一覧に表示されている項目だけ。
- 右クリックとドラッグは、現在のフォルダの列（中央の列）だけが対象。親フォルダ / プレビューの列は yazi の既定の動作のまま。
- ドラッグは、ファイルの行の上でボタンを押して始めたときだけ。
- 右クリックした項目が選択に含まれていれば選択全体、含まれていなければ選択を解除してその項目だけが対象になる（エクスプローラーと同じ）。
- メニューの「名前の変更」はエクスプローラーの外では動かないため、yazi の名前変更（`r` と同じ）になる。
- `Shift+F10` のときは、メニューはマウスカーソルの位置に表示される。
- Windows のメニューは 1 つのフォルダの中身にしか出せないため、別のフォルダにある選択項目は対象外になる（件数を通知する）。
- 1 画面のときの `Alt+P` は表示中のペインだけを切り替える。

- F5 / F6 と `Ctrl+V` は、エクスプローラーと同じ Windows のファイル操作で行う。
  - 同名のファイルがあるときは、エクスプローラーと同じダイアログで置き換え / スキップを選べる。進捗もエクスプローラーのダイアログに出る（yazi のタスク一覧には出ない）。
  - エクスプローラーの「元に戻す」（エクスプローラー上で `Ctrl+Z`）で取り消せる。
  - `y` / `x` でヤンクした内容には影響しない。
  - 確認なしでコピー / 移動したい場合は、普段の `keymap.toml` で `plugin yazipane copy-now` / `plugin yazipane move-now` を割り当てる。
  - 右クリックメニューの「反対ペインへコピー / 移動」は確認を出さない。
- 両ペインが同じフォルダのときは、コピー / 移動せずに警告を出す。
- ステータスバーの右側に、今のドライブの空き容量を表示する（ネットワークパス `\\server\share` では表示しない）。
- `Ctrl+V` で切り取ったファイルをすべて移動できた後はクリップボードを空にする。スキップや失敗がある場合や、移動中に内容が変わった場合は残す。同じフォルダへコピーを貼り付けると「- コピー」の付いた名前で複製する。
- `y` / `x` でヤンクした内容は反対ペインにも引き継がれるので、左で `y` → 右で `p` のようにも使える（yazi 組み込みの `session` プラグインの `sync_yanked`）。

### よく使う yazi の基本操作（既定のキー）

| キー | 動作 |
|---|---|
| `j` / `k`、`↓` / `↑` | カーソルを上下に移動 |
| `h` / `l`、`←` / `→` | 親フォルダへ戻る / フォルダに入る |
| `Enter` | 開く |
| `Space` | 選択を切り替え |
| `Ctrl+A` | すべて選択 |
| `v` | 範囲選択モード |
| `y` / `x` / `p` | コピー / 切り取り / 貼り付け（同じペイン内） |
| `d` / `D` | ごみ箱へ移動 / 完全に削除 |
| `a` | ファイルを作成（名前の最後に `\` を付けるとフォルダ） |
| `r` | 名前を変更 |
| `/` | 今のフォルダ内を検索 |
| `f` | 今のフォルダ内の表示を絞り込む |
| `s` / `S` | ファイル名 / 内容を検索（それぞれ `fd` / `ripgrep` が必要） |
| `c` → `c` | カーソル位置のパスをコピー |
| `,` → `m` / `M` | 更新日時順 / 逆順に並べ替え |
| `.` | 隠しファイルの表示を切り替え |
| `F1` または `~` | ヘルプ（yazi のキーの一覧） |
| `q` | 終了（yazipane では両方のペインを終了する） |

普段の `keymap.toml` に書いたキーもそのまま使える（yazipane のキーと重なった場合は yazipane が優先）。
`Ctrl+C` は yazi の既定の「タブを閉じる」を置き換える。タブを閉じるには `Ctrl+C` 以外のキーを普段の `keymap.toml` で `close` に割り当てる。
WezTerm 側のキー（`Ctrl+Tab` など）は yazi のヘルプには表示されない（`Alt+H` で確認できる）。

### 操作例

- 左から右にコピー: 左でファイルを `Space` で選び、`F5` → コピー先を確認して決定する。
- エクスプローラーのファイルを貼り付け: エクスプローラーでコピーし、移動先のペインで `Ctrl+V` を押す。
- 左右の場所を保存: 両ペインを目的のフォルダに移動し、`Alt+B` → `s` → 名前を入力する。復元は `Alt+B` → `o`。
- 違いを確認: `Alt+C` で一覧を開き、`S` でこちら側の候補を選択してから `F5` でコピーする。

### yazi / WezTerm の更新後

バージョンを `yazi --version` と `wezterm --version` で確認し、`task test`、`task lint`、`task smoke` を実行する。実画面では `Alt+D`、`Alt+C`、右クリック、ペインの切り替えも確認する。`task smoke` は `%LOCALAPPDATA%\yazipane\smoke` の一時フォルダを使い、普段の yazipane の位置・デバッグログ・保存したフォルダの組には触れない。yazi 本体のログは通常の保存先を使う。

右クリック、ドラッグ、Windows の確認ダイアログやクリップボードは [実機での確認](MANUAL_TEST.md) の手順で一時ファイルを使って試せる。

`task ui-smoke` はロックされていない Windows デスクトップで実行する。テスト中はウィンドウが前面になり、キー入力とクリップボードを使うため、他の操作を控える。クリップボードは終了時に復元を試みるが、アプリ独自の形式などは復元できない場合がある。テストは一時ファイルを使い、F5 のキャンセルとコピー、F6 の移動、Ctrl+C、Shift+F10 によるメニュー処理の起動と Esc による終了を確認する。ドラッグやマウスの右クリック、Windows の同名ファイル確認ダイアログは対象外。

## アイコン

`Yazipane/icon/yazipane.ico` は `pwsh tools/make-icon.ps1`（`task icon`）で生成する（ターミナルのプロンプトとフォルダ。配色は tokyonight 系）。

- exe のアイコンとして埋め込む（`ApplicationIcon`）。
- 起動した WezTerm のウィンドウにも同じアイコンを設定し（`WM_SETICON`）、ウィンドウ単位の AppUserModelID で
  タスクバー上は普段の WezTerm と別のグループにする（ピン留めすると yazipane.exe が起動される）。
- アイコンは読み込んだプロセスが持ち主なので、yazipane.exe は WezTerm が終了するまで裏で待機する。

## 仕組み

- `Yazipane/assets/` 以下を exe に埋め込みリソースとして持ち、起動時に `%LOCALAPPDATA%\yazipane\` へ書き出す。
- ソースは `Yazipane/` 以下:
  - `Program.cs`: 引数の振り分け（yazi のプラグインから呼ばれるサブコマンドか、ランチャーか）
  - `Launch/`: ランチャー（`Launcher.cs` 起動処理、`YaziConfig.cs` 設定の合成、`WindowIcon.cs` / `WindowPlacement.cs` ウィンドウのアイコンと位置、`Instances.cs` `--reuse` 用の記録）
  - `Commands/`: プラグインから呼ばれるサブコマンド（右クリックメニュー、クリップボード、ドラッグ、コピー / 移動、ドライブ、フォルダの組、エクスプローラー）
  - `Interop/`: Win32 / COM の共通部品（`Native.cs`、`Com.cs`、`ShellItems.cs`、`OwnerWindow.cs`）
  - `Common/`: 補助（`Files.cs`、`Assets.cs`、`Log.cs`）
- WezTerm を `--config-file` 付きの新しいプロセスとして起動し、2 つの yazi を別々の `--client-id` で起動する。
- WezTerm の設定は、普段の設定（`WEZTERM_CONFIG_FILE`、`~/.config/wezterm/wezterm.lua`、`~/.wezterm.lua` の順に探す）を読み込んだうえで、
  yazipane に必要なもの（タブバー、スクロールバー、終了時の動作、`Ctrl+Tab` / `Ctrl+Shift+Tab` / `Ctrl+Shift+E`）を上書きする。
  yazi の入力欄で記号を入力できない場合があるため、`enable_kitty_keyboard` は無効にする。
  `Ctrl+Shift+Z`（1 画面 / 2 画面）などは WezTerm の既定のキーをそのまま使う。フォントや配色は普段のものが使われる。
  - 注意: 普段の設定で `wezterm.on('gui-startup', ...)` などのイベント処理を書いていると、yazipane の処理と一緒に動く
    （起動時にウィンドウを開く処理があると、yazipane のウィンドウとは別にもう 1 つ開く）。
    また、普段の設定を読み込む分だけ起動が 1〜2 秒遅くなる。
- yazi の設定は、起動のたびに普段の設定（`YAZI_CONFIG_HOME`、未設定なら `%APPDATA%\yazi\config`）を土台にして
  `%LOCALAPPDATA%\yazipane\yazi` に組み立て直し、`YAZI_CONFIG_HOME` でそちらを使わせる。普段の設定ファイル自体は変更しない。
  - `plugins/` `flavors/` `vfs.toml` `package.toml`: そのままコピー（プラグインには yazipane 用のものを追加）
  - `init.lua`: yazipane の初期化の後ろに普段の `init.lua` を連結
  - `yazi.toml` `keymap.toml` `theme.toml`: `Yazipane/assets/yazi/` の内容を TOML として重ねる。キー一覧は狭いペインでも読みやすいよう 1 列にする。
    （テーブルは再帰マージ、`prepend_*` は先頭に連結、`append_*` は末尾に連結、それ以外は上書き）
  - WezTerm (Windows) は起動時にレジストリのユーザー環境変数で自身の環境を上書きするため、
    ランチャーからは `YAZIPANE_CONFIG_HOME` という別名で渡し、`wezterm.lua` で詰め替えている。
- 2 つの yazi はプラグイン `yazipane.yazi` が DDS（`ps.pub_to` / `ps.sub_remote`）で互いのカレントディレクトリを通知し合う。
  候補一覧は `yazipane-picker.yazi`、フォルダの組の操作は `yazipane-pairs.yazi`、比較一覧は `yazipane-report.yazi` に分ける。
  反対ペインへのコピー/移動は、相手のディレクトリを問い合わせてから `yazipane.exe --transfer` が
  Windows のファイル操作（`IFileOperation`）で行う。相手から応答がなければ操作を中止する。`Ctrl+V` の貼り付け（`--paste`）も同じ。
  項目ごとの結果を受け取り、「2 件をコピーしました（1 件はスキップ）」のように通知する。
  - 260 文字を超えるパスを含むフォルダは、エクスプローラーと同じく途中で中止になる。

## ライセンス

[MIT License](LICENSE)。yazipane.exe に組み込まれているソフトウェアのライセンスは [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) を参照。
