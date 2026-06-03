# Generates the branded app_icon.ico — multi-resolution (16/32/48/64/128/256).
#
# Re-run after a brand change to refresh the embedded Windows icon:
#   pwsh -File windows/runner/resources/generate_icon.ps1
#   flutter build windows
#
# Design — matches the in-app sidebar logo (root_shell.dart _SidebarBrand):
#   * rounded square, gradient primary → tertiary (purple → cyan)
#   * white Material Icons `psychology_alt` glyph centered
#   * subtle inner highlight along the top for depth
#
# We pull the glyph from Flutter's bundled MaterialIcons-Regular.otf so
# the taskbar / task-manager icon is pixel-true to what the user sees
# in the sidebar.

Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'

# ----- Locate the Material Icons font ----------------------------------
# Flutter copies it into build/flutter_assets/fonts on every build.
$buildAssets = Join-Path $PSScriptRoot '..\..\..\build\flutter_assets\fonts\MaterialIcons-Regular.otf'
$debugAssets = Join-Path $PSScriptRoot '..\..\..\build\windows\x64\runner\Debug\data\flutter_assets\fonts\MaterialIcons-Regular.otf'
$releaseAssets = Join-Path $PSScriptRoot '..\..\..\build\windows\x64\runner\Release\data\flutter_assets\fonts\MaterialIcons-Regular.otf'
$fontPath = $null
foreach ($p in @($buildAssets, $debugAssets, $releaseAssets)) {
    if (Test-Path -LiteralPath $p) { $fontPath = (Resolve-Path -LiteralPath $p).Path; break }
}
if (-not $fontPath) {
    throw "MaterialIcons-Regular.otf not found in build folders. Run 'flutter build windows' (or 'flutter pub get && flutter build bundle') first, then re-run this script."
}

# Load the font into a private collection so System.Drawing can use it
# without installing it system-wide.
$privateFonts = New-Object System.Drawing.Text.PrivateFontCollection
$privateFonts.AddFontFile($fontPath)
$materialFamily = $privateFonts.Families[0]

# ----- Master bitmap ---------------------------------------------------
# Render once at 256 px, then downscale per ICO entry. Single high-res
# master gives noticeably better small-size results than re-rendering
# at each size.
$master = 256
$bmp = New-Object System.Drawing.Bitmap $master, $master
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.Clear([System.Drawing.Color]::Transparent)

# ----- Rounded square --------------------------------------------------
# Radius matches the in-app logo's 10 px on 34 px scaled up to 256.
$radius = 56
$diameter = $radius * 2
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddArc(0, 0, $diameter, $diameter, 180, 90)
$path.AddArc($master - $diameter, 0, $diameter, $diameter, 270, 90)
$path.AddArc($master - $diameter, $master - $diameter, $diameter, $diameter, 0, 90)
$path.AddArc(0, $master - $diameter, $diameter, $diameter, 90, 90)
$path.CloseFigure()

# Brand gradient — primary → tertiary, diagonal TL→BR. Colors match
# Palette.dark from lib/theme/theme.dart so the taskbar icon reads as
# the dark-theme variant of the in-app logo.
$rect = New-Object System.Drawing.Rectangle 0, 0, $master, $master
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $rect,
    [System.Drawing.Color]::FromArgb(255, 157, 124, 255),   # primary  (#9D7CFF)
    [System.Drawing.Color]::FromArgb(255,  77, 212, 240),   # tertiary (#4DD4F0)
    [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal)
$g.FillPath($brush, $path)

