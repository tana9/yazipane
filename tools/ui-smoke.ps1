# 対話可能な Windows デスクトップで実際のキー操作を試す。
# 既存の smoke と同様に yazipane の状態を分離する。
param([string]$Exe)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class YazipaneUiInput {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
}
'@

$root = Split-Path $PSScriptRoot -Parent
$exePath = if ($Exe) { (Resolve-Path -LiteralPath $Exe).Path } else { Join-Path $root 'publish/yazipane.exe' }
if (-not (Test-Path -LiteralPath $exePath)) { throw "$exePath がありません。先に task build を実行してください。" }
$session = [guid]::NewGuid().ToString('N')
$stateRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'yazipane/smoke'))
$state = [IO.Path]::GetFullPath((Join-Path $stateRoot $session))
$work = Join-Path ([IO.Path]::GetTempPath()) "yazipane-ui-$session"
$leftDir = Join-Path $work 'left'
$rightDir = Join-Path $work 'right'
$oldSession = $env:YAZIPANE_TEST_SESSION
$oldUiSession = $env:YAZIPANE_UI_TEST_SESSION
$wezClass = "yazipane-test-$session"
$wez = $null
$launcher = $null
$passed = 0
$clipboard = $null
$clipboardSaved = $false

function Wait-Until([string]$description, [scriptblock]$condition, [int]$seconds = 15) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $condition) { Write-Host "OK: $description"; $script:passed++; return }
        Start-Sleep -Milliseconds 200
    } while ($timer.Elapsed.TotalSeconds -lt $seconds)
    throw "失敗: $description"
}

function Send-Key([string]$keys) {
    if (-not [YazipaneUiInput]::IsWindow($script:window)) { throw 'テスト対象のウィンドウがありません' }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        [void][YazipaneUiInput]::SetForegroundWindow($script:window)
        Start-Sleep -Milliseconds 200
    } while ([YazipaneUiInput]::GetForegroundWindow() -ne $script:window -and $timer.Elapsed.TotalSeconds -lt 5)
    if ([YazipaneUiInput]::GetForegroundWindow() -ne $script:window) { throw 'テスト対象のウィンドウを前面にできません' }
    [Windows.Forms.SendKeys]::SendWait($keys)
}

function Reveal([string]$name) {
    & ya emit-to $script:leftId reveal (Join-Path $leftDir $name)
    if ($LASTEXITCODE -ne 0) { throw 'ファイルの選択に失敗しました' }
    Start-Sleep -Milliseconds 500
}

