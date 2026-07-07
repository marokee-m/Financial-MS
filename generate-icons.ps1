Add-Type -AssemblyName System.Drawing

function New-HeartIcon {
    param(
        [int]$Size,
        [string]$OutPath,
        [bool]$Squircle = $true
    )

    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear([System.Drawing.Color]::Transparent)

    # ---- squircle background path (matches rounded-2xl look) ----
    $radius = [double]$Size * 0.225
    $rect = New-Object System.Drawing.RectangleF 0, 0, $Size, $Size
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
    $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()

    # ---- gradient fill: Tailwind from-pink-500 (#ec4899) to-rose-400 (#fb7185), diagonal ----
    $colorStart = [System.Drawing.Color]::FromArgb(255, 0xEC, 0x48, 0x99)
    $colorEnd   = [System.Drawing.Color]::FromArgb(255, 0xFB, 0x71, 0x85)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point(0,0)),
        (New-Object System.Drawing.Point($Size,$Size)),
        $colorStart, $colorEnd
    )
    $g.FillPath($brush, $path)

    # ---- subtle glossy highlight top-left for depth ----
    $glossPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $glossPath.AddEllipse(-$Size*0.15, -$Size*0.25, $Size*1.0, $Size*0.9)
    $glossBrush = New-Object System.Drawing.Drawing2D.PathGradientBrush($glossPath)
    $glossBrush.CenterColor = [System.Drawing.Color]::FromArgb(60, 255, 255, 255)
    $glossBrush.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 255, 255, 255))
    $oldClip = $g.Clip
    $g.SetClip($path)
    $g.FillPath($glossBrush, $glossPath)
    $g.Clip = $oldClip

    # ---- heart shape (parametric heart curve), filled white with soft look ----
    $cx = $Size / 2.0
    $cy = $Size / 2.0 + $Size * 0.02
    $scale = $Size * 0.021
    $pts = New-Object System.Collections.Generic.List[System.Drawing.PointF]
    $steps = 240
    for ($i = 0; $i -le $steps; $i++) {
        $t = ([double]$i / $steps) * 2 * [Math]::PI
        $hx = 16 * [Math]::Pow([Math]::Sin($t), 3)
        $hy = 13 * [Math]::Cos($t) - 5 * [Math]::Cos(2*$t) - 2 * [Math]::Cos(3*$t) - [Math]::Cos(4*$t)
        $px = $cx + $hx * $scale
        $py = $cy - $hy * $scale
        $pts.Add((New-Object System.Drawing.PointF($px, $py)))
    }

    # soft shadow behind heart for depth
    $shadowBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(50, 0, 0, 0))
    $g.TranslateTransform(0, $Size * 0.012)
    $g.FillPolygon($shadowBrush, $pts.ToArray())
    $g.ResetTransform()

    $heartBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.FillPolygon($heartBrush, $pts.ToArray())

    # small glossy highlight dot on the heart (upper-left lobe)
    $hlBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(160, 255, 255, 255))
    $hlSize = $Size * 0.09
    $g.FillEllipse($hlBrush, $cx - $Size*0.135, $cy - $Size*0.12, $hlSize, $hlSize * 0.7)

    $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
    Write-Output "Wrote $OutPath ($Size x $Size)"
}

$outDir = Join-Path (Get-Location) "icons"

New-HeartIcon -Size 512 -OutPath (Join-Path $outDir "icon-512.png")
New-HeartIcon -Size 192 -OutPath (Join-Path $outDir "icon-192.png")
New-HeartIcon -Size 180 -OutPath (Join-Path $outDir "apple-touch-icon.png")
New-HeartIcon -Size 32  -OutPath (Join-Path $outDir "favicon-32.png")
New-HeartIcon -Size 16  -OutPath (Join-Path $outDir "favicon-16.png")
