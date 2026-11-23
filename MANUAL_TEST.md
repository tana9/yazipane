# 実機での確認

自動テストではまだ確認していない操作を含め、一時フォルダで試す。元のファイルを使わない。
`task build` の後、PowerShell で次を実行し、表示されたパスをエクスプローラーでも開く。

```powershell
$testDir = Join-Path $env:TEMP ("yazipane-manual-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force (Join-Path $testDir 'left'), (Join-Path $testDir 'right') | Out-Null
Set-Content -LiteralPath (Join-Path $testDir 'left\copy.txt') -Value '左のコピー元'
Set-Content -LiteralPath (Join-Path $testDir 'left\move.txt') -Value '左の移動元'
Set-Content -LiteralPath (Join-Path $testDir 'left\same.txt') -Value '左の内容'
Set-Content -LiteralPath (Join-Path $testDir 'right\same.txt') -Value '右の内容'
Start-Process -FilePath (Resolve-Path 'publish\yazipane.exe') -ArgumentList "`"$testDir\left`"", "`"$testDir\right`""
Write-Host "確認用フォルダ: $testDir"
```

- [ ] 左の `copy.txt` を右クリックし、Windows のメニューが開く。`Shift+F10` でも開く。
- [ ] `copy.txt` を F5 でコピーし、確認後に右へ作られる。`move.txt` を F6 で移動すると左から消える。
- [ ] `same.txt` を F5 でコピーし、同名ダイアログでスキップすると右側の内容が残り、スキップ件数が通知される。
- [ ] 左の `copy.txt` を `Ctrl+C` でコピーし、エクスプローラーで貼り付けられる。`Alt+X` では切り取りになる。
- [ ] エクスプローラーでテスト用ファイルを切り取り、yazipane の別フォルダで `Ctrl+V` すると移動される。
- [ ] `copy.txt` をエクスプローラーへドラッグし、コピーまたはショートカットが作られる。
- [ ] `Alt+C` に左右の違いが表示され、`Esc` では選択が変わらず、`S` ではこちらにしかない / 新しい項目が選ばれる。
- [ ] `Alt+B` でフォルダの組を保存し、左右を移動した後に復元できる。確認後、同じメニューから組を削除する。
- [ ] 左右のペインをマウスで切り替えると `▶` が移動する。`Ctrl+Tab`、`Ctrl+Shift+Z`、`Ctrl+Shift+E` も動く。

終了後、テスト用フォルダが不要なら、表示されたパスを確認してからエクスプローラーで削除する。クリップボードはテストに使った内容へ変わる。