function Get-TestPaneText {
    $panes = & wezterm cli --class $script:wezClass list --format json | ConvertFrom-Json
    $target = ([string]$script:leftDir).Replace('\', '/')
    $pane = $panes | Where-Object { ([string]$_.cwd).Replace('\', '/').Contains($target) } | Select-Object -First 1
    if (-not $pane) { return $null }
    & wezterm cli --class $script:wezClass get-text --pane-id $pane.pane_id
}

try {
    New-Item -ItemType Directory -Force $leftDir, $rightDir | Out-Null
    Set-Content -LiteralPath (Join-Path $leftDir 'copy.txt') -Value 'copy'
    Set-Content -LiteralPath (Join-Path $leftDir 'move.txt') -Value 'move'
    $env:YAZIPANE_TEST_SESSION = $session
    $env:YAZIPANE_UI_TEST_SESSION = $session
    $launcher = Start-Process -FilePath $exePath -ArgumentList '--debug', "`"$leftDir`"", "`"$rightDir`"" -PassThru
    $yazis = @()
    Wait-Until 'テスト用の 2 ペインが起動' {
        $script:yazis = @(Get-CimInstance Win32_Process -Filter "Name='yazi.exe'" | Where-Object { $_.CommandLine -like "*$work*" -and $_.CommandLine -match '--client-id (\d+)' })
        $script:yazis.Count -eq 2
    } 30
    $leftYazi = $yazis | Where-Object { $_.CommandLine -like "*$leftDir*" } | Select-Object -First 1
    $leftId = [uint64]($leftYazi.CommandLine -replace '.*--client-id (\d+).*', '$1')
    $wez = $leftYazi.ParentProcessId
    Wait-Until 'WezTerm のウィンドウが表示' {
        $script:window = (Get-Process -Id $wez -ErrorAction SilentlyContinue).MainWindowHandle
        $script:window -ne [IntPtr]::Zero
    }
    Wait-Until '左ペインの初期化' { Test-Path -LiteralPath (Join-Path $state 'last-left.txt') }
    Start-Sleep -Seconds 2

    Reveal 'copy.txt'
    Send-Key '{F5}'
    Wait-Until 'F5 の確認画面が表示される' { (Get-TestPaneText) -match '反対ペインへコピー' }
    Send-Key '{ESC}'
    Wait-Until 'Esc で F5 の確認画面が閉じる' { (Get-TestPaneText) -notmatch '反対ペインへコピー' }
    if (Test-Path -LiteralPath (Join-Path $rightDir 'copy.txt')) { throw '失敗: Esc でコピーをキャンセル' }
    Write-Host 'OK: Esc でコピーをキャンセル'; $passed++
    Send-Key '{F5}'
    Wait-Until 'F5 の確認画面が再表示される' { (Get-TestPaneText) -match '反対ペインへコピー' }
    Send-Key '{ENTER}'
    Wait-Until 'Enter でコピーを実行' { Test-Path -LiteralPath (Join-Path $rightDir 'copy.txt') }

    Reveal 'move.txt'
    Send-Key '{F6}'
    Wait-Until 'F6 の確認画面が表示される' { (Get-TestPaneText) -match '反対ペインへ移動' }
    Send-Key '{ENTER}'
    Wait-Until 'Enter で移動を実行' { (Test-Path -LiteralPath (Join-Path $rightDir 'move.txt')) -and -not (Test-Path -LiteralPath (Join-Path $leftDir 'move.txt')) }

    Reveal 'copy.txt'
    $clipboard = [Windows.Forms.Clipboard]::GetDataObject()
    $clipboardSaved = $true
    Send-Key '^c'
    Wait-Until 'Ctrl+C でファイルをクリップボードにコピー' {
        [Windows.Forms.Clipboard]::ContainsFileDropList() -and
        [Windows.Forms.Clipboard]::GetFileDropList().Contains((Join-Path $leftDir 'copy.txt'))
    }

    Send-Key '+{F10}'
    Wait-Until 'Shift+F10 で Windows のメニュー処理を起動' {
        @(Get-CimInstance Win32_Process -Filter "Name='yazipane.exe'" | Where-Object { $_.CommandLine -like '*--context-menu*' -and $_.CommandLine -like "*$work*" }).Count -gt 0
    }
    Start-Sleep -Seconds 3
    [Windows.Forms.SendKeys]::SendWait('{ESC}')
    Wait-Until 'Esc で Windows のメニューを閉じる' {
        @(Get-CimInstance Win32_Process -Filter "Name='yazipane.exe'" | Where-Object { $_.CommandLine -like '*--context-menu*' -and $_.CommandLine -like "*$work*" }).Count -eq 0
    }

    Write-Host "すべて成功しました（$passed 件）" -ForegroundColor Green
}
finally {
    if ($clipboardSaved) {
        try {
            if ($null -eq $clipboard) { [Windows.Forms.Clipboard]::Clear() }
            else { [Windows.Forms.Clipboard]::SetDataObject($clipboard, $true) }
        }
        catch { Write-Warning "クリップボードを復元できませんでした: $_" }
    }
    if ($wez) { Stop-Process -Id $wez -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='yazipane.exe'" | Where-Object { $_.CommandLine -like '*--context-menu*' -and $_.CommandLine -like "*$work*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
    if ($launcher -and -not $launcher.HasExited) { [void]$launcher.WaitForExit(5000) }
    $env:YAZIPANE_TEST_SESSION = $oldSession
    $env:YAZIPANE_UI_TEST_SESSION = $oldUiSession
    if ((Split-Path $state -Parent) -eq $stateRoot -and (Test-Path -LiteralPath $state)) { Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
