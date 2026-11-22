# yazipane のアイコン（Yazipane/icon/yazipane.ico と確認用の PNG）を生成する。
#   pwsh tools/make-icon.ps1
# 図柄: ターミナルのプロンプトとフォルダを描く。
# 配色は tokyonight 系。32px 以下では細部を省いた簡略版を描く。

Add-Type -AssemblyName System.Drawing

$root = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $root 'Yazipane/icon'
New-Item -ItemType Directory -Force $outDir | Out-Null

function New-Color([string]$hex, [int]$alpha = 255) {
    $c = [System.Drawing.ColorTranslator]::FromHtml($hex)
    [System.Drawing.Color]::FromArgb($alpha, $c.R, $c.G, $c.B)
}

function New-RoundedPath([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $d = [Math]::Max(0.5, [Math]::Min($r * 2, [Math]::Min($w, $h)))
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $p
}

function Fill-Rounded($g, $brush, [float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-RoundedPath $x $y $w $h $r
    $g.FillPath($brush, $p)
    $p.Dispose()
}

function Draw-Icon([int]$size) {
    $bmp = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = $size / 256.0
    $bg = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
        [System.Drawing.PointF]::new(0, 0), [System.Drawing.PointF]::new(0, $size),
        (New-Color '#364466'), (New-Color '#141b2e'))
    Fill-Rounded $g $bg (3*$s) (3*$s) (250*$s) (250*$s) (56*$s)
    $bg.Dispose()

    # A bold terminal prompt and a folder, with no window chrome.
    $pen = [System.Drawing.Pen]::new((New-Color '#91c0ff'), [Math]::Max(1.3, 15*$s))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $prompt = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new(46*$s,91*$s),
        [System.Drawing.PointF]::new(75*$s,120*$s),
        [System.Drawing.PointF]::new(46*$s,149*$s))
    $g.DrawLines($pen, $prompt)
    $pen.Dispose()
    $folder = [System.Drawing.SolidBrush]::new((New-Color '#c0adff'))
    Fill-Rounded $g $folder (118*$s) (80*$s) (45*$s) (27*$s) (8*$s)
    Fill-Rounded $g $folder (118*$s) (95*$s) (92*$s) (71*$s) (12*$s)
    $folder.Dispose()
    $g.Dispose()
    $bmp
}

# Write a multi-resolution Windows icon.
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$pngs = foreach ($size in $sizes) {
    $bmp = Draw-Icon $size
    $ms = [System.IO.MemoryStream]::new()
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    if ($size -eq 256) {
        $bmp.Save((Join-Path $outDir 'yazipane-256.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    }
    $bmp.Dispose()
    , $ms.ToArray()
}

$ico = [System.IO.MemoryStream]::new()
$w = [System.IO.BinaryWriter]::new($ico)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)   # ICONDIR
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {                                    # ICONDIRENTRY
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($png in $pngs) { $w.Write($png) }
$w.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $outDir 'yazipane.ico'), $ico.ToArray())
$w.Dispose()

# 確認用: 小さいサイズを並べたプレビュー
$preview = [System.Drawing.Bitmap]::new(640, 272)
$pg = [System.Drawing.Graphics]::FromImage($preview)
$pg.Clear((New-Color '#e5e5e5'))
$x = 8
foreach ($size in 256, 128, 64, 48, 32, 24, 16) {
    $b = Draw-Icon $size
    $pg.DrawImage($b, $x, 8, $size, $size)
    $x += $size + 8
    $b.Dispose()
}
$pg.Dispose()
$preview.Save((Join-Path $outDir 'preview.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$preview.Dispose()

Write-Host "wrote $(Join-Path $outDir 'yazipane.ico')"
