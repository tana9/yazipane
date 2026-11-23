# yazipane の連携機能のスモークテスト。
# 一時フォルダで yazipane を起動し、ya emit-to で操作して、ファイル / ウィンドウタイトル / プラグインのログで結果を確かめる。
#   task smoke（publish/yazipane.exe を最新にしてから実行する）
# - yazipane の設定・状態・ログはテスト専用フォルダに生成し、最後に片付ける。yazi 本体のログは通常の保存先を使う。
# - マウス / キー操作が必要なもの（右クリックメニュー、ドラッグ、Ctrl+Shift+Z のキー自体）は対象外。

#   -Exe: 試す yazipane.exe（既定は publish/yazipane.exe。カバレッジを測るときは Debug のビルドを渡す: tools/coverage-smoke.ps1）
param([string]$Exe)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$exe = if ($Exe) { (Resolve-Path $Exe).Path } else { Join-Path $root 'publish/yazipane.exe' }
$testSession = [guid]::NewGuid().ToString('N')
$state = Join-Path $env:LOCALAPPDATA "yazipane/smoke/$testSession"
$oldTestSession = $env:YAZIPANE_TEST_SESSION
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("yazipane-smoke-" + [guid]::NewGuid().ToString('N'))
$L = Join-Path $work 'left'
$R = Join-Path $work 'right'
$pairName = 'smoke-' + [guid]::NewGuid().ToString('N')
$pairKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($pairName))) + '.txt'
$pairFile = Join-Path $state "pairs/$pairKey"

if (-not (Test-Path $exe)) { throw "$exe がありません。先に task build を実行してください。" }
if (-not (Get-Command ya -ErrorAction SilentlyContinue)) { throw 'ya.exe が見つかりません。' }

$results = [System.Collections.Generic.List[object]]::new()

# 条件が満たされるまで最大 $timeout 秒待って判定する
function Test-Step([string]$name, [scriptblock]$condition, [double]$timeout = 5) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $condition) {
            $results.Add([pscustomobject]@{ Test = $name; Result = 'OK' })
            return
        }
        Start-Sleep -Milliseconds 200
    } while ($sw.Elapsed.TotalSeconds -lt $timeout)
    $results.Add([pscustomobject]@{ Test = $name; Result = 'NG' })
}

function Send-Emit([uint64]$id, [string[]]$action) {
    & ya emit-to $id @action
    if ($LASTEXITCODE -ne 0) { throw "ya emit-to $id $action に失敗しました" }
}

# ---- 準備 ----
New-Item -ItemType Directory -Force $L, $R, (Join-Path $L 'sub') | Out-Null
'a', 'b', 'c', 'd' | ForEach-Object { Set-Content (Join-Path $L "$_.txt") $_ }