# Subtle top highlight — matches the boxShadow + light feel of the
# in-app logo. Soft white sweep clipped to the rounded top.
$highlightPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$highlightPath.AddArc(0, 0, $diameter, $diameter, 180, 90)
$highlightPath.AddArc($master - $diameter, 0, $diameter, $diameter, 270, 90)
$midY = [single]($master * 0.4)
$highlightPath.AddLine([single]$master, $midY, [single]0, $midY)
$highlightPath.CloseFigure()
$hlHeight = [int]($master * 0.45)
$hlRect = New-Object System.Drawing.Rectangle (0), (0), ([int]$master), ($hlHeight)
$highlightBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $hlRect,
    [System.Drawing.Color]::FromArgb(50, 255, 255, 255),
    [System.Drawing.Color]::FromArgb(0,  255, 255, 255),
    [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
$g.FillPath($highlightBrush, $highlightPath)

# ----- Material Icons glyph --------------------------------------------
# Codepoint 0xF0873 is `psychology_alt` (see Flutter's
# packages/flutter/lib/src/material/icons.dart). It sits above the BMP
# so we convert from UTF-32 to get the right surrogate pair for .NET.
$glyph = [System.Char]::ConvertFromUtf32(0xF0873)

# Font sized so the glyph fills ~60% of the canvas with breathing room
# inside the rounded square — same proportion as the 20 px icon on the
# 34 px in-app container.
$font = New-Object System.Drawing.Font $materialFamily, 160, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
$sf = New-Object System.Drawing.StringFormat
$sf.Alignment = [System.Drawing.StringAlignment]::Center
$sf.LineAlignment = [System.Drawing.StringAlignment]::Center

# Drop shadow for depth against the gradient.
$shadowRect = New-Object System.Drawing.RectangleF 0, 6, $master, $master
$shadowBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 0, 0, 0))
$g.DrawString($glyph, $font, $shadowBrush, $shadowRect, $sf)

# Main glyph in solid white.
$textRect = New-Object System.Drawing.RectangleF 0, 0, $master, $master
$g.DrawString($glyph, $font, [System.Drawing.Brushes]::White, $textRect, $sf)

$g.Dispose()

# ----- Pack into ICO ---------------------------------------------------
# Every embedded size is a PNG (valid since Vista) which keeps the
# file small and lets the OS pick the right resolution per surface
# (16 in taskbar, 32 in alt-tab, 256 in shortcuts).
$sizes = @(16, 32, 48, 64, 128, 256)
$pngs = @{}
foreach ($s in $sizes) {
    $resized = New-Object System.Drawing.Bitmap $s, $s
    $rg = [System.Drawing.Graphics]::FromImage($resized)
    $rg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $rg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $rg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $rg.DrawImage($bmp, 0, 0, $s, $s)
    $rg.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $resized.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngs[$s] = $ms.ToArray()
    $ms.Dispose()
    $resized.Dispose()
}
$bmp.Dispose()

# ICO format:
#   ICONDIR (6 bytes): reserved=0, type=1 (ICO), count
#   ICONDIRENTRY (16 bytes per image): width, height, palette, reserved,
#     planes, bitsPerPixel, dataSize, dataOffset
#   <image bytes...>
$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $out

$bw.Write([uint16]0)
$bw.Write([uint16]1)
$bw.Write([uint16]$sizes.Count)

$dataOffset = 6 + 16 * $sizes.Count
foreach ($s in $sizes) {
    $bytes = $pngs[$s]
    # 256 is encoded as 0 in the byte fields (ICO format quirk).
    $w = [byte]($(if ($s -ge 256) { 0 } else { $s }))
    $h = [byte]($(if ($s -ge 256) { 0 } else { $s }))
    $bw.Write($w)
    $bw.Write($h)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]$bytes.Length)
    $bw.Write([uint32]$dataOffset)
    $dataOffset += $bytes.Length
}
foreach ($s in $sizes) {
    $bw.Write($pngs[$s])
}
$bw.Flush()

$icoPath = Join-Path $PSScriptRoot 'app_icon.ico'
[System.IO.File]::WriteAllBytes($icoPath, $out.ToArray())
$bw.Dispose()
$out.Dispose()

Write-Output "Wrote $icoPath ($([System.IO.File]::ReadAllBytes($icoPath).Length) bytes, $($sizes.Count) sizes, font: $fontPath)"
