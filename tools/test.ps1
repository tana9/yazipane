# 単体テスト（C# の xUnit と、yazi のプラグインの Lua テスト）を実行する。
$root = Split-Path $PSScriptRoot -Parent

# テスト用の一時領域を指定する。SDK が実行ごとにアクセスを制限したサブディレクトリを作る。
if (-not $env:VSTEST_ARTIFACTS_BASE_DIRECTORY) {
    $env:VSTEST_ARTIFACTS_BASE_DIRECTORY = [System.IO.Path]::GetTempPath()
}
dotnet test (Join-Path $root 'yazipane.slnx')
$dotnet = $LASTEXITCODE

# yazi / WezTerm の API を偽物に差し替えて main.lua / wezterm.lua を読み込み、操作ごとの動きを確かめる（lua が無ければ飛ばす）
$lua = 0
if (Get-Command lua -ErrorAction SilentlyContinue) {
    lua (Join-Path $root 'Yazipane.Tests/lua/plugin_test.lua') (Join-Path $root 'Yazipane/assets/yazi/plugins/yazipane.yazi/main.lua')
    $lua = $LASTEXITCODE
    lua (Join-Path $root 'Yazipane.Tests/lua/wezterm_test.lua') (Join-Path $root 'Yazipane/assets/wezterm.lua')
    if ($LASTEXITCODE -ne 0) { $lua = $LASTEXITCODE }
} else {
    Write-Warning 'lua が見つからないため、プラグインのテストを飛ばしました（scoop install lua）'
}

exit ($dotnet -ne 0 ? $dotnet : $lua)
