# --debug で起動したときの yazipane とプラグインのログを表示する。
$root = Join-Path $env:LOCALAPPDATA 'yazipane/logs'
$dir = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
    Sort-Object CreationTimeUtc -Descending | Select-Object -First 1
if (-not $dir) { Write-Host 'ログはありません'; return }
Write-Host "===== $($dir.FullName)"
Get-ChildItem -LiteralPath $dir.FullName -Filter '*.log' -File | Sort-Object Name | ForEach-Object {
    Write-Host "===== $($_.Name)"
    Get-Content -LiteralPath $_.FullName
}
