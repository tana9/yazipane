# publish/yazipane.exe を切り離して起動する（yazipane.exe は WezTerm の終了まで待機するため）。
# 引数はそのまま yazipane.exe に渡す: pwsh tools/start.ps1 [--debug] [左のフォルダ] [右のフォルダ]
$exe = Join-Path (Split-Path $PSScriptRoot -Parent) 'publish/yazipane.exe'
$list = @($args | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { "$_" } })
if ($list.Count -gt 0) {
    Start-Process -FilePath $exe -ArgumentList $list
} else {
    Start-Process -FilePath $exe
}