try {
    $env:YAZIPANE_TEST_SESSION = $testSession
    $launcher = Start-Process -FilePath $exe -ArgumentList '--debug', "`"$L`"", "`"$R`"" -PassThru

    # yazi が 2 つ起動するまで待つ（普段の WezTerm 設定の読み込みで数秒かかる）
    $yazis = @()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($yazis.Count -lt 2 -and $sw.Elapsed.TotalSeconds -lt 30) {
        Start-Sleep -Milliseconds 500
        $yazis = @(Get-CimInstance Win32_Process -Filter "Name='yazi.exe'" |
            Where-Object { $_.CommandLine -like "*$work*" -and $_.CommandLine -match '--client-id (\d+)' })
    }
    if ($yazis.Count -lt 2) { throw 'yazi が起動しませんでした' }

    $idOf = { param($dir) [uint64](($yazis | Where-Object { $_.CommandLine -like "*$dir*" }).CommandLine -replace '.*--client-id (\d+).*', '$1') }
    $left = & $idOf $L
    $right = & $idOf $R
    $wez = ($yazis | Select-Object -First 1).ParentProcessId
    $title = { (Get-Process -Id $wez -ErrorAction SilentlyContinue).MainWindowTitle }
    Start-Sleep 2   # プラグインの初期化と、ペイン同士の接続を待つ

    # 起動直後は yazi がタイトルを設定するまで時間がかかることがある（マシンが重いときや、カバレッジを測る Debug のビルド）
    Test-Step 'ウィンドウタイトルに左右のフォルダ名' { (& $title) -match 'left\s+│\s+right' } 15

    # F5 / F6（確認ダイアログを出さない copy-now / move-now を使う）
    Send-Emit $left reveal, (Join-Path $L 'a.txt'); Send-Emit $left plugin, yazipane, copy-now
    Test-Step 'F5: 反対ペインへコピー' { (Test-Path "$R/a.txt") -and (Test-Path "$L/a.txt") }
    Send-Emit $left reveal, (Join-Path $L 'b.txt'); Send-Emit $left plugin, yazipane, move-now
    Test-Step 'F6: 反対ペインへ移動' { (Test-Path "$R/b.txt") -and -not (Test-Path "$L/b.txt") }

    # y / p の共有。間に F5 を挟んでも y の内容は消えない
    Send-Emit $left reveal, (Join-Path $L 'c.txt'); Send-Emit $left yank; Start-Sleep 0.5
    Send-Emit $left reveal, (Join-Path $L 'd.txt'); Send-Emit $left plugin, yazipane, copy-now
    Test-Step 'F5: 2 回目のコピー' { Test-Path "$R/d.txt" }
    Send-Emit $right paste
    Test-Step '左で y → F5 → 右で p（F5 の後も y の内容が残る）' { Test-Path "$R/c.txt" }

    # 入れ替え / 反対ペインで開く / 同じ場所へ
    Send-Emit $left plugin, yazipane, swap
    Test-Step 'Alt+S: 左右の入れ替え' { (& $title) -match 'right\s+│\s+left' }
    Send-Emit $left plugin, yazipane, swap
    Test-Step 'Alt+S: もう一度で元に戻る' { (& $title) -match 'left\s+│\s+right' }
    Send-Emit $left reveal, (Join-Path $L 'sub'); Send-Emit $left plugin, yazipane, open-peer
    Test-Step 'Alt+I: カーソル位置のフォルダを反対ペインで開く' { (& $title) -match 'left\s+│\s+sub' }
    Send-Emit $left plugin, yazipane, push
    Test-Step '=: 反対ペインをこちらと同じ場所へ' { (& $title) -match 'left\s+│\s+left' }
    & ya pub-to $right yazipane-cd --str $R | Out-Null
    Test-Step '反対ペインを元の場所へ戻す' { (& $title) -match 'left\s+│\s+right' }
    Send-Emit $right plugin, yazipane, pull
    Test-Step 'Alt+O: こちらを反対ペインと同じ場所へ' { (& $title) -match 'left\s+│\s+left' }
    & ya pub-to $right yazipane-cd --str $R | Out-Null

    # この起動の左ペインのログを使う（別の yazipane のログとは混ぜない）
    $logDir = Get-ChildItem (Join-Path $state 'logs') -Directory | Where-Object Name -Like "*-$($launcher.Id)-*" | Select-Object -First 1
    if (-not $logDir) { throw 'テストのログディレクトリが見つかりません' }
    $plog = Join-Path $logDir.FullName 'plugin-left.log'
    Send-Emit $left plugin, yazipane, layout-single
    Test-Step '1 画面: yazi 本来の列の比率になる' { (Test-Path $plog) -and (Select-String -Path $plog -Pattern 'left layout single -> ratio' -Quiet) }
    Send-Emit $left plugin, yazipane, layout-dual
    Test-Step '2 画面: 2 画面用の比率に戻る' { Select-String -Path $plog -Pattern 'left layout dual -> ratio 0,' -Quiet }

    # 画面を止めて開くもの（エディタなど）の間は 1 画面になり、終わると 2 画面に戻る。
    # エディタは人によって違うので、数秒で終わるコマンドを yazi の shell --block で開いて確かめる。
    $env:WEZTERM_UNIX_SOCKET = Join-Path $env:USERPROFILE ".local\share\wezterm\gui-sock-$wez"
    $anyZoomed = { @(wezterm cli list --format json | ConvertFrom-Json | Where-Object is_zoomed).Count -gt 0 }
    Send-Emit $left shell, 'ping -n 5 127.0.0.1', '--block'
    Test-Step 'エディタなど（shell --block）を開いている間は 1 画面' { & $anyZoomed } 5
    Test-Step '閉じたら 2 画面に戻る' { -not (& $anyZoomed) } 10

    # 1 画面 / 2 画面の切り替え（Ctrl+Shift+Z）は WezTerm に任せている。WezTerm 側で切り替えても yazi の列が追従する
    $leftPane = (wezterm cli list --format json | ConvertFrom-Json | Where-Object { $_.cwd -like '*left*' } | Select-Object -First 1).pane_id
    $rightPane = (wezterm cli list --format json | ConvertFrom-Json | Where-Object { $_.cwd -like '*right*' } | Select-Object -First 1).pane_id
    wezterm cli activate-pane --pane-id $rightPane
    Test-Step 'フォーカスした右ペインに目印を出す' { (wezterm cli get-text --pane-id $rightPane) -match '(?m)^ ▶ ' }
    wezterm cli activate-pane --pane-id $leftPane
    Test-Step 'フォーカスを左へ戻すと目印も移る' {
        (wezterm cli get-text --pane-id $leftPane) -match '(?m)^ ▶ ' -and
        (wezterm cli get-text --pane-id $rightPane) -notmatch '(?m)^ ▶ '
    }
    Set-Content (Join-Path $L 'compare-left.txt') 'left'
    Set-Content (Join-Path $L 'compare-left2.txt') 'left2'
    Set-Content (Join-Path $R 'compare-right.txt') 'right'
    Set-Content (Join-Path $L 'compare-size.txt') 'short'
    Set-Content (Join-Path $R 'compare-size.txt') 'longer content'
    Set-Content (Join-Path $L 'compare-newer.txt') 'same'
    Set-Content (Join-Path $R 'compare-newer.txt') 'same'
    $compareTime = [DateTime]::UtcNow.AddMinutes(-10)
    [IO.File]::SetLastWriteTimeUtc((Join-Path $L 'compare-size.txt'), $compareTime)
    [IO.File]::SetLastWriteTimeUtc((Join-Path $R 'compare-size.txt'), $compareTime)
    [IO.File]::SetLastWriteTimeUtc((Join-Path $L 'compare-newer.txt'), $compareTime)
    [IO.File]::SetLastWriteTimeUtc((Join-Path $R 'compare-newer.txt'), $compareTime.AddMinutes(1))
    Send-Emit $left plugin, yazipane, compare
    Test-Step 'Alt+C: 左右の違いを一覧表示する' {
        $screen = wezterm cli get-text --pane-id $leftPane | Out-String
        $screen -match '左のみ\s+compare-left.txt' -and $screen -match '右のみ\s+compare-right.txt' -and
        $screen -match 'サイズが違う\s+compare-size.txt' -and $screen -match '右が新しい\s+compare-newer.txt'
    }
    if ($results[-1].Result -eq 'NG') { wezterm cli get-text --pane-id $leftPane }
    wezterm cli send-text --pane-id $leftPane --no-paste ([string][char]27)
    Test-Step 'Alt+C: Esc で一覧を閉じる' { (wezterm cli get-text --pane-id $leftPane) -notmatch '左のみ\s+compare-left.txt' }
    Send-Emit $left plugin, yazipane, compare
    Test-Step 'Alt+C: 選択の前に一覧を再表示する' { (wezterm cli get-text --pane-id $leftPane) -match '左のみ\s+compare-left.txt' }
    wezterm cli send-text --pane-id $leftPane --no-paste 's'
    Test-Step 'Alt+C: S でこちら側の項目を選択する' { (wezterm cli get-text --pane-id $leftPane) -match '選択しました' }
    Send-Emit $left plugin, yazipane, copy-now
    Test-Step 'Alt+C: 複数選択した差分を F5 でコピーできる' {
        (Test-Path -LiteralPath (Join-Path $R 'compare-left.txt')) -and
        (Test-Path -LiteralPath (Join-Path $R 'compare-left2.txt'))
    }
    if ($results[-1].Result -eq 'NG') {
        wezterm cli get-text --pane-id $leftPane
        Get-ChildItem (Join-Path $state 'logs') -Recurse -Filter 'transfer-*.log' | ForEach-Object { Get-Content -LiteralPath $_.FullName }
    }
    Send-Emit $left plugin, yazipane, folder-pairs
    Test-Step 'Alt+B: 保存 / 復元メニューを表示する' { (wezterm cli get-text --pane-id $leftPane) -match '(?m)^│> s\s+' }
    wezterm cli send-text --pane-id $leftPane --no-paste 's'
    Test-Step 'Alt+B: 名前の入力欄を表示する' { (wezterm cli get-text --pane-id $leftPane) -match 'フォルダの組の名前' }
    wezterm cli send-text --pane-id $leftPane --no-paste $pairName
    wezterm cli send-text --pane-id $leftPane --no-paste "`r"
    Test-Step 'Alt+B: フォルダの組を保存する' { Test-Path -LiteralPath $pairFile }
    Send-Emit $left cd, $R
    Send-Emit $right cd, $L
    Test-Step 'Alt+B: 復元前に左右を入れ替える' { (& $title) -match 'right\s+│\s+left' }
    Send-Emit $left plugin, yazipane, folder-pairs
    Test-Step 'Alt+B: メニューを再表示する' { (wezterm cli get-text --pane-id $leftPane) -match '(?m)^│> s\s+' }
    wezterm cli send-text --pane-id $leftPane --no-paste 'o'
    Test-Step 'Alt+B: 保存した組を一覧に出す' { (wezterm cli get-text --pane-id $leftPane) -match [regex]::Escape($pairName) }
    $pairText = (wezterm cli get-text --pane-id $leftPane | Out-String)
    $pairMatch = [regex]::Match($pairText, '(?m)^│(?:> |  )([a-z0-9])\s+' + [regex]::Escape($pairName))
    if ($pairMatch.Success) { wezterm cli send-text --pane-id $leftPane --no-paste $pairMatch.Groups[1].Value }
    Test-Step 'Alt+B: 保存した左右のフォルダを復元する' { (& $title) -match 'left\s+│\s+right' }
    Send-Emit $left plugin, yazipane, folder-pairs
    Test-Step 'Alt+B: 削除メニューを表示する' { (wezterm cli get-text --pane-id $leftPane) -match '(?m)^│> s\s+' }
    wezterm cli send-text --pane-id $leftPane --no-paste 'd'
    Test-Step 'Alt+B: 削除する組を表示する' { (wezterm cli get-text --pane-id $leftPane) -match [regex]::Escape($pairName) }
    $pairText = (wezterm cli get-text --pane-id $leftPane | Out-String)
    $pairMatch = [regex]::Match($pairText, '(?m)^│(?:> |  )([a-z0-9])\s+' + [regex]::Escape($pairName))
    if ($pairMatch.Success) { wezterm cli send-text --pane-id $leftPane --no-paste $pairMatch.Groups[1].Value }
    Test-Step 'Alt+B: 削除の確認を表示する' { (wezterm cli get-text --pane-id $leftPane) -match '削除' }
    wezterm cli send-text --pane-id $leftPane --no-paste 'y'
    Test-Step 'Alt+B: 確認した組を削除する' { -not (Test-Path -LiteralPath $pairFile) }
    $driveRoot = [IO.Path]::GetPathRoot($L)
    $drivePattern = '(?im)^│> ' + [regex]::Escape($driveRoot.Substring(0, 1)) + '\s+' + [regex]::Escape($driveRoot)
    Send-Emit $left plugin, yazipane, drives
    Test-Step 'Alt+D: ドライブの一覧を左寄せで表示する' { (wezterm cli get-text --pane-id $leftPane) -match $drivePattern }
    if ($results[-1].Result -eq 'NG') { wezterm cli get-text --pane-id $leftPane }
    wezterm cli send-text --pane-id $leftPane --no-paste ([string][char]27)
    Test-Step 'Alt+D: Esc で一覧を閉じる' { (wezterm cli get-text --pane-id $leftPane) -notmatch $drivePattern }
    Send-Emit $left plugin, yazipane, drives
    Test-Step 'Alt+D: 再び一覧を表示する' { (wezterm cli get-text --pane-id $leftPane) -match $drivePattern }
    wezterm cli send-text --pane-id $leftPane --no-paste ($driveRoot.Substring(0, 1).ToLowerInvariant())
    Test-Step 'Alt+D: 英字キーでドライブへ移動する' { (Get-Content (Join-Path $state 'last-left.txt') -Raw).Trim() -eq $driveRoot }
    Send-Emit $left cd, $L
    Test-Step 'ドライブ選択後に元の場所へ戻る' { (Get-Content (Join-Path $state 'last-left.txt') -Raw).Trim() -eq $L }
    Send-Emit $left plugin, yazipane, drives
    Test-Step 'Alt+D: 矢印操作の前に一覧を表示する' { (wezterm cli get-text --pane-id $leftPane) -match $drivePattern }
    wezterm cli send-text --pane-id $leftPane --no-paste "`e[A"
    wezterm cli send-text --pane-id $leftPane --no-paste "`r"
    Test-Step 'Alt+D: 上矢印と Enter で先頭のドライブへ移動する' { (Get-Content (Join-Path $state 'last-left.txt') -Raw).Trim() -eq $driveRoot }
    Send-Emit $left cd, $L
    Test-Step '矢印操作後に元の場所へ戻る' { (Get-Content (Join-Path $state 'last-left.txt') -Raw).Trim() -eq $L }
    $singles = @(Select-String -Path $plog -Pattern 'left layout single').Count
    wezterm cli zoom-pane --pane-id $leftPane --zoom
    Test-Step 'WezTerm で 1 画面にすると yazi が本来の 3 列になる' { @(Select-String -Path $plog -Pattern 'left layout single').Count -gt $singles }
    $duals = @(Select-String -Path $plog -Pattern 'left layout dual').Count
    wezterm cli zoom-pane --pane-id $leftPane --unzoom
    Test-Step 'WezTerm で 2 画面に戻すと yazi も 2 画面用の列に戻る' { @(Select-String -Path $plog -Pattern 'left layout dual').Count -gt $duals }

    # 前回のフォルダの記録
    Test-Step '今のフォルダを記録する' { (Get-Content (Join-Path $state 'last-left.txt') -Raw).Trim() -eq $L }

    # --reuse: 起動中のウィンドウで指定のフォルダを開き、新しいウィンドウは開かない
    $second = Start-Process -FilePath $exe -ArgumentList '--reuse', "`"$R`"", "`"$(Join-Path $L 'sub')`"" -PassThru
    $finished = $second.WaitForExit(15000)
    if (-not $finished) {
        # 新しいウィンドウを開いてしまった（WezTerm の終了を待っている）。後片付けして失敗にする
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($second.Id)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $second.Id -Force -ErrorAction SilentlyContinue
    }
    Test-Step '--reuse: 2 回目の起動はすぐに終わる' { $finished } 0
    Test-Step '--reuse: 新しいウィンドウは開かない' {
        @(Get-CimInstance Win32_Process -Filter "Name='yazi.exe'" | Where-Object { $_.CommandLine -like "*$work*" }).Count -eq 2
    } 0
    Test-Step '--reuse: 起動中のペインが指定のフォルダに移る' { (& $title) -match 'right\s+│\s+sub' }

    # q で両方のペインを終了する
    Send-Emit $left plugin, yazipane, quit
    Test-Step 'q: 両方のペインとウィンドウが終了する' {
        -not (Get-Process -Id $wez -ErrorAction SilentlyContinue) -and
        -not (Get-CimInstance Win32_Process -Filter "Name='yazi.exe'" | Where-Object { $_.CommandLine -like "*$work*" })
    } 10
}
finally {
    if (Test-Path -LiteralPath $pairFile) { Remove-Item -LiteralPath $pairFile -Force }
    # 失敗して残ったウィンドウを閉じる
    if ($wez) { Stop-Process -Id $wez -ErrorAction SilentlyContinue }
    $env:YAZIPANE_TEST_SESSION = $oldTestSession
    $resolvedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'yazipane/smoke'))
    $resolvedState = [IO.Path]::GetFullPath($state)
    if ((Split-Path $resolvedState -Parent) -eq $resolvedRoot -and (Test-Path -LiteralPath $resolvedState)) {
        Remove-Item -LiteralPath $resolvedState -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$results | Format-Table -AutoSize
$ng = @($results | Where-Object Result -eq 'NG').Count
if ($ng -gt 0) {
    Write-Host "$ng 件失敗しました" -ForegroundColor Red
    exit 1
}
Write-Host "すべて成功しました（$($results.Count) 件）" -ForegroundColor Green
