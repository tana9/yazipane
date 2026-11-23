# Lua の静的チェック（lua-language-server --check）。
#   - yazi の設定とプラグイン（Yazipane/assets/yazi）は yazi の型定義（yazi-rs/plugins の types.yazi）で
#   - WezTerm の設定（Yazipane/assets/wezterm.lua）は WezTerm の型定義（DrKJeff16/wezterm-types）で
# 未定義の変数、存在しない API の呼び出し、型の食い違いなどを調べる。
# 型定義はコミットを固定して .cache/lua-types に取得する（リポジトリには入れない）。
#   pwsh tools/lua-check.ps1        （task lua-check）
# lua-language-server が必要: scoop install lua-language-server

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cache = Join-Path $root '.cache/lua-types'

if (-not (Get-Command lua-language-server -ErrorAction SilentlyContinue)) {
    Write-Warning 'lua-language-server が見つからないため、Lua の静的チェックを飛ばしました（scoop install lua-language-server）'
    exit 0
}

# ---- 型定義（更新するときはコミットを書き換える） ----
$yaziTypesCommit = '4dc7f1b6458c2578f4494f10d468c68c1082214f'     # yazi 26.9 に対応
$weztermTypesCommit = '1e6a0b7ac2206b197c741240743e981af37ce292'

$yaziTypes = Join-Path $cache "yazi-$yaziTypesCommit"
if (-not (Test-Path $yaziTypes)) {
    New-Item -ItemType Directory -Force $yaziTypes | Out-Null
    Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/yazi-rs/plugins/$yaziTypesCommit/types.yazi/main.lua" `
        -OutFile (Join-Path $yaziTypes 'types.lua')
}
$weztermTypes = Join-Path $cache "wezterm-$weztermTypesCommit"
if (-not (Test-Path $weztermTypes)) {
    $zip = Join-Path $cache 'wezterm-types.zip'
    New-Item -ItemType Directory -Force $cache | Out-Null
    Invoke-WebRequest -UseBasicParsing "https://codeload.github.com/DrKJeff16/wezterm-types/zip/$weztermTypesCommit" -OutFile $zip
    $tmp = Join-Path $cache 'wezterm-extract'
    Expand-Archive $zip $tmp -Force
    Move-Item (Join-Path (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName 'lua') $weztermTypes
    Remove-Item $tmp, $zip -Recurse -Force
}

# ---- チェック ----

# 調べる対象を一時フォルダに写して調べる（対象ごとに型定義が違うので、ワークスペースを分ける）
function Invoke-LuaCheck([string]$name, [string[]]$files, [string]$library, [string[]]$globals) {
    $work = Join-Path $cache "check-$name"
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Force $work | Out-Null
    $map = @{}
    foreach ($f in $files) {
        $dst = Join-Path $work (Split-Path $f -Leaf)
        Copy-Item (Join-Path $root $f) $dst
        $map[(Split-Path $f -Leaf)] = $f
    }
    $config = @{
        'runtime.version'      = 'Lua 5.4'
        'workspace.library'    = @($library)
        'workspace.checkThirdParty' = $false
        'diagnostics.globals'  = $globals
    } | ConvertTo-Json -Depth 4
    $configPath = Join-Path $work '.luarc.json'
    Set-Content $configPath $config -Encoding utf8NoBOM

    $log = Join-Path $cache "log-$name"
    $result = Join-Path $cache "result-$name.json"
    if (Test-Path $result) { Remove-Item $result }
    $null = lua-language-server --check=$work --checklevel=Warning --configpath=$configPath --logpath=$log `
        --check_format=json --check_out_path=$result 2>&1
    if (-not (Test-Path $result)) {
        throw "lua-language-server の結果が出力されませんでした（$name）"
    }
    $problems = @()
    $text = Get-Content $result -Raw
    if ($text -and $text.Trim() -notin '', '[]', '{}') {
        $json = $text | ConvertFrom-Json -AsHashtable
        foreach ($uri in $json.Keys) {
            $file = [Uri]::UnescapeDataString(($uri -split '/')[-1])
            foreach ($d in $json[$uri]) {
                $problems += [pscustomobject]@{
                    File    = $map[$file] ?? $file
                    Line    = $d.range.start.line + 1
                    Code    = $d.code
                    Message = ($d.message -split "`n")[0]
                }
            }
        }
    }
    $problems | Sort-Object File, Line
}

# yazi の UI の部品（型定義に含まれていないもの）
$yaziGlobals = @('Status', 'Current', 'Header', 'Tab', 'Linemode', 'Modal')
$all = @()
$all += Invoke-LuaCheck 'yazi' @(
    'Yazipane/assets/yazi/init.lua',
    'Yazipane/assets/yazi/plugins/yazipane.yazi/main.lua'
) (Join-Path $yaziTypes 'types.lua') $yaziGlobals
$all += Invoke-LuaCheck 'yazi-picker' @('Yazipane/assets/yazi/plugins/yazipane-picker.yazi/main.lua') (Join-Path $yaziTypes 'types.lua') $yaziGlobals
$all += Invoke-LuaCheck 'yazi-pairs' @('Yazipane/assets/yazi/plugins/yazipane-pairs.yazi/main.lua') (Join-Path $yaziTypes 'types.lua') $yaziGlobals
$all += Invoke-LuaCheck 'yazi-report' @('Yazipane/assets/yazi/plugins/yazipane-report.yazi/main.lua') (Join-Path $yaziTypes 'types.lua') $yaziGlobals
$all += Invoke-LuaCheck 'wezterm' @('Yazipane/assets/wezterm.lua') $weztermTypes @()

if ($all.Count -gt 0) {
    $all | Format-Table -AutoSize -Wrap
    Write-Host "Lua の静的チェック: $($all.Count) 件" -ForegroundColor Yellow
    exit 1
}
Write-Host 'Lua の静的チェック: 問題なし' -ForegroundColor Green
