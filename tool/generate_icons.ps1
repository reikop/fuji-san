# Generate the original geometric Fuji San mark. No external artwork or fonts.
Add-Type -AssemblyName System.Drawing
$project = Split-Path -Parent $PSScriptRoot
function Write-IconPng([string]$Path, [int]$Size) {
    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.ColorTranslator]::FromHtml('#315B46'))
    $scale = $Size / 1024.0
    $graphics.ScaleTransform($scale, $scale)
    $cream = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#F5F3EC'))
    $sun = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#D7A779'))
    $green = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#315B46'))
    $graphics.FillEllipse($sun, 640, 215, 160, 160)
    $points = [System.Drawing.PointF[]]@([System.Drawing.PointF]::new(135,755), [System.Drawing.PointF]::new(444,285), [System.Drawing.PointF]::new(558,285), [System.Drawing.PointF]::new(880,755))
    $graphics.FillPolygon($cream, $points)
    $cutout = [System.Drawing.PointF[]]@([System.Drawing.PointF]::new(352,500), [System.Drawing.PointF]::new(444,545), [System.Drawing.PointF]::new(500,487), [System.Drawing.PointF]::new(575,540), [System.Drawing.PointF]::new(661,500), [System.Drawing.PointF]::new(814,715), [System.Drawing.PointF]::new(200,715))
    $graphics.FillPolygon($green, $cutout)
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose(); $cream.Dispose(); $sun.Dispose(); $green.Dispose()
}
foreach ($platform in @('ios','macos')) {
    $folder = Join-Path $project "$platform/Runner/Assets.xcassets/AppIcon.appiconset"
    $catalog = Get-Content (Join-Path $folder 'Contents.json') -Raw | ConvertFrom-Json
    foreach ($entry in $catalog.images) {
        if ($entry.filename) {
            $size = [int]([double]($entry.size.Split('x')[0]) * [double]($entry.scale.TrimEnd('x')))
            Write-IconPng (Join-Path $folder $entry.filename) $size
        }
    }
}
foreach ($pair in @(@('mdpi',48),@('hdpi',72),@('xhdpi',96),@('xxhdpi',144),@('xxxhdpi',192))) {
    Write-IconPng (Join-Path $project "android/app/src/main/res/mipmap-$($pair[0])/ic_launcher.png") $pair[1]
}
$pngPath = Join-Path $project '.tools/icon-256.png'
Write-IconPng $pngPath 256
$png = [IO.File]::ReadAllBytes($pngPath)
$stream = [IO.File]::Create((Join-Path $project 'windows/runner/resources/app_icon.ico'))
$writer = New-Object IO.BinaryWriter($stream)
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]1)
$writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([byte]0)
$writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]$png.Length); $writer.Write([uint32]22); $writer.Write($png)
$writer.Dispose(); $stream.Dispose()
