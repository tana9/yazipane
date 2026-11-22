# 起動中の yazipane（yazipane の設定で動いている WezTerm と、待機中の yazipane.exe）を終了する。
# 普段使いの WezTerm や yazi には触れない。
Get-CimInstance Win32_Process -Filter "Name='wezterm-gui.exe'" |
    Where-Object { $_.CommandLine -match 'yazipane' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
# 別のユーザー（サンドボックスなど）が起動したものは確認を求められて止まるので -Force を付ける
Get-Process yazipane -ErrorAction SilentlyContinue | Stop-Process -Force
# exe のロックが外れるのを少し待つ
Start-Sleep -Milliseconds 500
