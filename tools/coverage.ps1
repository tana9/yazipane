# C# のカバレッジを測り、ファイルごとの行カバレッジを表示する。
#   pwsh tools/coverage.ps1          単体テストだけ（task coverage）
#   pwsh tools/coverage.ps1 -Smoke   単体テスト + スモークテスト（task coverage-all。WezTerm のウィンドウが開く）
# 単体テストは coverlet（テストのプロジェクトの coverlet.collector）で測る。
# スモークテストは NativeAOT の exe では測れないので、Debug のビルドの yazipane.exe で動かし、
# dotnet-coverage（dotnet-tools.json。dotnet tool restore で入る）で、WezTerm → yazi → yazipane.exe と起動された
# 子プロセスも含めて測る。2 つの結果は行ごとに合算する（どちらかで通った行を「通った」とする）。
# ソース生成で作られたファイル（obj/ 以下）は数えない。Lua のプラグインは対象外。
# 結果は .cache/coverage に残す。
param([switch]$Smoke)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root '.cache/coverage'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force $out | Out-Null
# dotnet-coverage などが利用状況を送らないようにする
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

# ---- 単体テスト ----
if (-not $env:VSTEST_ARTIFACTS_BASE_DIRECTORY) {
    $env:VSTEST_ARTIFACTS_BASE_DIRECTORY = [System.IO.Path]::GetTempPath()
}
dotnet test (Join-Path $root 'yazipane.slnx') --collect:'XPlat Code Coverage' --results-directory (Join-Path $out 'unit') `
    --settings (Join-Path $PSScriptRoot 'coverage.runsettings')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$unitXml = Join-Path $out 'unit.cobertura.xml'
Move-Item (Get-ChildItem (Join-Path $out 'unit') -Recurse -Filter coverage.cobertura.xml | Select-Object -First 1).FullName $unitXml

# ---- スモークテスト ----
$smokeXml = $null
$smokeExit = 0
if ($Smoke) {
    dotnet tool restore | Out-Null
    dotnet build (Join-Path $root 'Yazipane') -c Debug -v q
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $exe = Join-Path $root 'Yazipane/bin/Debug/net11.0-windows/win-x64/yazipane.exe'
    $smokeXml = Join-Path $out 'smoke.cobertura.xml'
    $smokeScript = Join-Path $PSScriptRoot 'smoke.ps1'
    dotnet tool run dotnet-coverage -- collect --nologo -f cobertura -o $smokeXml `
        "pwsh -NoProfile -File `"$smokeScript`" -Exe `"$exe`""
    $smokeExit = $LASTEXITCODE
}

# ---- 集計 ----

# cobertura の結果を「ファイル（Yazipane/ からの相対パス） → 行番号 → 通ったか」にする
function Read-Coverage([string]$path) {
    [xml]$c = Get-Content $path
    $source = @($c.coverage.sources.source)[0]
    $files = @{}
    foreach ($class in $c.coverage.packages.package.classes.class) {
        $name = $class.filename
        if (-not [IO.Path]::IsPathRooted($name) -and $source) { $name = Join-Path $source $name }
        $name = [IO.Path]::GetRelativePath((Join-Path $root 'Yazipane'), $name) -replace '\\', '/'
        if ($name -like '..*' -or $name -like 'obj/*') { continue }
        if (-not $files.ContainsKey($name)) { $files[$name] = @{} }
        foreach ($line in @($class.lines.line)) {
            $n = [int]$line.number
            $files[$name][$n] = ($files[$name][$n] -eq $true) -or ([int]$line.hits -gt 0)
        }
    }
    $files
}

function Format-Rate($hit, $total) { if ($total) { '{0,5:0.0}' -f ($hit * 100.0 / $total) } else { '    -' } }

$unit = Read-Coverage $unitXml
$smokeCov = if ($smokeXml) { Read-Coverage $smokeXml } else { @{} }
$names = @($unit.Keys) + @($smokeCov.Keys) | Sort-Object -Unique
$sum = @{ Lines = 0; Unit = 0; Smoke = 0; All = 0 }
$rows = foreach ($name in $names) {
    $u = $unit[$name] ?? @{}
    $s = $smokeCov[$name] ?? @{}
    $lines = @($u.Keys) + @($s.Keys) | Sort-Object -Unique
    $uHit = @($lines | Where-Object { $u[$_] }).Count
    $sHit = @($lines | Where-Object { $s[$_] }).Count
    $aHit = @($lines | Where-Object { $u[$_] -or $s[$_] }).Count
    $sum.Lines += $lines.Count; $sum.Unit += $uHit; $sum.Smoke += $sHit; $sum.All += $aHit
    $row = [ordered]@{ File = $name; Lines = $lines.Count; 'Unit %' = Format-Rate $uHit $lines.Count }
    if ($Smoke) {
        $row['Smoke %'] = Format-Rate $sHit $lines.Count
        $row['All %'] = Format-Rate $aHit $lines.Count
    }
    [pscustomobject]$row
}
$rows | Format-Table -AutoSize
$summary = "合計 {0} 行: 単体テスト {1}%" -f $sum.Lines, (Format-Rate $sum.Unit $sum.Lines).Trim()
if ($Smoke) {
    $summary += "、スモークテスト {0}%、合算 {1}%" -f (Format-Rate $sum.Smoke $sum.Lines).Trim(), (Format-Rate $sum.All $sum.Lines).Trim()
}
Write-Host "$summary（結果: $out）"

if ($smokeExit -ne 0) {
    Write-Warning "スモークテストが失敗しました（終了コード $smokeExit）。カバレッジはその時点までのもの"
    exit $smokeExit
}
