# Render actual production code without launching a desktop window.
param([string]$PreviewPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repo = Split-Path $PSScriptRoot -Parent
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'clawd-pet.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
# The C# helpers (ClawdFrames: frame cache) live in src\ClawdNative.cs. No disk cache here.
if (-not ('ClawdFrames' -as [type])) { Add-Type -Path (Join-Path $repo 'src\ClawdNative.cs') -ReferencedAssemblies System.Drawing, System.Windows.Forms }
$fnNames = @('Render-Pet', 'Get-GifSrc', 'Get-GifPlacement', 'Get-CookIntroPlacement', 'Add-Anim', 'Set-AnimPace', 'Get-AnimFrame', 'Apply-Pulse', 'Push-Scale')
foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $fnNames }, $true)) {
    Invoke-Expression $fn.Extent.Text
}
$layout = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in @('$script:destH', '$script:margin', '$script:formW', '$script:crabH') }, $true)
$script:gifStates = @{}; $script:gifSrc = @{}
# Load the production source rectangles, scale nudges and head anchors.
function Test-TopLevel($n) {
    for ($p = $n.Parent; $null -ne $p; $p = $p.Parent) { if ($p -is [Management.Automation.Language.FunctionDefinitionAst]) { return $false } }
    return $true
}
$setup = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and ($n.Left.Extent.Text -like '$script:gif*') -and (Test-TopLevel $n) }, $true)
$assetDir = Join-Path $repo 'assets'
$script:frameMs = 1000 / 60.0; $script:halfFrameMs = $script:frameMs / 2
foreach ($assignment in $setup) {
    if ($assignment.Left.Extent.Text -notin @('$script:gifHeadX', '$script:gifHeadTop')) { Invoke-Expression $assignment.Extent.Text }
}
$cookIntroPath = Join-Path $assetDir 'Clawd-CookIntro.gif'
$script:globalT = 0.0; $script:pulseAt = -1000.0; $script:nowMs = 0.0
$still = [Drawing.Image]::FromFile((Join-Path $repo 'assets\Clawd-Still.png'))
$sheet = New-Object Drawing.Bitmap 990,680
$sg = [Drawing.Graphics]::FromImage($sheet)
$sg.Clear([Drawing.Color]::FromArgb(35,35,38))
$sg.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$font = New-Object Drawing.Font 'Segoe UI',14
try {
    foreach ($size in @(44,56,68,80,120,200)) {
        $script:destW = $size
        foreach ($assignment in $layout) { Invoke-Expression $assignment.Extent.Text }
        # Build the frame cache exactly like Build-FrameCache does for these poses
        $script:anims = @{}
        foreach ($st in @('dance', 'work', 'cook')) {
            $p = Get-GifPlacement $st $script:gifSrc[$st]
            Add-Anim $st $script:gifStates[$st] $script:gifSrc[$st] $p[0] $p[1] $p[2] $p[3] $true
            $script:anims[$st].hx = $p[4]; $script:anims[$st].ht = $p[5]
        }
        $p = Get-CookIntroPlacement
        Add-Anim 'cook-intro' $cookIntroPath $p[6] $p[0] $p[1] $p[2] $p[3] $true
        $script:anims['cook-intro'].hx = $p[4]; $script:anims['cook-intro'].ht = $p[5]
        $column = 0
        foreach ($pose in @('idle','intro first','intro last','cook','work','dance')) {
            $bmp = New-Object Drawing.Bitmap $script:formW,$script:destH
            $g = [Drawing.Graphics]::FromImage($bmp)
            try {
                if ($pose -eq 'idle') {
                    $g.DrawImage($still, (New-Object Drawing.Rectangle $script:margin,0,$size,$script:destH), (New-Object Drawing.Rectangle 736,351,1200,1499), [Drawing.GraphicsUnit]::Pixel)
                } else {
                    $script:state = if ($pose -like 'intro*') { 'cook-intro' } else { $pose }
                    $script:nowMs = if ($pose -eq 'intro last') { 1e6 } else { 0.0 }   # past the end = held on the last frame
                    Render-Pet $g
                    if ($pose -in @('cook','work','intro first','intro last') -and [Math]::Abs($script:gifHeadX - $script:formW / 2.0) -gt 1) {
                        throw "$pose head shifts away from centre at size $size"
                    }
                }
                # A clipped prop would leave visible pixels on a side of the window.
                for ($y = 0; $y -lt $bmp.Height; $y++) {
                    if ($bmp.GetPixel(0,$y).A -gt 0 -or $bmp.GetPixel(($bmp.Width-1),$y).A -gt 0) { throw "$pose clipped at size $size" }
                }
                if ($size -eq 80 -and $PreviewPath) {
                    $x = ($column % 3) * 330; $y0 = [int][Math]::Floor($column / 3) * 340
                    $sg.DrawString($pose,$font,[Drawing.Brushes]::White,$x+10,$y0+5)
                    $sg.DrawImage($bmp, ($x + [int]((330-$bmp.Width*2)/2)), ($y0+35), ($bmp.Width*2), ($bmp.Height*2))
                }
            } finally { $g.Dispose(); $bmp.Dispose() }
            $column++
        }
        foreach ($a in $script:anims.Values) { foreach ($b in $a.frames) { $b.Dispose() } }
        Write-Host "PASS size $size`: character anchors centred; pan, laptop and poses fit"
    }
    if ($PreviewPath) { $sheet.Save($PreviewPath); Write-Host "Preview: $PreviewPath" }
} finally {
    $font.Dispose(); $sg.Dispose(); $sheet.Dispose(); $still.Dispose()
}
