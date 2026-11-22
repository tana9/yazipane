# yazipane の連携機能のスモークテスト。
# 一時フォルダで yazipane を起動し、ya emit-to で操作して、ファイル / ウィンドウタイトル / プラグインのログで結果を確かめる。
#   task smoke（publish/yazipane.exe を最新にしてから実行する）
# - 前回のフォルダの記録（last-*.txt）はテスト中に書き換わるので、退避して最後に戻す。
# - マウス / キー操作が必要なもの（右クリックメニュー、ドラッグ、Ctrl+Shift+Z のキー自体）は対象外。

#   -Exe: 試す yazipane.exe（既定は publish/yazipane.exe。カバレッジを測るときは Debug のビルドを渡す: tools/coverage-smoke.ps1）
param([string]$Exe)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$exe = if ($Exe) { (Resolve-Path $Exe).Path } else { Join-Path $root 'publish/yazipane.exe' }
$state = Join-Path $env:LOCALAPPDATA 'yazipane'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("yazipane-smoke-" + [guid]::NewGuid().ToString('N'))
$L = Join-Path $work 'left'
$R = Join-Path $work 'right'

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

$backup = @{}
foreach ($side in 'left', 'right') {
    $f = Join-Path $state "last-$side.txt"
    if (Test-Path $f) { $backup[$f] = Get-Content $f -Raw }
}

try {
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
    # 失敗して残ったウィンドウを閉じる
    if ($wez) { Stop-Process -Id $wez -ErrorAction SilentlyContinue }
    foreach ($side in 'left', 'right') {
        $f = Join-Path $state "last-$side.txt"
        if ($backup.ContainsKey($f)) { Set-Content $f $backup[$f] -NoNewline } else { Remove-Item $f -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$results | Format-Table -AutoSize
$ng = @($results | Where-Object Result -eq 'NG').Count
if ($ng -gt 0) {
    Write-Host "$ng 件失敗しました（ログ: task log）" -ForegroundColor Red
    exit 1
}
Write-Host "すべて成功しました（$($results.Count) 件）" -ForegroundColor Green
