# ビルドで作られたファイル（各プロジェクトの bin / obj と publish）を消す。
$root = Split-Path $PSScriptRoot -Parent
foreach ($dir in 'publish', 'Yazipane/bin', 'Yazipane/obj', 'Yazipane.Tests/bin', 'Yazipane.Tests/obj') {
    $path = Join-Path $root $dir
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force
        Write-Host "removed $dir"
    }
}
