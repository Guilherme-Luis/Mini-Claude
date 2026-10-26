# Clawd Pet - the official Claude crab mascot living on your desktop, always on top of other windows.
# Uses the official animation assets from claude.ai (assets\ folder).
#   Eyes        : always follow the cursor; blinks every few seconds
#   Cursor near : stops walking and watches; on touch -> hearts and rosy cheeks (love)
#   Typing      : "?" bubble + confused wobble for a few seconds
#   Left click  : wave / jump / wiggle / dance (random)
#   Picked up   : claw hooks onto the cursor - dangles, swings, and PANICS
#                 (eyes bulge, pupils tremble, sweat, shaking)
#   Released    : falls, squashes, then jumps for joy
#   On its own  : dances, coffee breaks, ponders, stretches, sneezes, naps (bubble) or dozes (Zz...)
#   Agent watch : acts out what Claude is doing (thinking -> thought cloud, reading -> magnifier,
#                 else working/cooking); celebrates with confetti when Claude is done
#   Right click : every animation + quit
#   Tray icon   : stand-by / wake up, animations, colour, size, sound, start with Windows (optionally
#                 in stand-by), quit. Waking up: he peeks from a screen edge and walks out.
# Run with -TestBlink to test sprite generation only (no window).
# -PerfLog <file.json>: every 5 s, writes the frame rate and the script's cost per frame for each pose.
# Runs as a script (start-clawd.vbs) or inside Clawd.exe (build.ps1), which hosts this same file.

param([switch]$TestBlink, [string]$WatchLog, [switch]$Standby, [string]$PerfLog)   # -Standby: start asleep (tray icon only)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Only one Clawd allowed. An "abandoned" mutex (old owner killed) still counts as acquired.
$script:mutex = New-Object System.Threading.Mutex($false, 'ClawdPetMutex')
if (-not $TestBlink) {
    try {
        if (-not $script:mutex.WaitOne(0, $false)) { exit }
    } catch [System.Threading.AbandonedMutexException] { }
}

# C# helpers (src\ClawdNative.cs: frame cache, layered windows, frame clock, Win32 calls - see each
# class comment). Clawd.exe has them compiled in. Run as a script they are compiled once and kept as a
# DLL in the cache folder, so a launch only waits for the C# compiler after the file changes.
$script:dataDir = Join-Path $env:LOCALAPPDATA 'ClawdPet'
if (-not ('ClawdFrames' -as [type])) {
    $nativeSrc = Join-Path $PSScriptRoot 'src\ClawdNative.cs'
    $nativeRefs = @('System.Drawing', 'System.Windows.Forms')
    try {
        $nativeDll = Join-Path $script:dataDir ('cache\ClawdNative-' + (Get-FileHash $nativeSrc -Algorithm MD5).Hash + '.dll')
        if (-not (Test-Path $nativeDll)) {
            [void][IO.Directory]::CreateDirectory((Split-Path $nativeDll))
            $tmpDll = $nativeDll -replace '\.dll$', ".$PID.dll"
            Add-Type -Path $nativeSrc -ReferencedAssemblies $nativeRefs -OutputAssembly $tmpDll -OutputType Library
            Move-Item $tmpDll $nativeDll -Force
        }
        Add-Type -Path $nativeDll
    } catch {
        if (-not ('ClawdFrames' -as [type])) { Add-Type -Path $nativeSrc -ReferencedAssemblies $nativeRefs }   # no writable cache: compile in memory
    }
}
[ClawdCache]::Dir = Join-Path $script:dataDir 'cache'

# Custom chime generator — sine-wave WAV cached to temp file (fast on 2nd+ launch)
$script:chimeWav = Join-Path $env:TEMP 'clawd-chime.wav'
if (-not (Test-Path $script:chimeWav)) {
    $sr = 22050
    $notes = @(523, 659, 784, 1047); $durs = @(80, 80, 80, 180); $gapSamp = $sr * 25 / 1000
    $totalSamp = 0; for ($i = 0; $i -lt $notes.Count; $i++) { $totalSamp += [long]($sr * $durs[$i] / 1000) + $gapSamp }
    $raw = New-Object double[] $totalSamp; $pos = 0
    for ($n = 0; $n -lt $notes.Count; $n++) {
        $freq = $notes[$n]; $samples = [long]($sr * $durs[$n] / 1000)
        for ($s = 0; $s -lt $samples; $s++) { $raw[$pos++] = [Math]::Sin(2 * [Math]::PI * $freq * $s / $sr) * 0.35 }
        for ($s = 0; $s -lt $gapSamp; $s++) { $raw[$pos++] = 0 }
    }
    $dataBytes = [int]($totalSamp * 2)
    $fs = [System.IO.File]::Create($script:chimeWav)
    $w = New-Object System.IO.BinaryWriter($fs)
    $w.Write([char[]]('RIFF')); $w.Write(36 + $dataBytes)
    $w.Write([char[]]('WAVE')); $w.Write([char[]]('fmt ')); $w.Write(16)
    $w.Write([uint16]1); $w.Write([uint16]1); $w.Write($sr); $w.Write($sr * 2)
    $w.Write([uint16]2); $w.Write([uint16]16)
    $w.Write([char[]]('data')); $w.Write($dataBytes)
    for ($i = 0; $i -lt $totalSamp; $i++) { $w.Write([int16]($raw[$i] * 32767)) }
    $w.Close(); $fs.Close()
    $raw = $null
}
$script:chimePlayer = New-Object System.Media.SoundPlayer($script:chimeWav)
$script:chimePlayer.Load()


# ---------- Config (clawd.json) ----------
$script:cfg = $null
$cfgPath = Join-Path $PSScriptRoot 'clawd.json'
if (Test-Path $cfgPath) {
    try { $script:cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json } catch { $script:cfg = $null }
}
function Get-Cfg([string]$path, $default) {
    $node = $script:cfg
    foreach ($k in $path.Split('.')) {
        if ($null -eq $node) { return $default }
        $prop = $node.PSObject.Properties[$k]
        if ($null -eq $prop) { return $default }
        $node = $prop.Value
    }
    if ($null -eq $node) { return $default }
    return $node
}

$script:cfgSpeed  = [Math]::Max(0.2, [Math]::Min(4.0, [double](Get-Cfg 'walkSpeed' 1.0)))
$script:cfgGrav   = [Math]::Max(0.2, [Math]::Min(3.0, [double](Get-Cfg 'gravity' 1.0)))
$script:idleMinT  = [int]([Math]::Max(2.0, [double](Get-Cfg 'idleSecondsMin' 5)) * 62.5)
$script:idleMaxT  = [int]([Math]::Max(3.0, [double](Get-Cfg 'idleSecondsMax' 10)) * 62.5)
if ($script:idleMaxT -lt ($script:idleMinT + 100)) { $script:idleMaxT = $script:idleMinT + 100 }
$script:blinkMinT = [int]([Math]::Max(1.0, [double](Get-Cfg 'blinkSecondsMin' 2.5)) * 62.5)
$script:blinkMaxT = [int]([Math]::Max(1.5, [double](Get-Cfg 'blinkSecondsMax' 5.5)) * 62.5)
if ($script:blinkMaxT -lt ($script:blinkMinT + 30)) { $script:blinkMaxT = $script:blinkMinT + 30 }
$script:featEyes  = [bool](Get-Cfg 'features.eyeTracking' $true)
$script:featPlat  = [bool](Get-Cfg 'features.windowPlatforms' $true)
$script:featType  = [bool](Get-Cfg 'features.typingReaction' $true)
$script:featLurk  = [bool](Get-Cfg 'features.edgeLurking' $true)
$script:featSys   = [bool](Get-Cfg 'features.systemAwareness' $true)
$script:featClimb = [bool](Get-Cfg 'features.climbing' $true)
$script:featMisch = [bool](Get-Cfg 'features.mischief' $true)
$script:featClaudeWatch = [bool](Get-Cfg 'features.claudeWatch' $true)
$script:featCodexWatch = [bool](Get-Cfg 'features.codexWatch' $false)
$script:featSound = [bool](Get-Cfg 'features.sound' $true)
$script:featWatch = [bool](Get-Cfg 'features.agentWatch' $true) -and ($script:featClaudeWatch -or $script:featCodexWatch)
. (Join-Path $PSScriptRoot 'tools\agent-state.ps1')
$script:codexWatchFile = Join-Path $env:TEMP "clawd-codex-$PID.json"
$script:codexWatcher = $null
$script:watchSource = ''
$script:termCmd   = [string](Get-Cfg 'terminal.command' 'clawd --hello')
$script:termOut   = [string](Get-Cfg 'terminal.output' 'Hello, World!')

# ---------- Official assets ----------
. (Join-Path $PSScriptRoot 'tools\asset-validation.ps1')
$assetDir = Join-Path $PSScriptRoot 'assets'
# A full decode per asset on every start was slow; a file that already passed (same size and time
# stamp) is remembered in the cache and not checked again.
function Test-AssetOk([string]$path) {
    if ([ClawdCache]::IsKnownGood($path)) { return $true }
    if (Test-ClawdAsset $path) { [ClawdCache]::MarkGood($path); return $true }
    return $false
}
$neededAssets = @('Clawd-Still.png', 'Clawd-CrabWalking.gif', 'Clawd-Waving.gif', 'Clawd-JumpingHappy.gif', 'Clawd-Lurking.gif',
                  'Clawd-Dancing.gif', 'Clawd-Working.gif', 'Clawd-Loading.gif', 'Clawd-Cooking.gif', 'Clawd-CookIntro.gif')
$missingAssets = @($neededAssets | Where-Object { -not (Test-AssetOk (Join-Path $assetDir $_)) })
if ($missingAssets.Count -gt 0) {
    # Missing or invalid assets -> download again before any image is loaded.
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'download-assets.ps1') | Out-Null
    $missingAssets = @($neededAssets | Where-Object { -not (Test-AssetOk (Join-Path $assetDir $_)) })
    if ($missingAssets.Count -gt 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Clawd's assets are missing or invalid:`n$($missingAssets -join "`n")`n`nRun download-assets.ps1 manually or download a fresh copy of the repo, then try again.",
            'Clawd Pet', 'OK', 'Warning')
        exit
    }
}
# Images are only decoded when their frames are not in the cache yet (see ClawdCache), so these are paths
$script:stillPath     = Join-Path $assetDir 'Clawd-Still.png'
$script:lurkPath      = Join-Path $assetDir 'Clawd-Lurking.gif'
$script:cookIntroPath = Join-Path $assetDir 'Clawd-CookIntro.gif'
# Claude Watch "loading" indicator: the official animated spark, replacing the old hand-drawn
# throb. Animates continuously; only painted (faded) into the status bubble while it is shown.
# Its frames are cached at bubble size once the status font is known (Render-Status).
$script:loadPath = Join-Path $assetDir 'Clawd-Loading.gif'
# Stepped on the display-frame grid so it turns evenly (a little faster than its native ~4s/loop)
$script:loadFrameEvery = 4   # display frames per spark frame (60 Hz: 15 fps; lower = faster)

# Standalone GIFs: already cropped to the character (not the 2750x1850 canvas), so they are
# drawn WHOLE - scaled to fit the window and bottom-aligned - instead of via $script:srcRect.
# Their frames are pre-scaled into the frame cache (Build-FrameCache) at the placement below.
# $gifSrc holds each GIF's character-content sub-rectangle so the transparent padding around
# him is cropped out and he renders as large as the idle sprite. Bounds were measured from the
# shipped assets; if an asset's canvas size differs (re-exported), fall back to the full frame.
function Get-GifSrc([string]$path, [int]$cw, [int]$ch, [int]$x, [int]$y, [int]$w, [int]$h) {
    $sz = [ClawdFrames]::ImageSize($path)
    if ($sz.Width -eq $cw -and $sz.Height -eq $ch) { return [System.Drawing.Rectangle]::new($x, $y, $w, $h) }
    return [System.Drawing.Rectangle]::new(0, 0, $sz.Width, $sz.Height)
}
$script:gifStates = @{}; $script:gifSrc = @{}
$script:gifStates['dance'] = Join-Path $assetDir 'Clawd-Dancing.gif'; $script:gifSrc['dance'] = (Get-GifSrc $script:gifStates['dance'] 267 230 14 18 226 209)
$script:gifStates['work']  = Join-Path $assetDir 'Clawd-Working.gif'; $script:gifSrc['work']  = (Get-GifSrc $script:gifStates['work']  438 230 22 24 372 205)
$script:gifStates['cook']  = Join-Path $assetDir 'Clawd-Cooking.gif'; $script:gifSrc['cook']  = (Get-GifSrc $script:gifStates['cook']  540 368  0 14 482 347)
# Extra animations made by tools\make-animations.ps1 (optional: an action whose GIF is missing is
# simply not offered). They draw Clawd as a puppet on a 140x120 canvas with his 80x100 sprite grid
# at (30,20), so Build-FrameCache places them to line up exactly with the idle Clawd.
$script:extraAnims = [ordered]@{
    'coffee' = 'Clawd-Coffee.gif'; 'magnifier' = 'Clawd-Magnifier.gif'; 'celebrate' = 'Clawd-Celebrate.gif'; 'love' = 'Clawd-Love.gif'
    'sneeze' = 'Clawd-Sneeze.gif'; 'stretch' = 'Clawd-Stretch.gif'; 'nap' = 'Clawd-Nap.gif'
}
$script:extraPaths = [ordered]@{}
foreach ($k in $script:extraAnims.Keys) {
    $p = Join-Path $assetDir $script:extraAnims[$k]
    if (Test-AssetOk $p) { $script:extraPaths[$k] = $p }
}
# Per-GIF size nudge on top of the idle-match scale (1.0 = match idle footprint). Cooking's
# pan reaches out to the side, inflating its bounds, so its crab reads small - bump it to fill
# the window. Clamped to the window afterwards, so it never clips.
$script:gifScale = @{ 'cook' = 1.4 }
# Head anchor (centre x, top y) in each GIF's OWN pixel coords. These wide GIFs put Clawd's body
# off-centre (the laptop / the reaching pan), so the status bubble is centred over this point
# instead of the window centre - keeping it right above his head, not the middle of the GIF.
$script:gifHead = @{ 'work' = @(134, 26); 'cook' = @(307, 15) }

# Crab area inside the 2750x1850 canvas: x 736..1935, y 351..1850 (feet at the bottom)
$script:srcRect = [System.Drawing.Rectangle]::new(736, 351, 1200, 1499)

if ($TestBlink) {
    $still = New-Object System.Drawing.Bitmap($script:stillPath)
    $blink = [ClawdFx]::MakeBlink($still, 736, 1000, 1200, 850)
    $crop = [System.Drawing.Rectangle]::new(900, 1000, 900, 500)
    $cmp = New-Object System.Drawing.Bitmap(900, 1000)
    $g = [System.Drawing.Graphics]::FromImage($cmp)
    $g.DrawImage($still, ([System.Drawing.Rectangle]::new(0, 0, 900, 500)), $crop, [System.Drawing.GraphicsUnit]::Pixel)
    $g.DrawImage($blink, ([System.Drawing.Rectangle]::new(0, 500, 900, 500)), $crop, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    $cmp.Save("$env:TEMP\clawd-blink-test.png")
    $cmp.Dispose()
    Write-Output "saved: $env:TEMP\clawd-blink-test.png"
    Write-Output "eyes: $(([ClawdFx]::FindEyes($still, 736, 1000, 1200, 850)) -join ',')"
    $blink.Dispose(); $still.Dispose()
    exit
}

# ---------- Display size ----------
$script:destW  = [Math]::Max(40, [Math]::Min(200, [int](Get-Cfg 'size' 80)))
$script:destH  = [int](1499 / 1200 * $script:destW)   # ~100
# Room for the pan/laptop while keeping the character centred in every pose.
$script:margin = [int]($script:destW * 0.4)
$script:formW  = $script:destW + 2 * $script:margin
$script:crabH  = [int](800 * $script:destW / 1200)   # body height ~53 px
# Square window while climbing: must fit the sprite at any rotation.
# Farthest distance from body center = side of head (destH - crabH/2), plus a safe margin.
$script:climbSide = [int](2 * (([int](1499 / 1200 * $script:destW)) - $script:crabH / 2.0 + 10))
$script:scale  = $script:destW / 1200.0

# ---------- Frame pacing ----------
# One display frame: the multiple of the monitor's refresh period closest to 60 fps. Every tick of
# the clock and every GIF frame (Snap) lands on this grid. Logic speeds are in ticks of tickMs.
$script:tickMs  = 27.8
$script:frameUs = 16667
$hz = [ClawdWin]::RefreshRate()
if ($hz -ge 50 -and $hz -le 500) { $script:frameUs = [int](1000000.0 * [Math]::Max(1, [Math]::Round($hz / 60.0)) / $hz) }
$script:frameMs = $script:frameUs / 1000.0
$script:halfFrameMs = $script:frameMs / 2   # GIF frames are sampled mid-frame: timer jitter never flips one
# Leg step = a whole number of 30 fps script ticks (~133 ms), so the stepping rhythm is exactly even
$script:legStepK = [Math]::Max(1, [Math]::Round(133.3 / (2 * $script:frameMs))) * 2 * $script:frameMs / $script:tickMs

# ---------- Sprite: eyes, blink, legs (cached at the display size) ----------
# The eyes are erased from the still sprite (they are redrawn live, following the cursor) and a blink
# variant is made; both are scaled to the display size and cached with the eye and leg positions.
$fr = $null; $meta = $null
$stillKey = [ClawdCache]::Key($script:stillPath, 'still', $script:destW, $script:destH)
if (-not [ClawdCache]::TryLoad($stillKey, [ref]$fr, [ref]$meta)) {
    $still  = New-Object System.Drawing.Bitmap($script:stillPath)
    $blink  = [ClawdFx]::MakeBlink($still, 736, 1000, 1200, 850)
    $noEyes = [ClawdFx]::MakeNoEyes($still, 736, 1000, 1200, 850)
    $fr = [System.Drawing.Bitmap[]]@(([ClawdFrames]::Extract($noEyes, $script:srcRect, $script:destW, $script:destH, $false))[0],
                                     ([ClawdFrames]::Extract($blink,  $script:srcRect, $script:destW, $script:destH, $false))[0])
    $meta = [int[]](@([ClawdFx]::FindEyes($still, 736, 1000, 1200, 850)) + [ClawdFx]::FindLegTop($still, 736, 1050, 1200, 799))
    $blink.Dispose(); $noEyes.Dispose(); $still.Dispose()
    [ClawdCache]::Save($stillKey, $fr, $meta)
}
$script:sNoEyesBase = $fr[0]; $script:sBlinkBase = $fr[1]
$script:eyeRects = [int[]]$meta[0..7]
$script:legTop   = $meta[8]

# ---------- Walking legs: exactly the frames of Clawd-CrabWalking.gif ----------
# Body/head STAYS STILL (Still sprite). Only the leg strip is animated, using
# ALL official GIF frames - flattened to 2D.
$script:legDestY = [int][Math]::Round(($script:legTop - 351) * $script:scale)
$legSrcH  = 1850 - $script:legTop
$legDestH = [int][Math]::Ceiling($legSrcH * $script:scale) + 1
$walkPath = Join-Path $assetDir 'Clawd-CrabWalking.gif'
$legKey   = [ClawdCache]::Key($walkPath, 'legs', $script:destW, $script:legTop, $legDestH)
if (-not [ClawdCache]::TryLoad($legKey, [ref]$fr, [ref]$meta)) {
    $legSrc = [System.Drawing.Rectangle]::new(736, $script:legTop, 1200, $legSrcH)
    $frames = @(); $hashes = @()
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $walkGif = [System.Drawing.Image]::FromFile($walkPath)
    $wd = New-Object System.Drawing.Imaging.FrameDimension($walkGif.FrameDimensionsList[0])
    $wn = $walkGif.GetFrameCount($wd)
    $legStrip = [System.Drawing.Rectangle]::new(0, 0, 1200, $legSrcH)
    for ($f = 0; $f -lt $wn; $f++) {
        $null = $walkGif.SelectActiveFrame($wd, $f)
        # Copy just the leg strip 1:1 (not the whole 2750x1850 frame - that alone took seconds)
        $full = New-Object System.Drawing.Bitmap(1200, $legSrcH, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb))
        $gg = [System.Drawing.Graphics]::FromImage($full)
        $gg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $gg.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $gg.DrawImage($walkGif, $legStrip, $legSrc, [System.Drawing.GraphicsUnit]::Pixel)
        $gg.Dispose()
        $flat = [ClawdFx]::MakeFlat($full, 0, 0, 1200, $legSrcH)
        $small = New-Object System.Drawing.Bitmap($script:destW, $legDestH, ([System.Drawing.Imaging.PixelFormat]::Format32bppPArgb))
        $gs = [System.Drawing.Graphics]::FromImage($small)
        $gs.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $gs.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $gs.DrawImage($flat, ([System.Drawing.Rectangle]::new(0, 0, $script:destW, $legDestH)), $legStrip, [System.Drawing.GraphicsUnit]::Pixel)
        $gs.Dispose()
        $frames += , $small
        $ms = New-Object System.IO.MemoryStream
        $small.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $hashes += [System.BitConverter]::ToString($md5.ComputeHash($ms.ToArray()))
        $ms.Dispose()
        $flat.Dispose(); $full.Dispose()
    }
    $walkGif.Dispose()
    $md5.Dispose()
    # Walk loop = only the frames whose legs DIFFER from the standing pose (frame 0),
    # so there is no "still" pause in the middle of the stepping cycle
    $loop = @()
    for ($f = 1; $f -lt $wn; $f++) { if ($hashes[$f] -ne $hashes[0]) { $loop += $f } }
    if ($loop.Count -eq 0) { $loop = @(0..($wn - 1)) }
    $fr = [System.Drawing.Bitmap[]]$frames; $meta = [int[]]$loop
    [ClawdCache]::Save($legKey, $fr, $meta)
}
$script:legFrames  = $fr
$script:legFramesL = [System.Drawing.Bitmap[]]@($fr | ForEach-Object { $m = $_.Clone(); $m.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX); $m })
$script:legLoop  = [int[]]$meta
$script:legFrame = 0
$script:legPos   = 0
$script:legWait  = $script:legStepK

# ---------- Frame cache ----------
# Every sprite and GIF frame is decoded and scaled ONCE, to the exact size it is drawn at, and kept
# in the disk cache. Drawing then is a tiny 1:1 copy - before, every frame rescaled a 2750x1850
# canvas, which alone ate ~9 ms per frame. GIFs are played by elapsed time, re-timed onto the
# display-frame grid (ClawdFrames.Snap); 'div' is how many display frames each GIF frame lasts.
$script:nowMs   = 0.0
$script:anims   = @{}
function Add-Anim([string]$name, [string]$path, $src, [int]$x, [int]$y, [int]$w, [int]$h, [bool]$smooth) {
    $delays = $null; $div = 1
    $frames = [ClawdCache]::LoadAnim($path, $src, $w, $h, $smooth, [ref]$delays)
    $cum = [ClawdFrames]::Snap($delays, $script:frameMs, [ref]$div)
    $script:anims[$name] = @{ base = $frames; frames = $frames; n = $frames.Length; t0 = 0.0; cum = $cum; x = $x; y = $y; w = $w; h = $h }
    Set-AnimPace $script:anims[$name] $div
}
# Script rate while a GIF plays: once per GIF frame (at most 6 display frames apart, so input still
# feels live), and at least every 2nd display frame while the status bubble's spark is turning.
function Set-AnimPace($a, [int]$div) {
    $a.div = [ClawdFrames]::DivisorAtMost($div, 6)
    $a.divBusy = [ClawdFrames]::DivisorAtMost($a.div, 2)
}
function Reset-Anim([string]$name) { $script:anims[$name].t0 = $script:nowMs }
function Get-AnimFrame([string]$name) {
    $a = $script:anims[$name]
    return $a.frames[[ClawdFrames]::Index($a.cum, ($script:nowMs - $a.t0 + $script:halfFrameMs))]
}
# Where a standalone GIF (dance / work / cook) lands in the window: sized to match the idle crab
# (scale up until either the width reaches destW OR the height reaches crabH, whichever needs
# more), clamped to the window, bottom-aligned, and centred on Clawd's head rather than on props.
function Get-GifPlacement([string]$state, $src) {
    $scale = [Math]::Max($script:destW / [double]$src.Width, $script:crabH / [double]$src.Height)
    if ($script:gifScale.ContainsKey($state)) { $scale *= $script:gifScale[$state] }
    if (($src.Width  * $scale) -gt $script:formW) { $scale = $script:formW / [double]$src.Width }
    if (($src.Height * $scale) -gt $script:destH) { $scale = $script:destH / [double]$src.Height }
    $dw = [int]($src.Width * $scale)
    $dh = [int]($src.Height * $scale)
    $dx = [int](($script:formW - $dw) / 2.0)
    $dy = [int]($script:destH - $dh)
    $hx = [int]($script:formW / 2.0); $ht = $dy
    if ($script:gifHead.ContainsKey($state)) {
        $ha = $script:gifHead[$state]
        $dx = [int]($script:formW / 2.0 - ($ha[0] - $src.X) * $scale)
        $hx = [int]($dx + ($ha[0] - $src.X) * $scale)
        $ht = [int]($dy + ($ha[1] - $src.Y) * $scale)
    }
    return @($dx, $dy, $dw, $dh, $hx, $ht)
}
# Cook intro: content rect skips only row-0 stage dots; the hat enters from y=24 in zoom-in frames
function Get-CookIntroPlacement {
    $src   = [System.Drawing.Rectangle]::new(2, 1, 258, 250)
    $scale = [Math]::Max($script:destW / [double]$src.Width, $script:crabH / [double]$src.Height) * 0.95
    if (($src.Width  * $scale) -gt $script:formW) { $scale = $script:formW / [double]$src.Width }
    if (($src.Height * $scale) -gt $script:destH) { $scale = $script:destH / [double]$src.Height }
    $dw = [int]($src.Width * $scale); $dh = [int]($src.Height * $scale)
    $dx = [int](($script:formW - $dw) / 2.0); $dy = [int]($script:destH - $dh)
    return @($dx, $dy, $dw, $dh, [int]($script:formW / 2.0), $dy, $src)
}
function Build-FrameCache {
    $full = [System.Drawing.Rectangle]::new(0, 0, $script:destW, $script:destH)
    $script:fullSrc = $full
    $script:bodySrc = [System.Drawing.Rectangle]::new(0, 0, $script:destW, $script:legDestY)
    $script:sNoEyes = $script:sNoEyesBase; $script:sBlink = $script:sBlinkBase
    Add-Anim 'wave' (Join-Path $assetDir 'Clawd-Waving.gif') $script:srcRect $script:margin 0 $script:destW $script:destH $false
    Add-Anim 'jump' (Join-Path $assetDir 'Clawd-JumpingHappy.gif') $script:srcRect $script:margin 0 $script:destW $script:destH $false
    foreach ($st in @('dance', 'work', 'cook')) {
        $p = Get-GifPlacement $st $script:gifSrc[$st]
        Add-Anim $st $script:gifStates[$st] $script:gifSrc[$st] $p[0] $p[1] $p[2] $p[3] $true
        $script:anims[$st].hx = $p[4]; $script:anims[$st].ht = $p[5]
    }
    $p = Get-CookIntroPlacement
    Add-Anim 'cook-intro' $script:cookIntroPath $p[6] $p[0] $p[1] $p[2] $p[3] $true
    $a = $script:anims['cook-intro']
    $a.hx = $p[4]; $a.ht = $p[5]
    # Played slower than the GIF (it's a quick zoom-in): 3 display frames per frame, ~0.85 s in all
    $a.cum = [ClawdFrames]::Uniform($a.n, 3, $script:frameMs); Set-AnimPace $a 3
    # Extra animations: canvas (140x120 sprite units, sprite at 30,20) mapped onto the window so the
    # puppet's sprite sits exactly where the idle sprite is (anything above the window is cropped)
    $u = $script:destW / 80.0
    foreach ($k in $script:extraPaths.Keys) {
        $sz = [ClawdFrames]::ImageSize($script:extraPaths[$k])
        Add-Anim $k $script:extraPaths[$k] ([System.Drawing.Rectangle]::new(0, 0, $sz.Width, $sz.Height)) ([int][Math]::Round($script:margin - 30 * $u)) ([int][Math]::Round($script:destH - 120 * $u)) ([int][Math]::Round(140 * $u)) ([int][Math]::Round(120 * $u)) $false
        $script:anims[$k].hx = [int]($script:formW / 2.0); $script:anims[$k].ht = $script:destH - $script:crabH
        $script:gifStates[$k] = $script:extraPaths[$k]
    }
}
# Length of an animation in logic ticks (for $loops plays). A hair short of the exact length: the
# pose ends on the very frame its last GIF frame is over, never showing the loop's first frame again.
function Get-AnimTicks([string]$name, [double]$loops = 1) {
    $a = $script:anims[$name]
    return ($loops * $a.cum[$a.cum.Length - 1] - 1) / $script:tickMs
}
# Play one of the extra animations; $false when its GIF is not available (caller falls back)
function Start-Extra([string]$name, [double]$loops = 1) {
    if (-not $script:anims.ContainsKey($name)) { return $false }
    $null = Set-State $name (Get-AnimTicks $name $loops)
    return $true
}
Build-FrameCache
$script:legBase  = $script:legFrames
$script:legBaseL = $script:legFramesL

# ---------- Shell colour ----------
# hue (deg, -1 = original coral), saturation multiplier, brightness multiplier
$script:colors = [ordered]@{
    'Coral'    = @(-1, 1.0, 1.0)
    'Ocean'    = @(205, 0.95, 1.0)
    'Mint'     = @(152, 0.75, 1.0)
    'Lavender' = @(262, 0.7, 1.05)
    'Rose'     = @(335, 0.8, 1.05)
    'Gold'     = @(42, 1.0, 1.08)
    'Graphite' = @(15, 0.12, 0.62)
}
$script:colorName = [string](Get-Cfg 'color' 'Coral')
# Give one cached animation the current shell colour (the originals are kept to recolour from)
function Set-AnimColor($a) {
    $c = $script:colors[$script:colorName]
    if (-not [object]::ReferenceEquals($a.frames, $a.base)) { foreach ($b in $a.frames) { $b.Dispose() } }
    if ($c[0] -lt 0) { $a.frames = $a.base }
    else { $a.frames = [System.Drawing.Bitmap[]]@($a.base | ForEach-Object { [ClawdFrames]::Recolor($_, $c[0], $c[1], $c[2]) }) }
}
function Set-ClawdColor([string]$name) {
    if (-not $script:colors.Contains($name)) { $name = 'Coral' }
    $c = $script:colors[$name]
    $recolor = {
        param($bmp)
        if ($c[0] -lt 0) { return $bmp }
        return [ClawdFrames]::Recolor($bmp, $c[0], $c[1], $c[2])
    }
    $script:colorName = $name
    foreach ($a in $script:anims.Values) { Set-AnimColor $a }
    if (-not [object]::ReferenceEquals($script:sNoEyes, $script:sNoEyesBase)) { $script:sNoEyes.Dispose(); $script:sBlink.Dispose() }
    if (-not [object]::ReferenceEquals($script:legFrames, $script:legBase)) {
        foreach ($b in $script:legFrames) { $b.Dispose() }
        foreach ($b in $script:legFramesL) { $b.Dispose() }
    }
    $script:sNoEyes = & $recolor $script:sNoEyesBase
    $script:sBlink  = & $recolor $script:sBlinkBase
    if ($c[0] -lt 0) { $script:legFrames = $script:legBase; $script:legFramesL = $script:legBaseL }
    else {
        $script:legFrames  = @($script:legBase  | ForEach-Object { & $recolor $_ })
        $script:legFramesL = @($script:legBaseL | ForEach-Object { & $recolor $_ })
    }
}

# Geometry while dangling from the cursor: pivot = tip of the right claw (src ~1930,1390)
$script:armLX  = [single]((1930 - 736) * $script:scale)   # ~79.6 (local, no margin)
$script:armLY  = [single]((1390 - 351) * $script:scale)   # ~69.3
$script:dragW  = [int](2.5 * $script:destW)   # square dangle window, scales with size
$script:dragH  = $script:dragW
$script:anchorX = [int]($script:dragW / 2)   # pivot (claw tip) at the center of the dangle window
$script:anchorY = [int]($script:dragH / 2)

# ---------- Window ----------
# Per-pixel alpha layered window: drawn via Update-PetVisual (not the Paint event)
$script:form = New-Object PetOverlay
$script:form.ClientSize = [System.Drawing.Size]::new($script:formW, $script:destH)
$script:glide = New-Object ClawdGlide($script:form)   # walking: moves the window on every display frame
$script:petBmp = $null
$script:petG   = $null

$script:calmKey = ''
function Update-PetVisual {
    # Resting is mostly frames identical to the last one (slow breathing, still eyes). A cheap key of
    # everything a calm frame shows lets those frames skip the drawing work altogether.
    if (($script:state -eq 'idle' -or $script:state -eq 'walk') -and ($script:fx -eq 'none' -or $script:fx -eq 'doze') -and $script:qmTicks -le 0 -and
        $null -eq $script:glyphCur -and ($script:globalT - $script:pulseAt) -ge 16 -and $script:sysMode -ne 'busy' -and
        -not $script:dragging -and $script:shMode -eq 'none' -and $script:balMode -eq 'none') {
        if ($script:state -eq 'walk') {
            $breath = "w$($script:legFrame)$($script:dir)$($script:cursorNear)"   # no breathing while walking
            $zz = 0
        } elseif ($script:fx -eq 'doze') {
            $breath = [Math]::Round(0.03 * [Math]::Sin($script:globalT * 0.03) * $script:destH * 2)
            $zz = [int]($script:globalT * 0.5)   # floating Zs move on
        } else {
            $breath = [Math]::Round(0.015 * [Math]::Sin($script:globalT * 0.05) * $script:destH * 2)
            $zz = 0
        }
        $blink = if ($script:blinkTicks -le 0) { 0 } elseif (Get-EyeHalf) { 1 } else { 2 }
        $key = "$breath|$([Math]::Round($script:eyeOX * $script:scale * 4))|$([Math]::Round($script:eyeOY * $script:scale * 4))|$blink|$zz|$($script:form.Left)|$($script:form.Top)|$($script:form.ClientSize.Width)|$($script:colorName)"
        if ($key -eq $script:calmKey) { return }
        $script:calmKey = $key
    } else {
        $script:calmKey = ''
    }
    $cs = $script:form.ClientSize
    if ($null -eq $script:petBmp -or $script:petBmp.Width -ne $cs.Width -or $script:petBmp.Height -ne $cs.Height) {
        if ($null -ne $script:petG)   { $script:petG.Dispose() }
        if ($null -ne $script:petBmp) { $script:petBmp.Dispose() }
        # Premultiplied, like the cached frames and the layered window itself: drawing is a straight
        # copy and handing the frame to the window needs no per-pixel conversion
        $script:petBmp = New-Object System.Drawing.Bitmap($cs.Width, $cs.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppPArgb))
        $script:petG = [System.Drawing.Graphics]::FromImage($script:petBmp)
    }
    $script:petG.ResetTransform()
    $script:petG.Clear([System.Drawing.Color]::Transparent)
    Render-Pet $script:petG
    $script:petG.ResetTransform()
    $script:form.Render($script:petBmp, $script:form.Left, $script:form.Top)
}

# Separate small window for the balloon during the descend phase
$script:balForm = New-Object System.Windows.Forms.Form
$script:balForm.FormBorderStyle = 'None'
$script:balForm.StartPosition   = 'Manual'
$script:balForm.TopMost         = $true
$script:balForm.ShowInTaskbar   = $false
$script:balForm.BackColor       = [System.Drawing.Color]::Magenta
$script:balForm.TransparencyKey = $script:balForm.BackColor
$script:balForm.ClientSize      = [System.Drawing.Size]::new(70, 110)
$script:balForm.Visible         = $false
$script:balForm.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($script:balForm, $true, $null)
$script:balForm.Add_Paint({
    $g2 = $_.Graphics
    $bs = $script:destW / 80.0
    Draw-Balloon $g2 35 4 $bs
    $knot = [single](4 + 44 * $bs + 2)
    $sw = [single](3 * [Math]::Sin($script:globalT * 0.08))
    $g2.DrawLine($script:stringPen, 35, $knot, (35 + $sw), ($knot + [single](30 * $bs)))
})

# The Shadow window: appears only during the rare encounter
$script:shForm = New-Object System.Windows.Forms.Form
$script:shForm.FormBorderStyle = 'None'
$script:shForm.StartPosition   = 'Manual'
$script:shForm.TopMost         = $true
$script:shForm.ShowInTaskbar   = $false
$script:shForm.BackColor       = [System.Drawing.Color]::Magenta
$script:shForm.TransparencyKey = $script:shForm.BackColor
$script:shForm.Opacity         = 0.9
$script:shForm.Visible         = $false
$script:shForm.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($script:shForm, $true, $null)
$script:shForm.Add_Paint({
    if ($script:shFrames.Count -eq 0) { return }
    $g3 = $_.Graphics
    $g3.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g3.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $w3 = $script:shDW; $h3 = $script:shDH
    if ($script:shDir -lt 0) {
        $g3.TranslateTransform([single]($w3 + 32), 0)
        $g3.ScaleTransform(-1, 1)
    }
    # During the staring phase: very subtle up-down breathing ALONG the screen edge
    # (not a tilt - tilting makes the body look detached from the edge)
    $yOff = 0
    if ($script:shT -ge 110 -and $script:shT -lt 420) {
        $yOff = [int][Math]::Round(1.5 * [Math]::Sin(($script:shT - 110) * 0.035))
    }
    $g3.DrawImage($script:shFrames[$script:shIdx], ([System.Drawing.Rectangle]::new(16, (8 + $yOff), $w3, $h3)))
})

# Sky overlay (shooting stars) - created once, shown only during the show
$script:starOv = New-Object StarOverlay      # twinkling sky
$script:starMetOv = New-Object StarOverlay   # meteors (small, follows them)

# "Claude is ..." status bubble overlay - click-through, floats above the head
$script:statusOv     = New-Object StarOverlay
$script:statusBmp    = $null   # composite per-frame bitmap (for fade)
$script:statusG      = $null
$script:statusBub    = $null   # bubble content bitmap (cached per token)
$script:statusBubTok = '~'   # token currently cached in statusBub
$script:statusKey    = ''    # what is currently composed into statusBmp (skip identical recomposes)
$script:statusPopAt  = [double]-1000
$script:loadFrames   = $null # loading-spark frames, cached at bubble size

# ---------- Monitors ----------
# Clawd lives on one monitor at a time: $script:scr is that monitor, $script:wa its working area
# (walls, ceiling, taskbar floor). He moves to another monitor when you drop him there or throw
# him across the edge; the choice is remembered in clawd.json ("monitor").
function Get-ScreenAt([double]$x, [double]$y) {
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) { if ($s.Bounds.Contains([int]$x, [int]$y)) { return $s } }
    return $null
}
# The monitor next to the current one on the left (-1) or right (1), level with height $y
function Get-NeighbourScreen([int]$side, [double]$y) {
    $best = $null
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        if ($s.DeviceName -eq $script:scr.DeviceName -or $y -lt $s.Bounds.Top -or $y -ge $s.Bounds.Bottom) { continue }
        if ($side -gt 0 -and $s.Bounds.Left -ge $script:scr.Bounds.Right -and ($null -eq $best -or $s.Bounds.Left -lt $best.Bounds.Left)) { $best = $s }
        if ($side -lt 0 -and $s.Bounds.Right -le $script:scr.Bounds.Left -and ($null -eq $best -or $s.Bounds.Right -gt $best.Bounds.Right)) { $best = $s }
    }
    return $best
}
function Set-PetScreen($s, [bool]$remember = $false) {
    $changed = ($null -eq $script:scr -or $script:scr.DeviceName -ne $s.DeviceName)
    $script:scr = $s
    $script:wa = $s.WorkingArea
    $script:bottomY = $script:wa.Bottom - $script:destH
    $script:supportY = [double]$script:bottomY
    if ($changed -and $remember) { Save-CfgValue 'monitor' ($s.DeviceName | ConvertTo-Json) }
}
$script:scr = $null
$startScreen = [System.Windows.Forms.Screen]::PrimaryScreen
$savedMon = [string](Get-Cfg 'monitor' '')
foreach ($s in [System.Windows.Forms.Screen]::AllScreens) { if ($savedMon -and $s.DeviceName -eq $savedMon) { $startScreen = $s } }
Set-PetScreen $startScreen
$script:posX    = [double]($script:wa.Left + ($script:wa.Width - $script:formW) / 2)
$script:form.Location = [System.Drawing.Point]::new([int]$script:posX, $script:bottomY)

# ---------- State ----------
# Time model: every counter, speed and duration below is expressed in "logic ticks" of
# $script:tickMs (Frame pacing, above) - the pace all of Clawd's motion was tuned at. Frames are
# rendered at 60 fps while something moves, 30 fps for walking (the window itself glides at 60),
# at each GIF's own frame rate for the GIF poses and 15 fps at rest; each frame advances the logic
# by $script:k = (scheduled ms since the last frame) / tickMs, so speed never depends on the frame rate.
$script:k         = 1.0
$script:lastMs    = 0.0
$script:rand      = New-Object System.Random
$script:state     = 'idle'   # idle | walk | wave | jump | fall
$script:ticks     = 150
$script:dir       = 1
$script:vy        = [double]0
$script:dragging  = $false
$script:dragOff   = [System.Drawing.Point]::new(0, 0)
$script:dragStart = [System.Drawing.Point]::new(0, 0)
$script:moved     = $false
$script:globalT   = [double]0
$script:fx        = 'none'   # none | hop | wiggle | squash | lookaround | doze
$script:busyUntil = 0        # globalT until which Working/Cooking stays on cooldown (anti-thrash)
$script:lastBusy  = ''       # which busy animation ran last ('work' | 'cook') - to alternate
$script:workAnim      = ''       # the single animation locked in for the current Claude-working session
$script:gifHeadX   = 0       # window-relative x of Clawd's head in the current standalone GIF
$script:gifHeadTop = 0       # window-relative y of the top of his head in the current standalone GIF
$script:everydayStates = @('idle', 'walk', 'wave', 'jump', 'dance', 'coffee', 'love', 'sneeze', 'stretch', 'nap', 'celebrate')   # poses that yield to a work session
# Poses a Claude/Codex work session can show; the activity token picks one (Get-WorkAnimFor)
$script:workStates = @('work', 'cook', 'cook-intro', 'think', 'magnifier')
$script:tokAnim    = @{ 'think' = 'think'; 'read' = 'magnifier' }   # (magnifier only if its GIF is present)
$script:busyPick   = ''      # work/cook choice for the other tokens, held for the whole session
$script:workAnimAt = [double]0   # globalT when the current session pose was chosen (anti-thrash hold)
$script:actT0      = [double]0   # globalT when the current thinking pose started
$script:propLook   = @(0.0, 0.0) # where the activity props want the eyes to look (eye-offset units)
$script:pulseAt    = [double]-1000   # globalT of the last squash-and-settle pulse
$script:pulseAmp   = 0.0
$script:glyphCur   = $null   # glyph bubble currently shown (for the pop-in / pop-out)
$script:glyphAt    = [double]-1000
$script:glyphGoneAt= [double]-1000
$script:nudgeAcc   = 0.0     # fractional pixels owed to a shoved window
$script:nextWatch  = 0.0     # ms timestamps for throttled checks
$script:nextKeys   = 0.0
$script:nextSys    = 0.0
$script:nextPlat   = 0.0
$script:nextTop    = 0.0
$script:fxTicks   = 0
$script:fxTotal   = 1
$script:blinkTicks= 0
$script:blinkLen  = 10
$script:blinkCd   = 200
$script:hoverCd   = 0
$script:topCnt    = 0
$script:eyeOX     = [double]0
$script:eyeOY     = [double]0
$script:cursorNear= $false
$script:qmTicks   = 0
$script:qmCd      = 0
$script:theta     = [double]0   # pendulum angle while dangling (radians, 0 = hanging straight)
$script:omega     = [double]0   # angular velocity
$script:lastCpX   = 0
$script:lastCpY   = 0
$script:lastVelX  = [double]0
$script:lastVelY  = [double]0
$script:fallVX    = [double]0   # horizontal velocity when thrown
$script:posY      = [double]0
$script:ancX      = [double]0   # anchor (claw) position CHASING the cursor with easing
$script:ancY      = [double]0
$script:ancVX     = [double]0   # eased anchor velocity (for the swing)
$script:ancVY     = [double]0
$script:lastAncVX = [double]0
$script:cvX       = [double]0   # cursor velocity (EMA) - used for throw strength
$script:cvY       = [double]0
$script:walkTotal = 1   # walk duration for ease-in/ease-out
$script:platforms   = @()   # app windows used as platforms: (hwnd,L,T,R,B) per window
$script:platRefresh = 0
$script:onPlat      = $false   # currently standing on an app window?
$script:platHwnd    = [long]0
$script:supportY    = [double]0   # form.Top position when standing on the active platform
$script:lurkDir     = 1   # 1 = peeks from the left edge, -1 = from the right
$script:balMode   = 'none'   # none | descend | float | pop
$script:balX      = [double]0   # balloon position (descend phase)
$script:balY      = [double]0
$script:balVY     = [double]0   # rising speed while floating
$script:balT      = 0   # age of the floating phase
$script:balPopT   = 0   # explosion progress
$script:balDriftX = [double]0
$script:balLastDX = [double]0
$script:balWind   = [double]0   # subtle random wind (descend phase)
$script:balPosY   = [double]0   # precise sub-pixel Y position while floating
$script:balEscape = $false      # a let-go balloon drifting up & away on its own
$script:balEscX   = [double]0
$script:balEscY   = [double]0
$script:balEscVY  = [double]0
$script:balEscWind= [double]0
$script:starActive = $false   # shooting-star show in progress
$script:starT      = 0   # show timeline (ticks)
$script:sky        = $null   # the StarShow while it runs
# The Shadow: a dark Clawd that very rarely peeks from the screen edge
$script:shMode   = 'none'   # none | show
$script:shT      = 0   # encounter timeline
$script:shIdx    = 0   # dark lurking frame currently shown
$script:shDir    = 1   # 1 = left edge, -1 = right edge
$script:shFrames = @()   # darkened lurking frames (built on first call)
$script:shPeak   = 0   # the most "out" frame
$script:shScale  = 0.14 * ($script:destW / 80.0)
$script:shDW     = [int](330 * $script:shScale * 1.5)   # 1.5x the good Clawd: more intimidating
$script:shDH     = [int](401 * $script:shScale * 1.5)
# Climbing the screen wall
$script:climbPhase  = 'none'   # none | in | up | pause | down | out
$script:climbWall   = 1   # 1 = left wall, -1 = right
$script:climbRot    = [double]0   # current body rotation (degrees)
$script:climbX      = [double]0   # X position of the climb window
$script:climbY      = [double]0   # body center (screen Y)
$script:climbTarget = [double]0   # target height
$script:climbT      = 0
$script:wantClimb   = $false   # triggered from the menu: climb once the wall is reached
# Mischief: tugging the window he stands on
$script:shoveDir    = 1
# Mischief: shoving a window from the side (while on the floor)
$script:pushHwnd    = [long]0
$script:pushSide    = 1   # shove direction: 1 = right, -1 = left
$script:pushPhase   = 'none'   # none | approach | tug
$script:pushT       = 0
$script:pushTugs    = 0
# Work mode (system awareness): normal | busy (high CPU) | sleepy (user idle long)
$script:sysMode    = 'normal'
$script:cpuEMA     = [double]0
$script:sysCheck   = 0
if ($script:featSys) { [void][ClawdInput]::CpuPercent() }   # first sample (baseline)

# Balloon (rare animation)
$script:balBrush   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(217, 119, 87))
$script:balHiBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(242, 167, 135))
$script:balKnotBr  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(175, 88, 60))
$script:stringPen  = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(210, 195, 175))

# Claude-themed terminal: warm dark background, coral accent, cream text
$script:termBrush       = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(40, 38, 35))
$script:termPen         = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(217, 119, 87))
$script:termTextBrush   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(240, 238, 229))
$script:termCoralBrush  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(217, 119, 87))
$script:termDimBrush    = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(120, 217, 119, 87))
$script:codeFont        = New-Object System.Drawing.Font('Consolas', 7)
$script:eyeBrush    = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(18, 14, 12))
$script:whiteBrush  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(250, 248, 244))
$script:bubbleBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(246, 238, 226))
$script:glyphBrush  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 52, 44))
$script:sweatBrush  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220, 140, 190, 235))

# The finish chime is loaded into chimePlayer above.

# ---------- "Claude Watch": status bubble above the head ----------
# A Claude Code hook writes a single activity token to this file; Clawd reads it and
# shows a bubble: "running a command...", "writing code...", etc.
$script:watchFile  = Join-Path $env:TEMP 'clawd-status.txt'
$script:watchTok   = ''   # current activity token
$script:watchVis   = [double]0   # 0..1 for bubble fade-in/out
$script:watchCheck = 0   # throttle for file reads
$script:watchAge   = 999.0   # age (seconds) of the last write
$script:statusTail = 7   # height of the bubble triangle tail
$script:statusFont = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Regular)
$script:watchText  = @{
    'think'  = 'thinking...'
    'bash'   = 'running a command...'
    'edit'   = 'writing code...'
    'read'   = 'reading files...'
    'web'    = 'browsing the web...'
    'task'   = 'spinning up an agent...'
    'notify' = 'needs your input...'
    'done'   = 'all done'
}
# Playful "done" verbs (like Claude Code) - a random one + timestamp is picked each finish
$script:doneVerbs = @('cooked', 'brewed', 'baked', 'steeped', 'simmered', 'served', 'plated',
                      'shipped', 'wrapped up', 'sealed', 'polished', 'buttoned up', 'nailed it')
$script:doneMsg   = 'all done'   # current finish message (regenerated on each transition to done)

# Pixel patterns for the bubble: question mark, Z (sleep), note (dancing)
function Convert-Pattern([string[]]$rows) {
    $cells = @()
    for ($r = 0; $r -lt $rows.Count; $r++) {
        for ($c = 0; $c -lt $rows[$r].Length; $c++) {
            if ($rows[$r][$c] -eq '#') { $cells += , @($c, $r) }
        }
    }
    return $cells
}
$script:glyphs = @{
    'qm'   = Convert-Pattern @('.###.', '#...#', '....#', '...#.', '..#..', '.....', '..#..')
    'zz'   = Convert-Pattern @('#####', '....#', '...#.', '..#..', '.#...', '#....', '#####')
    'note' = Convert-Pattern @('...#.', '...##', '...#.', '...#.', '..##.', '.###.', '..#..')
    'ex'   = Convert-Pattern @('..#..', '..#..', '..#..', '..#..', '..#..', '.....', '..#..')
}

# Blink in three steps (half-shut -> shut -> half-shut) instead of an instant snap.
# Long closes (sleep, wishing) skip the half steps at the ends that matter less.
function Get-EyeHalf {
    return ($script:blinkTicks -gt 0 -and $script:fx -ne 'doze' -and $script:blinkLen -le 12 -and
            ($script:blinkTicks -lt 1.6 -or $script:blinkTicks -gt ($script:blinkLen - 1.6)))
}
function Start-Blink([int]$len) { $script:blinkTicks = $len; $script:blinkLen = $len }

function Get-CurrentImage {
    switch ($script:state) {
        'wave' { return (Get-AnimFrame 'wave') }
        'jump' { return (Get-AnimFrame 'jump') }
        default {
            if ($script:blinkTicks -gt 0 -and -not (Get-EyeHalf)) { return $script:sBlink }
            return $script:sNoEyes
        }
    }
}

# A quick squash-and-settle "boing" (decaying spring), used to soften hard cuts between poses
function Start-Pulse([double]$amp) { $script:pulseAt = $script:globalT; $script:pulseAmp = $amp }

$script:pulseStates = @('wave', 'jump', 'dance', 'work', 'cook', 'think', 'code', 'coffee', 'magnifier', 'celebrate', 'love', 'sneeze', 'stretch', 'nap')
# Lurking frames, built on first use (67 frames that most sessions never need). Also finds the
# frame where he is furthest out (peakMs), where the wake-up peek stops before he steps out.
function Initialize-LurkAnim {
    if ($script:anims.ContainsKey('lurk')) { return }
    Add-Anim 'lurk' $script:lurkPath ([System.Drawing.Rectangle]::new(0, 399, 330, 401)) 0 ($script:destH - 40) 33 40 $false
    $a = $script:anims['lurk']
    $best = -1; $peak = 0
    for ($i = 0; $i -lt $a.n; $i++) { $cnt = [ClawdFx]::CountOpaque($a.base[$i]); if ($cnt -gt $best) { $best = $cnt; $peak = $i } }
    $a.peak = $peak
    $a.peakMs = if ($peak -gt 0) { $a.cum[$peak - 1] } else { 0 }
    Set-AnimColor $a
}

function Set-State([string]$s, [double]$durTicks) {
    $prev = $script:state
    $script:state = $s
    $script:ticks = $durTicks
    $script:glide.Stop()   # a new pose moves the window itself (if at all)
    if ($s -eq 'lurk' -or $s -eq 'peek') { Initialize-LurkAnim; Reset-Anim 'lurk' }
    if ($script:anims.ContainsKey($s)) { Reset-Anim $s }
    if ($s -eq 'think') { $script:actT0 = $script:globalT }
    # Soften the cut into (and back out of) a different-looking pose
    if ($s -ne $prev -and (($script:pulseStates -contains $s) -or ($s -eq 'idle' -and ($script:pulseStates -contains $prev)))) {
        Start-Pulse 0.07
    }
    Update-PetVisual
}

function Start-Fx([string]$f, [int]$total) {
    $script:fx = $f
    $script:fxTotal = [Math]::Max(1, $total)
    $script:fxTicks = $total
}

# True while a fresh agent activity is selected by the shared status layer.
function Test-AgentWorking {
    return ($script:featWatch -and $script:watchTok -and $script:watchTok -ne 'done' -and $script:watchAge -lt 15.0)
}

# Switch to the next busy animation, alternating Working <-> Cooking so it stays lively.
# Used for the rare ambient appearance while Claude is idle.
function Start-BusyNext {
    $next = if ($script:lastBusy -eq 'work') { 'cook' } else { 'work' }
    $script:lastBusy = $next
    Set-State $next $script:rand.Next(320, 460)
}

# Which pose matches what the agent is doing: thinking -> thought cloud. Everything else (editing,
# reading, commands, web, agents...) uses Working or Cooking, picked once per session (Cook ~75%).
function Get-WorkAnimFor([string]$tok) {
    $mapped = $script:tokAnim[$tok]
    if ($mapped -and ($mapped -eq 'think' -or $script:anims.ContainsKey($mapped))) { return $mapped }
    if ($script:busyPick -eq '') { $script:busyPick = if ($script:rand.Next(4) -gt 0) { 'cook' } else { 'work' } }
    return $script:busyPick
}

# Keep Clawd in a pose for the agent's session. The pose follows the activity, but each choice is
# held for at least ~4 s so quick tool hops (read -> edit -> read...) never make him flicker.
function Start-WorkSession {
    $want = Get-WorkAnimFor $script:watchTok
    if ($script:workAnim -eq '') {
        $script:workAnim = $want; $script:workAnimAt = $script:globalT
    } elseif ($want -ne $script:workAnim -and ($script:globalT - $script:workAnimAt) -ge 150) {
        $script:workAnim = $want; $script:workAnimAt = $script:globalT
    }
    if ($script:workAnim -eq 'work' -or $script:workAnim -eq 'cook') { $script:lastBusy = $script:workAnim }
    if ($script:state -eq $script:workAnim) {
        if ($script:ticks -lt 100) { $script:ticks = $script:rand.Next(320, 460) }   # already in it - keep going
    } elseif ($script:state -eq 'cook-intro' -and $script:workAnim -eq 'cook') {
        # intro still playing - let it finish naturally, don't interrupt
    } else {
        $startState = if ($script:workAnim -eq 'cook') { 'cook-intro' } else { $script:workAnim }
        Set-State $startState $script:rand.Next(320, 460)   # cook-intro hands over to cook by itself
    }
}

function Draw-Balloon($g, [single]$cx, [single]$top, [double]$s) {
    $w = [single](36 * $s); $h = [single](44 * $s)
    $g.FillEllipse($script:balBrush, ($cx - $w / 2), $top, $w, $h)
    $g.FillEllipse($script:balHiBrush, ($cx - $w * 0.28), ($top + $h * 0.12), ($w * 0.22), ($h * 0.26))
    $g.FillRectangle($script:balKnotBr, ($cx - 2), ($top + $h - 1), 4, 4)
}

function Start-Balloon {
    if ($script:balMode -ne 'none' -or $script:balEscape) { return }
    $bs = $script:destW / 80.0
    $crabCX = $script:form.Left + $script:formW / 2
    $off = 120 + $script:rand.Next(0, 160)
    if ($script:rand.NextDouble() -lt 0.5) { $off = -$off }
    $script:balX = [double][Math]::Max(($script:wa.Left + 60), [Math]::Min(($script:wa.Right - 60), ($crabCX + $off)))
    $script:balY = [double]($script:wa.Top - 10)
    $script:balMode = 'descend'
    $script:balT = 0
    $script:balForm.ClientSize = [System.Drawing.Size]::new(70, [int]((44 + 34) * $bs + 14))
    $script:balForm.Location = [System.Drawing.Point]::new([int]($script:balX - 35), [int]$script:balY)
    $script:balForm.Show()
    $script:balForm.TopMost = $true
    $script:form.TopMost = $true
    Set-State 'walk' 9999
    $script:walkTotal = 9999
}

function Cancel-Balloon {
    $script:balMode = 'none'
    $script:balForm.Hide()
    if ($script:state -eq 'walk' -and $script:ticks -gt 5000) {
        Set-State 'idle' $script:rand.Next($script:idleMinT, $script:idleMaxT)
    }
}

# ---------- Climbing the wall ----------
function Start-Climb([int]$wall) {
    $script:climbWall  = $wall
    $script:climbPhase = 'in'
    $script:climbT     = 0
    $script:climbRot   = 0
    $half = $script:climbSide / 2.0
    $cx = $script:form.Left + $script:margin + $script:destW / 2.0
    $cy = $script:form.Top + $script:destH - $script:crabH / 2.0
    $script:climbX = $cx - $half
    $script:climbY = $cy
    $script:climbTarget = $script:wa.Top + $script:wa.Height * (0.22 + $script:rand.NextDouble() * 0.30)
    $script:form.ClientSize = [System.Drawing.Size]::new($script:climbSide, $script:climbSide)
    $script:form.Location = [System.Drawing.Point]::new([int][Math]::Round($script:climbX), [int][Math]::Round($script:climbY - $half))
    Set-State 'climb' 9999
    Update-PetVisual
}

function Stop-Climb([bool]$jumpOff) {
    $half = $script:climbSide / 2.0
    $bodyCX = $script:climbX + $half
    $script:form.ClientSize = [System.Drawing.Size]::new($script:formW, $script:destH)
    $newLeft = [int][Math]::Max($script:wa.Left, [Math]::Min(($script:wa.Right - $script:formW), [Math]::Round($bodyCX - $script:formW / 2.0)))
    $newTop  = [int][Math]::Round($script:climbY - ($script:destH - $script:crabH / 2.0))
    $script:form.Location = [System.Drawing.Point]::new($newLeft, $newTop)
    Update-PetVisual
    $script:posX = [double]$newLeft
    $script:posY = [double]$newTop
    $script:climbPhase = 'none'
    if ($jumpOff) {
        $script:fallVX = -$script:climbWall * (2.5 + $script:rand.NextDouble() * 3.0)
        $script:vy = -1.5
        Set-State 'fall' 9999
    } else {
        $script:form.Top = [int]$script:bottomY
        $script:posY = [double]$script:bottomY
        Set-State 'idle' $script:rand.Next($script:idleMinT, $script:idleMaxT)
    }
}

# ---------- Shoving a window from the side ----------
function Find-PushTarget {
    # Find a window that reaches the floor and whose side edge he can approach
    $floorY = $script:bottomY + $script:destH
    $crabCX = $script:form.Left + $script:formW / 2
    $best = $null
    $bestDist = 600
    for ($i = 0; $i -lt $script:platforms.Length; $i += 5) {
        $L = $script:platforms[$i + 1]; $T = $script:platforms[$i + 2]
        $R = $script:platforms[$i + 3]; $B = $script:platforms[$i + 4]
        if ($B -lt ($floorY - 30)) { continue }   # does not reach the floor
        if ($T -gt ($script:bottomY + 10)) { continue }
        if (($R - $L) -lt 200) { continue }
        if (($R + 80) -lt $script:wa.Right) {   # shove from left to right
            $d = [Math]::Abs($L - $crabCX)
            if ($d -lt $bestDist) { $bestDist = $d; $best = @{ h = $script:platforms[$i]; side = 1 } }
        }
        if (($L - 80) -gt $script:wa.Left) {   # shove from right to left
            $d = [Math]::Abs($R - $crabCX)
            if ($d -lt $bestDist) { $bestDist = $d; $best = @{ h = $script:platforms[$i]; side = -1 } }
        }
    }
    return $best
}

function Start-Push($target) {
    $script:pushHwnd  = $target.h
    $script:pushSide  = $target.side
    $script:pushPhase = 'approach'
    $script:pushT     = 0
    $script:pushTugs  = 0
    Set-State 'push' 9999
}

function Stop-Push {
    $script:pushPhase = 'none'
    Set-State 'idle' $script:rand.Next($script:idleMinT, $script:idleMaxT)
}

# ---------- The Shadow ----------
function Build-ShadowFrames {
    if ($script:shFrames.Count -gt 0) { return }
    $gif = [System.Drawing.Image]::FromFile((Join-Path $assetDir 'Clawd-Lurking.gif'))
    $fd = New-Object System.Drawing.Imaging.FrameDimension($gif.FrameDimensionsList[0])
    $n = $gif.GetFrameCount($fd)
    $maxC = -1
    for ($f = 0; $f -lt $n; $f++) {
        $null = $gif.SelectActiveFrame($fd, $f)
        $full = New-Object System.Drawing.Bitmap($gif.Width, $gif.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb))
        $gg = [System.Drawing.Graphics]::FromImage($full)
        $gg.DrawImage($gif, 0, 0, $gif.Width, $gif.Height)
        $gg.Dispose()
        $dark = [ClawdFx]::Darken($full, 0, 399, 330, 401, 10, 9, 12, 205, 28, 36)   # pitch-black body, red eyes
        $full.Dispose()
        $script:shFrames += , $dark
        $c = [ClawdFx]::CountOpaque($dark)
        if ($c -gt $maxC) { $maxC = $c; $script:shPeak = $f }
    }
    $gif.Dispose()
}

function Start-Shadow {
    if ($script:shMode -ne 'none' -or $script:starActive -or $script:balMode -ne 'none' -or $script:dragging) { return }
    Build-ShadowFrames
    if ($script:shFrames.Count -eq 0) { return }
    # Appear on the edge farther from Clawd
    $crabCX = $script:form.Left + $script:formW / 2
    $script:shDir = 1
    if ($crabCX -lt ($script:wa.Left + $script:wa.Width / 2)) { $script:shDir = -1 }
    $script:shForm.ClientSize = [System.Drawing.Size]::new(($script:shDW + 32), ($script:shDH + 12))
    $left = $script:wa.Left - 16
    if ($script:shDir -lt 0) { $left = $script:wa.Right - $script:shDW - 16 }
    $script:shForm.Location = [System.Drawing.Point]::new([int]$left, [int](($script:bottomY + $script:destH) - $script:shDH - 8))
    $script:shForm.Opacity = 0
    $script:shIdx = 0
    $script:shT = 0
    $script:shMode = 'show'
    $script:shForm.Show()
    $script:shForm.TopMost = $true
    $script:form.TopMost = $true
    if ($script:state -eq 'walk' -or $script:state -eq 'idle') { Set-State 'idle' 9999 }
}

function Stop-Shadow {
    $script:shMode = 'none'
    $script:shForm.Hide()
    if ($script:state -eq 'idle' -and $script:ticks -gt 5000) {
        Set-State 'idle' $script:rand.Next($script:idleMinT, $script:idleMaxT)
    }
}

# ---------- Shooting stars ----------
# Simulated and drawn natively by StarShow (see the C# block): meteors on a small window that
# follows them, the twinkling sky on a second overlay refreshed only a few times a second.
function Start-StarShow {
    if ($script:starActive -or $script:balMode -ne 'none' -or $script:dragging) { return }
    $bounds = $script:scr.Bounds   # the sky of the monitor he is on
    $script:sky = New-Object StarShow($script:starMetOv, $script:starOv, $bounds.Left, $bounds.Top, $bounds.Width, [int]($bounds.Height * 0.55), $script:rand.Next(), $script:tickMs)
    $script:sky.Attach($script:clock)   # meteors animate natively at 60 fps; Clawd's logic runs at 30
    $script:starT = 0
    $script:starActive = $true
    $script:form.TopMost = $true
    Set-State 'stargaze' 9999
}

function Cancel-StarShow {
    $script:starActive = $false
    if ($null -ne $script:sky) { $script:sky.Close(); $script:sky = $null }
}

function Update-StarShow {
    $t0 = $script:starT
    $t = $script:sky.Time
    $script:starT = $t
    # Wish moment: eyes closed for a while, golden sparkle around the head (drawn on the pet form)
    if ($t0 -lt 415 -and $t -ge 415) { Start-Blink 60 }
    if ($t -ge 560) {
        Cancel-StarShow
        Set-State 'jump' 190   # jump for joy after the wish is made
    }
}

function Draw-Eyes($g, [single]$ox, [single]$oy, [bool]$panic, [bool]$happy = $false, [bool]$half = $false) {
    for ($e = 0; $e -lt 2; $e++) {
        $ex = $script:eyeRects[$e * 4]; $ey = $script:eyeRects[$e * 4 + 1]
        $ew = $script:eyeRects[$e * 4 + 2] * $script:scale
        $eh = $script:eyeRects[$e * 4 + 3] * $script:scale
        $bx = [single]($ox + ($ex - 736) * $script:scale)
        $by = [single]($oy + ($ey - 351) * $script:scale)
        if ($panic) {
            # Bulging: white eye base grows, pupil shrinks (no tremble)
            $g.FillRectangle($script:whiteBrush, [single]($bx - 1), [single]($by - 1), [single]($ew + 2), [single]($eh + 2))
            $pw = [single]($ew * 0.55); $ph = [single]($eh * 0.55)
            $g.FillRectangle($script:eyeBrush, [single]($bx + ($ew - $pw) / 2), [single]($by + ($eh - $ph) / 2), $pw, $ph)
        } elseif ($happy) {
            # Happy eyes while dancing: PIXEL pattern (blocks) so it matches the Clawd sprite style -
            # a ^_^ arch from blocks half the eye size (real eye = 100px in the source).
            $rowsH = @('.##.', '#..#')
            $colsH = 4
            $bs    = [single]($ew * 0.5)
            $pwH   = [single]($colsH * $bs); $phH = [single]($rowsH.Count * $bs)
            $ecx   = [single]($bx + $ew / 2.0)
            $ecy2  = [single]($by + $eh / 2.0)
            $px0   = [single]($ecx - $pwH / 2.0); $py0 = [single]($ecy2 - $phH / 2.0)
            $sm = $g.SmoothingMode; $g.SmoothingMode = 'None'
            for ($ry = 0; $ry -lt $rowsH.Count; $ry++) {
                $line = $rowsH[$ry]
                for ($cxi = 0; $cxi -lt $colsH; $cxi++) {
                    if ($line[$cxi] -eq '#') {
                        $g.FillRectangle($script:eyeBrush, [single]($px0 + $cxi * $bs), [single]($py0 + $ry * $bs), $bs, $bs)
                    }
                }
            }
            $g.SmoothingMode = $sm
        } else {
            $ex2 = [single]($bx + $script:eyeOX * $script:scale)
            $ey2 = [single]($by + $script:eyeOY * $script:scale)
            if ($half) {
                # Half-shut (start/end of a blink): only the lower part of the eye shows
                $hh = [single][Math]::Max(1.0, [Math]::Round($eh * 0.4))
                $g.FillRectangle($script:eyeBrush, $ex2, [single]($ey2 + $eh - $hh), [single]$ew, $hh)
            } else {
                $g.FillRectangle($script:eyeBrush, $ex2, $ey2, [single]$ew, [single]$eh)
            }
        }
    }
}

# Clawd's body sprite + eyes (open, half-shut or closed) with its top-left at (x, y)
function Draw-Clawd($g, [int]$x, [int]$y) {
    $half = Get-EyeHalf
    $closed = ($script:blinkTicks -gt 0 -and -not $half)
    $img = if ($closed) { $script:sBlink } else { $script:sNoEyes }
    $g.DrawImage($img, ([System.Drawing.Rectangle]::new($x, $y, $script:destW, $script:destH)), $script:fullSrc, [System.Drawing.GraphicsUnit]::Pixel)
    if (-not $closed) { Draw-Eyes $g ([single]$x) ([single]$y) $false $false $half }
}

# Squash (sx > 1, sy < 1) or stretch around an anchor point
function Push-Scale($g, [single]$ax, [single]$ay, [double]$sx, [double]$sy) {
    $g.TranslateTransform($ax, $ay); $g.ScaleTransform([single]$sx, [single]$sy); $g.TranslateTransform(-$ax, -$ay)
}

# The settle "boing" after a pose change: a decaying squash <-> stretch spring
function Apply-Pulse($g, [single]$ax, [single]$ay) {
    $pe = $script:globalT - $script:pulseAt
    if ($pe -lt 0 -or $pe -ge 16) { return }
    $ps = $script:pulseAmp * [Math]::Exp(-$pe / 3.2) * [Math]::Cos($pe * 0.85)
    Push-Scale $g $ax $ay (1.0 + $ps) (1.0 - $ps)
}

# ---------- Activity props (thinking / sleeping) ----------
# Pixel-art props drawn in "sprite units": u = destW / 80, the sprite grid at the default size.
# Coordinates are relative to the sprite's top-left; the head top sits at y = 47u.
$script:propU    = $script:destW / 80.0
$script:thinkCloudTop = 0
$script:zCells = Convert-Pattern @('####', '..#.', '.#..', '####')

# THINKING: little puffs rise to a thought cloud with "..." cycling; now and then an idea "!"
function Draw-ThinkCloud($g, [double]$ox, [double]$oy) {
    $u = $script:propU
    $t = $script:globalT - $script:actT0
    $headTop = $oy + 47 * $u
    if ($t -gt 3) { $r = 1.6 * $u; $g.FillEllipse($script:bubbleBrush, [single]($ox + 58 * $u - $r), [single]($headTop - 3 * $u - $r), [single](2 * $r), [single](2 * $r)) }
    if ($t -gt 7) { $r = 2.4 * $u; $g.FillEllipse($script:bubbleBrush, [single]($ox + 63 * $u - $r), [single]($headTop - 9 * $u - $r), [single](2 * $r), [single](2 * $r)) }
    if ($t -le 11) { return }
    $q = [Math]::Min(1.0, ($t - 11) / 8.0)
    $s = 1 + 2.70158 * [Math]::Pow($q - 1, 3) + 1.70158 * [Math]::Pow($q - 1, 2)   # pop in with a little overshoot
    $cx = [single]($ox + 69 * $u); $cy = [single]($headTop - 22 * $u)
    $script:thinkCloudTop = [int]($cy - 9 * $u)
    $st = $g.Save()
    Push-Scale $g $cx $cy $s $s
    foreach ($b in @(@(-12, -4, 12, 10), @(-5, -9, 13, 12), @(3, -6, 11, 10), @(-13, -1, 26, 8))) {
        $g.FillEllipse($script:bubbleBrush, [single]($cx + $b[0] * $u), [single]($cy + $b[1] * $u), [single]($b[2] * $u), [single]($b[3] * $u))
    }
    $phase = ($t - 11) % 260
    if ($phase -ge 200) {
        $cell = [int][Math]::Max(1, [Math]::Round(1.1 * $u))
        $gx = [int]($cx - 2.5 * $cell); $gy = [int]($cy - 6 * $u)
        foreach ($cl in $script:glyphs['ex']) { $g.FillRectangle($script:termCoralBrush, ($gx + $cl[0] * $cell), ($gy + $cl[1] * $cell), $cell, $cell) }
    } else {
        $n = 1 + [int][Math]::Floor(($t % 45) / 15)
        $d = [int][Math]::Max(2, [Math]::Round(2 * $u))
        for ($i = 0; $i -lt $n; $i++) {
            $g.FillRectangle($script:glyphBrush, [int]($cx + (-6 + $i * 5) * $u), [int]($cy - 1 * $u), $d, $d)
        }
    }
    $g.Restore($st)
    $script:propLook = @((36.0 + 8.0 * [Math]::Sin($t * 0.04)), -30.0)
}

# Sleeping: little "z" bubbles drift up from his head, grow, and pop
function Draw-Zzz($g, [double]$cx, [double]$headTop) {
    $u = $script:propU
    for ($i = 0; $i -lt 3; $i++) {
        $ph = (($script:globalT * 0.010) + $i / 3.0) % 1.0
        $sz = (7 + 7 * $ph) * $u
        if ($ph -gt 0.85) { $sz *= (1 - $ph) / 0.15 }
        if ($ph -lt 0.12) { $sz *= $ph / 0.12 }
        if ($sz -lt 2) { continue }
        $x = $cx + (10 + $ph * 14) * $u + 2 * $u * [Math]::Sin($ph * 7 + $i)
        $y = $headTop - (4 + $ph * 30) * $u
        $g.FillEllipse($script:bubbleBrush, [single]($x - $sz / 2), [single]($y - $sz / 2), [single]$sz, [single]$sz)
        $cell = [int][Math]::Max(1, [Math]::Floor($sz / 8))
        $zx = [int]($x - 2 * $cell); $zy = [int]($y - 2 * $cell)
        foreach ($cl in $script:zCells) { $g.FillRectangle($script:glyphBrush, ($zx + $cl[0] * $cell), ($zy + $cl[1] * $cell), $cell, $cell) }
    }
}

# ---------- Drawing (called by Update-PetVisual, renders to an ARGB bitmap) ----------
function Render-Pet($g) {
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::Half

    # ===== DANGLING MODE: claw caught on the cursor, body becomes a pendulum =====
    if ($script:dragging -and $script:moved) {
        $ang = [single](-85 + $script:theta * 180.0 / [Math]::PI)
        $g.TranslateTransform([single]$script:anchorX, [single]$script:anchorY)
        $g.RotateTransform($ang)
        $g.TranslateTransform(-$script:armLX, -$script:armLY)
        Draw-Clawd $g 0 0
        return
    }

    # ===== BALLOON MODE: floating up on a balloon / balloon popping =====
    if ($script:state -eq 'balloon') {
        $bs = $script:destW / 80.0
        $cxw = [single]($script:form.ClientSize.Width / 2.0)
        $knotY = [single](8 + 44 * $bs)
        $pivY  = [single]($knotY + 30 * $bs)
        if ($script:balMode -eq 'float' -or $script:balMode -eq 'lift') {
            Draw-Balloon $g $cxw 8 $bs
            $g.DrawLine($script:stringPen, $cxw, $knotY, $cxw, $pivY)
        } elseif ($script:balMode -eq 'pop') {
            # Explosion: coral particles spread out then fade
            for ($i = 0; $i -lt 8; $i++) {
                $a = $i * [Math]::PI / 4
                $r = 4 + $script:balPopT * 2.4
                $px = $cxw + $r * [Math]::Cos($a)
                $py = (8 + 22 * $bs) + $r * [Math]::Sin($a)
                $sz = [Math]::Max(1.0, 4.5 - $script:balPopT * 0.32)
                $g.FillEllipse($script:termCoralBrush, [single]($px - $sz / 2), [single]($py - $sz / 2), [single]$sz, [single]$sz)
            }
        }
        # Crab hangs at the end of the string; during lift-off it rotates smoothly
        # from the standing pose (0 deg) to the hanging pose (-85 deg)
        if ($script:balMode -eq 'lift') {
            $p = [Math]::Min(1.0, $script:balT / 55.0)
            $e = $p * $p * (3 - 2 * $p)
            $ang = [single](-85.0 * $e)
        } else {
            $ang = [single](-85 + $script:theta * 180.0 / [Math]::PI)
        }
        $g.TranslateTransform($cxw, $pivY)
        $g.RotateTransform($ang)
        $g.TranslateTransform(-$script:armLX, -$script:armLY)
        Draw-Clawd $g 0 0
        return
    }

    # ===== CLIMBING MODE: body rotates 90 deg, legs planted on the wall =====
    if ($script:state -eq 'climb') {
        $half = [single]($script:climbSide / 2.0)
        $g.TranslateTransform($half, $half)
        $g.RotateTransform([single]$script:climbRot)
        $g.TranslateTransform([single](-($script:margin + $script:destW / 2.0)), [single](-($script:destH - $script:crabH / 2.0)))
        $cur2 = Get-CurrentImage
        $g.DrawImage($cur2, ([System.Drawing.Rectangle]::new($script:margin, 0, $script:destW, $script:legDestY)), $script:bodySrc, [System.Drawing.GraphicsUnit]::Pixel)
        $leg = $script:legFrames[$script:legFrame]
        $g.DrawImage($leg, ([System.Drawing.Rectangle]::new($script:margin, $script:legDestY, $leg.Width, $leg.Height)))
        $eh = Get-EyeHalf
        if ($script:blinkTicks -le 0 -or $eh) { Draw-Eyes $g ([single]$script:margin) ([single]0) $false $false $eh }
        return
    }

    # ===== LURKING MODE: peeks shyly from the screen edge (official GIF) =====
    # 'peek' (waking up from stand-by) plays it only up to the frame where he is furthest out
    # and holds there, then he steps out ('enter').
    if ($script:state -eq 'lurk' -or $script:state -eq 'peek') {
        if ($script:lurkDir -lt 0) {
            $g.TranslateTransform([single]$script:formW, 0)
            $g.ScaleTransform(-1, 1)
        }
        $a = $script:anims['lurk']
        $frame = if ($script:state -eq 'peek' -and ($script:nowMs - $a.t0) -ge $a.peakMs) { $a.frames[$a.peak] } else { Get-AnimFrame 'lurk' }
        $g.DrawImage($frame, ([System.Drawing.Rectangle]::new($a.x, $a.y, $a.w, $a.h)))
        return
    }

    # ===== CODE MODE: hide -> type hello world -> wave (still hidden) -> then wake up =====
    if ($script:state -eq 'code') {
        $elapsed = 380 - $script:ticks
        # Stays submerged through the sequence; only rises in the last 25 ticks
        $t = 1.0
        if ($elapsed -lt 25) { $t = $elapsed / 25.0 }
        elseif ($elapsed -gt 355) { $t = (380 - $elapsed) / 25.0 }
        $t = [Math]::Max(0.0, [Math]::Min(1.0, $t))
        $ease = $t * $t * (3 - 2 * $t)
        $yy = [int](($script:crabH - 16) * $ease)
        if ($elapsed -ge 205 -and $elapsed -lt 355) {
            # Waving from behind the edge: only the head + hand peek out
            $dest = [System.Drawing.Rectangle]::new($script:margin, $yy, $script:destW, $script:destH)
            $g.DrawImage((Get-AnimFrame 'wave'), $dest, $script:fullSrc, [System.Drawing.GraphicsUnit]::Pixel)
        } else {
            Draw-Clawd $g $script:margin $yy
        }
        # Claude-themed terminal (shown while he hides & waves)
        if ($elapsed -ge 30 -and $elapsed -lt 355) {
            $g.ResetTransform()
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
            $tw = [Math]::Min(96, $script:formW - 2); $th = 38   # narrower at the Tiny size
            $tx = [single](($script:formW - $tw) / 2)
            $ty = [single]2
            $g.FillRectangle($script:termBrush, $tx, $ty, $tw, $th)
            $g.DrawRectangle($script:termPen, $tx, $ty, $tw, $th)
            # Three macOS-style window dots, coral colored
            $g.FillEllipse($script:termCoralBrush, ($tx + 4), ($ty + 4), 4, 4)
            $g.FillEllipse($script:termDimBrush,   ($tx + 11), ($ty + 4), 4, 4)
            $g.FillEllipse($script:termDimBrush,   ($tx + 18), ($ty + 4), 4, 4)
            $g.SetClip([System.Drawing.RectangleF]::new(($tx + 1), $ty, ($tw - 2), $th))   # text never spills out of the frame
            $l1 = '> ' + $script:termCmd
            $n1 = [Math]::Max(0, [Math]::Min($l1.Length, [int][Math]::Floor(($elapsed - 35) / 3)))
            if ($n1 -gt 0) {
                $typed = $l1.Substring(0, $n1)
                if ($n1 -lt $l1.Length) { $typed += '_' }   # cursor rides along while typing
                $g.DrawString($typed, $script:codeFont, $script:termTextBrush, ($tx + 3), ($ty + 11))
            }
            if ($elapsed -gt (35 + $l1.Length * 3 + 25)) {
                $l2 = $script:termOut
                if (([int]($script:globalT / 18)) % 2 -eq 0) { $l2 += '_' }
                $g.DrawString($l2, $script:codeFont, $script:termCoralBrush, ($tx + 3), ($ty + 24))
            }
            $g.ResetClip()
        }
        return
    }

    $cx = [single]($script:margin + $script:destW / 2.0)
    $bottom = [single]$script:destH

    # ===== COOK-INTRO: plays once (held on its last frame), then the logic hands over to cook =====
    if ($script:state -eq 'cook-intro') {
        $a = $script:anims['cook-intro']
        $script:gifHeadX = $a.hx; $script:gifHeadTop = $a.ht
        Apply-Pulse $g $cx $bottom
        $el = $script:nowMs - $a.t0 + $script:halfFrameMs
        $frame = if ($el -ge $a.cum[$a.n - 1]) { $a.frames[$a.n - 1] } else { $a.frames[[ClawdFrames]::Index($a.cum, $el)] }
        $g.DrawImage($frame, ([System.Drawing.Rectangle]::new($a.x, $a.y, $a.w, $a.h)))
        return
    }

    # ===== STANDALONE GIF STATES: dance / work / cook =====
    # Pre-scaled frames (see Build-FrameCache), bottom-aligned, centred on Clawd's head.
    if ($script:gifStates.ContainsKey($script:state)) {
        $a = $script:anims[$script:state]
        $script:gifHeadX = $a.hx; $script:gifHeadTop = $a.ht
        Apply-Pulse $g $cx $bottom
        $g.DrawImage((Get-AnimFrame $script:state), ([System.Drawing.Rectangle]::new($a.x, $a.y, $a.w, $a.h)))
        return
    }

    # ===== NORMAL MODE =====
    $cur = Get-CurrentImage
    $baseSprite = ($script:state -ne 'wave' -and $script:state -ne 'jump' -and $script:state -ne 'code')
    $y = 0

    if ($script:qmTicks -gt 0 -and $baseSprite) {
        # Smooth ramp-in so the confused tilt does not jerk at the start
        $ramp = [Math]::Min(1.0, (160 - $script:qmTicks) / 12.0)
        $angle = [single](4.0 * [Math]::Sin($script:globalT * 0.12) * $ramp)
        $g.TranslateTransform($cx, $bottom); $g.RotateTransform($angle); $g.TranslateTransform(-$cx, -$bottom)
    }
    elseif ($script:state -eq 'push' -and $script:pushPhase -eq 'tug') {
        # Shoving a window: lean TOWARD the window + shake -> SHOVE (recoil + squash)
        $c = $script:pushT % 36
        $lean = 0.0
        if ($c -lt 18) {
            $p = $c / 18.0
            $lean = (4.0 + 9.0 * $p * $p) - (1.2 * [Math]::Sin($script:globalT * 1.1) * $p)
        } elseif ($c -lt 26) {
            $p = ($c - 18) / 8.0
            $lean = 13.0 - 8.0 * $p
            $sq = 0.05 * (1 - $p)
            Push-Scale $g $cx $bottom (1.0 + $sq) (1.0 - $sq)
        } else {
            $p = ($c - 26) / 10.0
            $lean = 5.0 - 1.0 * $p
        }
        $lean *= [Math]::Min(1.0, $script:pushT / 12.0)   # smooth ramp-in at the start
        $angle = [single]($lean * $script:pushSide)
        $g.TranslateTransform($cx, $bottom); $g.RotateTransform($angle); $g.TranslateTransform(-$cx, -$bottom)
    }
    elseif ($script:state -eq 'think' -and $script:fx -eq 'none') {
        # Pondering: a slow, gentle head tilt
        $angle = [single](2.0 * [Math]::Sin(($script:globalT - $script:actT0) * 0.035))
        $g.TranslateTransform($cx, $bottom); $g.RotateTransform($angle); $g.TranslateTransform(-$cx, -$bottom)
    }
    elseif ($script:state -eq 'idle' -and $script:fx -eq 'none') {
        $s = 1.0 + 0.015 * [Math]::Sin($script:globalT * 0.05)
        Push-Scale $g $cx $bottom 1.0 $s
    }
    elseif ($script:state -eq 'fall' -and $script:fx -eq 'none') {
        # Stretch along the motion while flying, like a rubber toy
        $v = [Math]::Min(1.0, [Math]::Abs($script:vy) / 22.0)
        Push-Scale $g $cx ([single]($bottom - $script:crabH / 2.0)) (1.0 - 0.07 * $v) (1.0 + 0.10 * $v)
    }
    Apply-Pulse $g $cx $bottom

    switch ($script:fx) {
        'squash' {
            # Landing spring: squash flat, rebound into a stretch, settle
            $e = $script:fxTotal - $script:fxTicks
            $s = 0.2 * [Math]::Exp(-$e / 3.5) * [Math]::Cos($e * 0.75)
            Push-Scale $g $cx $bottom (1.0 + $s) (1.0 - $s)
        }
        'hop' {
            # Up and down with a stretch in the air (the landing squash is a pulse, see the logic)
            $p = ($script:fxTotal - $script:fxTicks) / [double]$script:fxTotal
            $sn = [Math]::Sin([Math]::PI * $p)
            $y -= [int][Math]::Round(9 * $sn)
            Push-Scale $g $cx $bottom (1.0 - 0.04 * $sn) (1.0 + 0.07 * $sn)
        }
        'wiggle' {
            $wp = ($script:fxTotal - $script:fxTicks) * 0.9
            $damp = $script:fxTicks / [double]$script:fxTotal
            $angle = 10.0 * [Math]::Sin($wp) * $damp
            $g.TranslateTransform($cx, $bottom); $g.RotateTransform($angle); $g.TranslateTransform(-$cx, -$bottom)
        }
        'lookaround' {
            $angle = 2.0 * [Math]::Sin(($script:fxTotal - $script:fxTicks) * 0.06)
            $g.TranslateTransform($cx, $bottom); $g.RotateTransform($angle); $g.TranslateTransform(-$cx, -$bottom)
        }
        'doze' {
            # Sleeping: deep and slow breathing
            $s = 1.0 + 0.03 * [Math]::Sin($script:globalT * 0.03)
            Push-Scale $g $cx $bottom 1.0 $s
        }
        'duck' {
            # Hiding behind the edge: sink smoothly until only the head + eyes remain
            $elapsed = $script:fxTotal - $script:fxTicks
            $f1 = [Math]::Min(1.0, $elapsed / 25.0)
            $f2 = [Math]::Min(1.0, $script:fxTicks / 25.0)
            $t = [Math]::Max(0.0, [Math]::Min($f1, $f2))
            $ease = $t * $t * (3 - 2 * $t)
            $y += [int](($script:crabH - 16) * $ease)
        }
        'shove' {
            # Tugging the window rhythmically: wind-up (lean + shake) -> YANK (recoil + squash)
            $els = $script:fxTotal - $script:fxTicks
            $c = $els % 36
            $lean = 0.0
            if ($c -lt 18) {
                # Wind-up: leaning more, shaking under the load
                $p = $c / 18.0
                $lean = -(4.0 + 10.0 * $p * $p) + (1.3 * [Math]::Sin($script:globalT * 1.1) * $p)
            } elseif ($c -lt 26) {
                # Yank: quick recoil + body squashes from the effort
                $p = ($c - 18) / 8.0
                $lean = -14.0 + 9.0 * $p
                $sq = 0.05 * (1 - $p)
                Push-Scale $g $cx $bottom (1.0 + $sq) (1.0 - $sq)
            } else {
                # Catch a breath before the next pull
                $p = ($c - 26) / 10.0
                $lean = -5.0 + 1.0 * $p
            }
            $lean *= [Math]::Min(1.0, $els / 12.0)   # smooth ramp-in at the start
            $angle = [single](-$lean * $script:shoveDir)
            $g.TranslateTransform($cx, $bottom); $g.RotateTransform($angle); $g.TranslateTransform(-$cx, -$bottom)
        }
    }

    $eyeHalf = Get-EyeHalf
    $eyesOpen = ($script:blinkTicks -le 0 -or $eyeHalf)
    if ((($script:state -eq 'walk' -and -not $script:cursorNear) -or $script:state -eq 'enter' -or $script:fx -eq 'shove' -or $script:state -eq 'push') -and $script:legFrames.Count -gt 0) {
        # Body/head STAYS STILL from the Still sprite; legs = official GIF frames as-is
        # (also used while dragging a window: legs step when yanking)
        $g.DrawImage($cur, ([System.Drawing.Rectangle]::new($script:margin, $y, $script:destW, $script:legDestY)), $script:bodySrc, [System.Drawing.GraphicsUnit]::Pixel)
        $set = if ($script:dir -lt 0) { $script:legFramesL } else { $script:legFrames }
        $leg = $set[$script:legFrame]
        $g.DrawImage($leg, ([System.Drawing.Rectangle]::new($script:margin, ($y + $script:legDestY), $leg.Width, $leg.Height)))
        if ($eyesOpen) { Draw-Eyes $g ([single]$script:margin) ([single]$y) $false $false $eyeHalf }
    } else {
        $g.DrawImage($cur, ([System.Drawing.Rectangle]::new($script:margin, $y, $script:destW, $script:destH)), $script:fullSrc, [System.Drawing.GraphicsUnit]::Pixel)
        if ($baseSprite -and $eyesOpen) { Draw-Eyes $g ([single]$script:margin) ([single]$y) $false $false $eyeHalf }
    }


    # Busy mode (high CPU): a sweat drop runs down the side of the head
    if ($script:sysMode -eq 'busy' -and $baseSprite -and -not $script:dragging) {
        $sp = ([int]$script:globalT % 55) / 55.0
        if ($sp -lt 0.75) {
            $sy = [single](($script:destH - $script:crabH) + 2 + $sp * 16)
            $sx = [single]($script:margin + $script:destW - 14)
            $g.FillEllipse($script:sweatBrush, $sx, $sy, 4, 6)
        }
    }

    $g.ResetTransform()
    if ($script:state -eq 'think') { Draw-ThinkCloud $g $script:margin 0 }
    if ($script:fx -eq 'doze') { Draw-Zzz $g $cx ([double]($script:destH - $script:crabH)) }

    # Golden "wish" sparkle around the head while eyes are closed under a star
    if ($script:state -eq 'stargaze' -and $script:starT -ge 415 -and $script:starT -lt 490) {
        $hx = [single]($script:margin + $script:destW / 2.0)
        $hy = [single]($script:destH - $script:crabH + 4)
        $offs = @(@(-26, -4), @(24, -8), @(-13, -19), @(17, -22), @(1, -29), @(-31, -22))
        for ($i = 0; $i -lt $offs.Count; $i++) {
            if (((([int]$script:starT + $i * 7) / 9) % 3) -eq 0) { continue }   # alternating twinkle
            $sx = $hx + $offs[$i][0]; $sy = $hy + $offs[$i][1]
            $g.FillRectangle($script:bubbleBrush, [single]($sx - 2), [single]($sy - 0.5), 5, 2)
            $g.FillRectangle($script:bubbleBrush, [single]($sx - 0.5), [single]($sy - 2), 2, 5)
        }
    }

    # Bubble above the head: "!" (startled) / "?" (confused). It pops in with a little
    # overshoot and shrinks away instead of blinking on and off.
    $glyph = $null
    if ($script:shMode -eq 'show' -and $script:shT -ge 85 -and $script:shT -lt 170) { $glyph = 'ex' }
    elseif ($script:qmTicks -gt 0) { $glyph = 'qm' }
    if ($glyph) {
        if ($glyph -ne $script:glyphCur -or $script:glyphGoneAt -ge $script:glyphAt) { $script:glyphCur = $glyph; $script:glyphAt = $script:globalT }
        $script:glyphGoneAt = -1000
    } elseif ($script:glyphCur) {
        if ($script:glyphGoneAt -lt $script:glyphAt) { $script:glyphGoneAt = $script:globalT }
        if (($script:globalT - $script:glyphGoneAt) -gt 6) { $script:glyphCur = $null }
    }
    if ($script:glyphCur) {
        $q = [Math]::Min(1.0, ($script:globalT - $script:glyphAt) / 7.0)
        $s = 1 + 2.70158 * [Math]::Pow($q - 1, 3) + 1.70158 * [Math]::Pow($q - 1, 2)
        if (-not $glyph) { $s *= [Math]::Max(0.0, 1 - ($script:globalT - $script:glyphGoneAt) / 6.0) }
        if ($s -gt 0.05) {
            $bob = [single](1.5 * [Math]::Sin($script:globalT * 0.1))
            $bx = [single]($cx + 14)
            $by = [single]($script:destH - $script:crabH - 26 + $bob)
            Push-Scale $g ([single]($bx + 4)) ([single]($by + 22)) $s $s
            $g.FillEllipse($script:bubbleBrush, $bx, $by, 22, 22)
            foreach ($cell in $script:glyphs[$script:glyphCur]) {
                $g.FillRectangle($script:glyphBrush, [single]($bx + 6 + $cell[0] * 2), [single]($by + 4 + $cell[1] * 2), 2, 2)
            }
            $g.ResetTransform()
        }
    }
}

# ---------- "Claude Watch" bubble ----------
function New-RoundRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc(($x + $w - $d), $y, $d, $d, 270, 90)
    $p.AddArc(($x + $w - $d), ($y + $h - $d), $d, $d, 0, 90)
    $p.AddArc($x, ($y + $h - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# Build the bubble content bitmap for one token (cached; the pulsing dot is drawn separately)
# Tight text format (no trailing padding from MeasureString) so the text is truly centered
$script:statusFmt = [System.Drawing.StringFormat]::GenericTypographic.Clone()
$script:statusFmt.FormatFlags = $script:statusFmt.FormatFlags -bor [System.Drawing.StringFormatFlags]::MeasureTrailingSpaces

function Build-StatusBubble([string]$tok) {
    $done = ($tok -eq 'done')
    $txt = if ($done) { $script:doneMsg } else { $script:watchText[$tok] }
    if (-not $txt) { $txt = $tok }
    $mB = New-Object System.Drawing.Bitmap 1, 1
    $mG = [System.Drawing.Graphics]::FromImage($mB)
    $ts = $mG.MeasureString($txt, $script:statusFont, [int]1000, $script:statusFmt)
    $mG.Dispose(); $mB.Dispose()
    $tw = [int][Math]::Ceiling($ts.Width)
    $th = [int][Math]::Ceiling($ts.Height)
    $padL = 27; $padR = 13; $padV = 5; $rad = 9; $tail = $script:statusTail
    $w = $tw + $padL + $padR
    $h = $th + 2 * $padV
    $bmp = New-Object System.Drawing.Bitmap ([int]$w), ([int]($h + $tail)), ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $rr = New-RoundRect 0.5 0.5 ([single]($w - 1)) ([single]($h - 1)) $rad
    $g.FillPath($script:termBrush, $rr)
    $g.DrawPath($script:termPen, $rr)
    $rr.Dispose()
    # Triangle tail at the bottom-center pointing to the head
    $cxq = [single]($w / 2.0)
    $tri = New-Object 'System.Drawing.PointF[]' 3
    $tri[0] = New-Object System.Drawing.PointF (($cxq - 6), ([single]($h - 1)))
    $tri[1] = New-Object System.Drawing.PointF (($cxq + 6), ([single]($h - 1)))
    $tri[2] = New-Object System.Drawing.PointF ($cxq, ([single]($h + $tail - 1)))
    $g.FillPolygon($script:termBrush, $tri)
    $g.DrawLine($script:termPen, $tri[0], $tri[2])
    $g.DrawLine($script:termPen, $tri[1], $tri[2])
    # Close the bottom border segment right at the tail base so it blends in
    $g.FillRectangle($script:termBrush, [single]($cxq - 5.5), [single]($h - 2), 11, 3)
    # Coral checkmark when done
    if ($done) {
        $cp = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(217, 119, 87)), 1.9
        $iy = [single]($h / 2.0)
        $g.DrawLines($cp, @(
            (New-Object System.Drawing.PointF 8, $iy),
            (New-Object System.Drawing.PointF 11, ($iy + 3)),
            (New-Object System.Drawing.PointF 16, ($iy - 4))
        ))
        $cp.Dispose()
    }
    $g.DrawString($txt, $script:statusFont, $script:termTextBrush, [single]($padL - 2), [single](($h - $th) / 2.0), $script:statusFmt)
    $g.Dispose()
    return $bmp
}

# Render the bubble to the layered overlay, positioned above the head with alpha = watchVis
function Render-Status {
    if (-not $script:statusOv.Visible) { $script:statusOv.Show(); $script:statusOv.TopMost = $true }
    $tok = $script:watchTok
    if ($script:statusBubTok -ne $tok -or $null -eq $script:statusBub) {
        if ($null -ne $script:statusBub) { $script:statusBub.Dispose() }
        $script:statusBub = Build-StatusBubble $tok
        $script:statusBubTok = $tok
        $script:statusPopAt = $script:globalT
        $script:statusKey = ''
    }
    $bub = $script:statusBub
    $bw = $bub.Width; $bh = $bub.Height
    if ($null -eq $script:statusBmp -or $script:statusBmp.Width -ne $bw -or $script:statusBmp.Height -ne $bh) {
        if ($null -ne $script:statusG)   { $script:statusG.Dispose() }
        if ($null -ne $script:statusBmp) { $script:statusBmp.Dispose() }
        $script:statusBmp = New-Object System.Drawing.Bitmap ([int]$bw), ([int]$bh), ([System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
        $script:statusG = [System.Drawing.Graphics]::FromImage($script:statusBmp)
        $script:statusG.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $script:statusG.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
        $script:statusKey = ''
    }
    $vis = [Math]::Max(0.0, [Math]::Min(1.0, $script:watchVis))
    if ($vis -lt 0.05) { $script:statusPopAt = $script:globalT }   # (re)appearing: pop in from small
    # Loading spark (the "live" indicator), the official animated GIF; done shows a checkmark
    # instead. Painted at the same spot as the old spark: left gap of the bubble (centre x = 14),
    # vertically centred in the bubble body. Its frames are cached at this size on first use.
    $li = -1
    if ($tok -ne 'done') {
        $bodyH = $bh - $script:statusTail
        $ls = [int]([Math]::Max(14, [Math]::Min(20, $bodyH - 4)))
        if ($null -eq $script:loadFrames -or $script:loadFrames[0].Width -ne $ls) {
            $sz = [ClawdFrames]::ImageSize($script:loadPath); $ld = $null
            $script:loadFrames = [ClawdCache]::LoadAnim($script:loadPath, ([System.Drawing.Rectangle]::new(0, 0, $sz.Width, $sz.Height)), $ls, $ls, $true, [ref]$ld)
        }
        $li = [int][Math]::Floor(($script:nowMs + $script:halfFrameMs) / ($script:frameMs * $script:loadFrameEvery)) % $script:loadFrames.Length
    }
    # Pop: the bubble grows from 85% with an ease-out when it appears or its text changes
    $pq = [Math]::Min(1.0, ($script:globalT - $script:statusPopAt) / 9.0)
    $ps = 0.85 + 0.15 * (1 - [Math]::Pow(1 - $pq, 3))
    # Recompose only when something visible inside the bubble changed (the fade itself is free:
    # it is the window's constant alpha, applied by the compositor)
    $key = "$tok|$li|$([Math]::Round($ps, 3))"
    if ($key -ne $script:statusKey) {
        $script:statusKey = $key
        $g = $script:statusG
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.ResetTransform()
        if ($ps -lt 0.999) { Push-Scale $g ([single]($bw / 2.0)) ([single]$bh) $ps $ps }
        $g.DrawImage($bub, ([System.Drawing.Rectangle]::new(0, 0, $bw, $bh)), 0, 0, $bw, $bh, [System.Drawing.GraphicsUnit]::Pixel)
        if ($li -ge 0) {
            $lx = [int](14 - $ls / 2.0)
            $ly = [int](($bodyH - $ls) / 2.0)
            $g.DrawImage($script:loadFrames[$li], ([System.Drawing.Rectangle]::new($lx, $ly, $ls, $ls)))
        }
        $g.ResetTransform()
    }
    # Position: centered above the head; rises smoothly 6px on fade-in.
    # For the standalone GIFs (work/cook) use the actual drawn top so the bubble never
    # overlaps the head, whatever the GIF's height. While thinking it sits above the cloud.
    $cxs = $script:form.Left + $script:formW / 2.0
    $crabTop = $script:destH - $script:crabH
    if ($script:gifStates.ContainsKey($script:state)) {
        $cxs = $script:form.Left + $script:gifHeadX   # centre over his head, not the window
        $crabTop = $script:gifHeadTop
    } elseif ($script:state -eq 'think' -and $script:thinkCloudTop -gt 0) {
        $crabTop = $script:thinkCloudTop
    }
    $headTop = $script:form.Top + $crabTop
    $x = [int]($cxs - $bw / 2.0)
    $y = [int]($headTop - $bh - 1 + (1.0 - $vis) * 6)
    $x = [int][Math]::Max($script:wa.Left, [Math]::Min($x, ($script:wa.Right - $bw)))
    $script:statusOv.Render($script:statusBmp, $x, $y, [int](255 * $vis))
    if ($WatchLog -and $script:watchVis -gt 0.9) {
        $key = "$script:watchSource/$tok"
        if ($script:lastWatchLogKey -ne $key) {
            $script:lastWatchLogKey = $key
            try {
                [IO.File]::AppendAllText($WatchLog, ((@{at=[datetime]::UtcNow;source=$script:watchSource;token=$tok;state=$script:state;visible=$script:statusOv.Visible} | ConvertTo-Json -Compress) + [Environment]::NewLine))
                $script:statusBub.Save("$WatchLog.$script:watchSource.$tok.png", [Drawing.Imaging.ImageFormat]::Png)
            } catch { }
        }
    }
}

# ---------- State machine ----------
# Advance the walk-cycle legs by this frame's share of a logic tick. Every step lasts legStepK (a
# whole number of 30 fps ticks) and the remainder carries over, so the rhythm is exactly even.
# $rate > 1 steps faster (2 = twice as fast: hurrying, or yanking a window).
function Step-Legs([double]$rate = 1.0) {
    $script:legWait -= $script:k * $rate
    if ($script:legWait -le 0.001) {   # (4 x 1.2 is not quite 4.8 in floating point)
        $script:legPos = ($script:legPos + 1) % $script:legLoop.Count
        $script:legFrame = $script:legLoop[$script:legPos]
        $script:legWait = [Math]::Max(0.5, $script:legWait + $script:legStepK)
    }
}

# Walking moves go through the glide (window motion at 60 fps between 30 fps logic ticks); any
# other code that sets the window position directly takes over again (Set-State stops the glide).
$script:glideAt = 0.0
function Move-Glide([double]$x, [double]$y) {
    $script:glide.Push($x, $y, $script:nowMs)
    $script:glideAt = $script:nowMs
}

# Move a window by a fractional number of pixels per frame (whole pixels are sent, the rest is kept)
function Step-Nudge([long]$hwnd, [double]$dx) {
    $script:nudgeAcc += $dx
    $n = [int][Math]::Truncate($script:nudgeAcc)
    if ($n -ne 0) {
        $script:nudgeAcc -= $n
        [ClawdWin]::Nudge($hwnd, $n, 0)
    }
    return $n
}

# How many display frames until the next script frame:
#   1    = 60 fps  fast motion (thrown, dragged, balloon ride, meteors, hops and squashes)
#   2    = 30 fps  walking (the window glides at 60 fps in between) and anything else that moves
#   div  = a GIF pose: once per GIF frame (12 fps GIF -> 5, 30 fps -> 2), each shown equally long
#   4    = 15 fps  resting with nothing to animate and the mouse still (only breathing and blinks)
$script:cursorMovedAt = 0.0
function Get-FrameDivisor {
    if ($script:dragging -or $script:starActive -or $script:state -eq 'fall' -or $script:state -eq 'balloon') { return 1 }
    if ($script:fx -eq 'hop' -or $script:fx -eq 'squash' -or $script:fx -eq 'wiggle' -or $script:fx -eq 'shove') { return 1 }
    if (($script:globalT - $script:pulseAt) -lt 16 -or ($script:globalT - $script:glyphAt) -lt 10 -or ($script:globalT - $script:statusPopAt) -lt 10) { return 1 }
    $a = $script:anims[$script:state]
    if ($null -ne $a -and $script:fx -eq 'none' -and $script:qmTicks -le 0 -and $null -eq $script:glyphCur -and
        -not $script:balEscape -and $script:shMode -eq 'none') {
        if ($script:watchVis -gt 0.001) { return $a.divBusy }
        return $a.div
    }
    $resting = ($script:state -eq 'idle' -and ($script:fx -eq 'none' -or $script:fx -eq 'doze') -and $script:qmTicks -le 0 -and
                $null -eq $script:glyphCur -and $script:balMode -eq 'none' -and -not $script:balEscape -and $script:shMode -eq 'none' -and
                $script:watchVis -le 0.001 -and ($script:nowMs - $script:cursorMovedAt) -gt 1500)
    if ($resting) { return 4 }
    return 2
}

# Runs after every script frame (whichever way onTick returned): when the next one is due. A GIF
# pose is paced on its own frame grid, so the next script frame lands exactly on its next change.
$script:onPace = {
    $div = Get-FrameDivisor
    $frames = $div
    $a = $script:anims[$script:state]
    if ($null -ne $a -and $div -gt 1 -and ($div -eq $a.div -or $div -eq $a.divBusy)) {
        $frames = $div - ([Math]::Round(($script:nowMs - $a.t0) / $script:frameMs) % $div)
    }
    if ($script:starActive) {
        $script:clock.PeriodUs = $script:frameUs; $script:clock.PsDivisor = 2   # meteors: native 60 fps, Clawd 30
    } elseif ($script:glide.Active) {
        $script:clock.PeriodUs = $script:frameUs; $script:clock.PsDivisor = $div   # window glides every frame
    } else {
        $script:clock.PeriodUs = $script:frameUs * $frames; $script:clock.PsDivisor = 1
    }
}

$script:onTick = {
    # Time of this frame as scheduled by the clock (not when the UI thread got to it), in logic ticks
    # since the last one. Clamped so a stall (e.g. a drag of the menu or a sleeping PC) never
    # teleports anything.
    $nowMs = $script:clock.DueMs
    $k = ($nowMs - $script:lastMs) / $script:tickMs
    # A glide that was not pushed on the previous frame is over (he stopped or something took over)
    if ($script:glide.Active -and $script:glideAt -lt $script:lastMs) { $script:glide.Stop() }
    $script:lastMs = $nowMs
    if ($k -gt 2.5) { $k = 2.5 } elseif ($k -lt 0.05) { $k = 0.05 }
    $script:k = $k
    $script:nowMs = $nowMs
    $sk = [Math]::Sqrt($k)   # random-walk noise scales with sqrt(time)
    $script:globalT += $k
    if ($script:hoverCd -gt 0) { $script:hoverCd -= $k }
    if ($script:qmCd -gt 0) { $script:qmCd -= $k }
    if ($script:qmTicks -gt 0) { $script:qmTicks -= $k }

    # A let-go balloon drifting up & away on its own. Runs FIRST, before any early return
    # (e.g. the dragging block returns), so it keeps animating even while you hold the crab.
    if ($script:balEscape) {
        $bs = $script:destW / 80.0
        $script:balEscVY = [Math]::Max(-3.8, $script:balEscVY - 0.05 * $k)   # accelerates upward
        $script:balEscWind = ($script:balEscWind + ($script:rand.NextDouble() - 0.5) * 0.16 * $sk) * [Math]::Pow(0.97, $k)
        $script:balEscX += ($script:balEscWind + 0.5 * [Math]::Sin($script:globalT * 0.02)) * $k
        $script:balEscY += $script:balEscVY * $k
        $script:balForm.Location = [System.Drawing.Point]::new([int]($script:balEscX - 35), [int]($script:balEscY - 4))
        $script:balForm.Invalidate()
        if (($script:balEscY + 44 * $bs) -lt ($script:wa.Top - 30)) {   # fully off the top -> done
            $script:balForm.Hide()
            $script:balEscape = $false
        }
    }

    # ===== Claude Watch: read the status & show the bubble above the head =====
    # Runs up HERE, before the state-machine early-returns below, so the bubble can never
    # freeze in place when a heavy animation (balloon, meteor, push, climb, fall...) takes
    # over: the moment Clawd leaves a calm pose the bubble hides, and it only returns once
    # he's back in a normal pose.
    if ($script:featWatch) {
        if ($nowMs -ge $script:nextWatch) {   # ~3x / second
            $script:nextWatch = $nowMs + 300
            try {
                if ($null -ne ($agentState = Get-ClawdDisplayState $script:featClaudeWatch $script:featCodexWatch $script:codexWatchFile $script:watchFile)) {
                    $script:watchSource = $agentState.source
                    $script:watchAge = ([DateTime]::UtcNow - [datetime]$agentState.at).TotalSeconds
                    if ($script:featCodexWatch -and $agentState.token -ne 'done') { $script:watchAge = 0 }
                    $tk = $agentState.token
                    if ($tk) {
                        if ($tk -eq 'done' -and $script:watchTok -ne 'done' -and $script:watchAge -lt 8) {
                            # Fresh finish: pick a random playful verb + timestamp (like Claude Code)
                            $v = $script:doneVerbs[$script:rand.Next($script:doneVerbs.Count)]
                            $script:doneMsg = "$v at $([DateTime]::Now.ToString('HH:mm'))"
                            # Play custom chime — three ascending notes, unique clawd identity
                            if ($script:featSound) { try { $script:chimePlayer.Play() } catch { } } # Audio failure must not discard a completed turn.
                            # If he dozed off, wake him up so he never sleeps through a finish
                            if ($script:fx -eq 'doze') { $script:fx = 'none'; $script:fxTicks = 0 }
                            # Celebrate so the finish is noticeable - from a calm pose or straight out of
                            # the work pose (that is where a finish usually catches him)
                            if (($script:state -eq 'idle' -or $script:state -eq 'walk' -or ($script:workStates -contains $script:state)) -and $script:fx -eq 'none' -and -not $script:dragging -and $script:balMode -eq 'none' -and -not $script:starActive -and $script:shMode -eq 'none') {
                                if (-not (Start-Extra 'celebrate' 1.5)) { Set-State 'jump' 190 }
                            }
                        }
                        $script:watchTok = $tk
                    }
                } else {
                    $script:watchAge = 999.0
                }
            } catch { }
        }
        # Keep the bubble up through the small everyday animations: idle (incl. walk and brief
        # fx like hop / look-around), wave, hide (duck), jump, and the work poses. Still hidden
        # during the big "performances" (dance, sleep) and the special modes (dragging, balloon,
        # meteor shower, shadow); heavier states (fall/climb/push/code/...) are not whitelisted.
        $gentleIdle = ((($script:state -eq 'idle') -or ($script:state -eq 'walk')) -and ($script:fx -ne 'doze'))
        $calmPose = (($gentleIdle -or ($script:state -eq 'wave') -or ($script:state -eq 'jump') -or ($script:workStates -contains $script:state) -or (@('celebrate', 'coffee', 'love', 'stretch') -contains $script:state)) -and (-not $script:dragging) -and ($script:balMode -eq 'none') -and (-not $script:starActive) -and ($script:shMode -eq 'none'))
        $maxAge = if ($script:watchTok -eq 'done') { 8.0 } else { 15.0 }
        $fresh  = ($script:watchTok -and ($script:watchAge -lt $maxAge))
        $target = if ($calmPose -and $fresh) { 1.0 } else { 0.0 }
        $script:watchVis += ($target - $script:watchVis) * (1 - [Math]::Pow(0.91, $k))   # slow enough to read the fade
        if ($script:watchVis -lt 0.02 -and $target -eq 0.0) { $script:watchVis = 0 }
        # Only draw while still in a calm pose; if a heavy animation took over, hide at once
        # (no trailing/freezing). watchVis keeps easing to 0 so it fades back in cleanly later.
        if ($calmPose -and $script:watchVis -gt 0.001) { Render-Status }
        elseif ($script:statusOv.Visible) { $script:statusOv.Hide() }
    }

    # Cook-intro played through (on the frame its last frame is over) -> cut to the main cooking loop
    if ($script:state -eq 'cook-intro') {
        $a = $script:anims['cook-intro']
        if (($nowMs - $a.t0 + $script:halfFrameMs) -ge $a.cum[$a.n - 1]) {
            Set-State 'cook' ($script:rand.Next(320, 460))
        }
    }

    # While Claude Code is working, lock Clawd into a work pose that matches the activity (see
    # Start-WorkSession) - it loops until Claude is done, then ends together with the status
    # text. No wandering, dancing, or mischief meanwhile. Everyday poses are interrupted at once
    # (bigger one-off performances are left to finish; the transition picker keeps it going).
    if (Test-AgentWorking) {
        if (-not $script:dragging -and $script:fx -eq 'none' -and $script:balMode -eq 'none' -and -not $script:starActive -and $script:shMode -eq 'none' -and (($script:everydayStates -contains $script:state) -or ($script:workStates -contains $script:state))) {
            Start-WorkSession
        }
    } elseif ($script:workAnim -ne '') {
        # Claude finished and the status text is gone -> end the work animation right now
        $script:workAnim = ''
        $script:busyPick = ''
        if ($script:workStates -contains $script:state) {
            Set-State 'idle' $script:rand.Next($script:idleMinT, $script:idleMaxT)
        }
    }

    # Shooting-star show: update + render; cancel if its state gets taken over by another action
    if ($script:starActive) {
        if ($script:state -eq 'stargaze') { Update-StarShow }
        else { Cancel-StarShow }
    }

    # ===== The Shadow: encounter timeline =====
    if ($script:shMode -eq 'show') {
        $p0 = $script:shT
        $script:shT += $k
        $t2 = $script:shT
        # Fade-in then fade-out (full opacity while shown)
        if ($t2 -le 35) { $script:shForm.Opacity = [Math]::Min(1.0, $t2 / 35.0) }
        elseif ($t2 -ge 480 -and $t2 -le 530) { $script:shForm.Opacity = [Math]::Max(0, 1.0 - ($t2 - 480) / 50.0) }
        elseif ($t2 -lt 480) { $script:shForm.Opacity = 1.0 }
        # Frames: peek out (0-110), stare (110-420), retreat and vanish (420-530)
        $last = $script:shFrames.Count - 1
        if ($t2 -lt 110) {
            $p2 = $t2 / 110.0
            $e2 = $p2 * $p2 * (3 - 2 * $p2)
            $script:shIdx = [int]([Math]::Round($e2 * $script:shPeak))
        } elseif ($t2 -lt 420) {
            $script:shIdx = $script:shPeak
        } else {
            $p2 = [Math]::Min(1.0, ($t2 - 420) / 110.0)
            $e2 = $p2 * $p2 * (3 - 2 * $p2)
            $script:shIdx = [int]($script:shPeak + [Math]::Round($e2 * ($last - $script:shPeak)))
        }
        if ($script:shIdx -gt $last) { $script:shIdx = $last }
        $script:shForm.Invalidate()
        # The good Clawd notices: startled + "!"
        if ($p0 -lt 85 -and $t2 -ge 85) {
            if (-not $script:dragging -and $script:fx -eq 'none') { Start-Fx 'hop' 20 }
            Start-Blink 8
        }
        # Nervous blinking during the staredown
        if ($t2 -ge 110 -and $t2 -lt 420 -and $script:blinkCd -gt 45) { $script:blinkCd = 45 }
        # Shadow vanishes -> confused searching
        if ($p0 -lt 530 -and $t2 -ge 530) {
            $script:shForm.Hide()
            if (($script:state -eq 'idle' -or $script:state -eq 'walk') -and $script:fx -eq 'none') { Start-Fx 'lookaround' 170 }
        }
        if ($t2 -ge 560) { Stop-Shadow }
    }

    $cp = [System.Windows.Forms.Cursor]::Position

    # ===== Dangling from the cursor =====
    if ($script:dragging) {
        if ($script:moved) {
            # Raw cursor velocity (light EMA, in px per logic tick) - sets the throw strength
            $ema = 1 - [Math]::Pow(0.4, $k)
            $script:cvX += ((($cp.X - $script:lastCpX) / $k) - $script:cvX) * $ema
            $script:cvY += ((($cp.Y - $script:lastCpY) / $k) - $script:cvY) * $ema

            # === DRAGGING (easing / inertia lag) ===
            # The anchor (claw) does not stick rigidly to the cursor - it CHASES the cursor with
            # a LERP so it feels like it has mass.
            $chase = 1 - [Math]::Pow(0.65, $k)
            $mvX = ($cp.X - $script:ancX) * $chase
            $mvY = ($cp.Y - $script:ancY) * $chase
            $script:ancX += $mvX
            $script:ancY += $mvY
            $script:ancVX = $mvX / $k
            $script:ancVY = $mvY / $k

            # Spring-damper pendulum (under-damped) driven by the anchor acceleration;
            # the spring stiffens non-linearly at large angles -> never flips a full 360.
            $accX = ($script:ancVX - $script:lastAncVX) / $k
            $stiff = 1.0 + ($script:theta * $script:theta * 1.6)
            $alpha = (-0.0075 * $script:theta * $stiff) - (0.03 * $script:omega) - (0.012 * $accX) - (0.0022 * $script:ancVX)
            $script:omega = [Math]::Max(-0.28, [Math]::Min(0.28, $script:omega + $alpha * $k))
            $script:theta += $script:omega * $k
            if ($script:theta -gt 1.35)  { $script:theta = 1.35;  $script:omega *= 0.5 }   # soft limit ~77 deg
            if ($script:theta -lt -1.35) { $script:theta = -1.35; $script:omega *= 0.5 }
            $script:lastAncVX = $script:ancVX
            $script:form.Location = [System.Drawing.Point]::new([int][Math]::Round($script:ancX - $script:anchorX), [int][Math]::Round($script:ancY - $script:anchorY))
        }
        # Blinking keeps running normally while dangling
        if ($script:blinkTicks -gt 0) { $script:blinkTicks -= $k }
        else {
            $script:blinkCd -= $k
            if ($script:blinkCd -le 0) { Start-Blink 10; $script:blinkCd = $script:rand.Next($script:blinkMinT, $script:blinkMaxT) }
        }
        $script:lastCpX = $cp.X
        $script:lastCpY = $cp.Y
        Update-PetVisual
        return
    }
    if ($cp.X -ne $script:lastCpX -or $cp.Y -ne $script:lastCpY) { $script:cursorMovedAt = $nowMs }
    $script:lastCpX = $cp.X
    $script:lastCpY = $cp.Y

    # Eyes follow the cursor
    $ccx = $script:form.Left + $script:formW / 2.0
    $ccy = $script:form.Top + $script:destH - $script:crabH / 2.0
    $dx = $cp.X - $ccx; $dy = $cp.Y - $ccy
    $tx = [Math]::Max(-1.0, [Math]::Min(1.0, $dx / 240.0)) * 55
    $ty = [Math]::Max(-1.0, [Math]::Min(1.0, $dy / 240.0)) * 35
    if (-not $script:featEyes) { $tx = 0; $ty = 0 }
    # While the balloon descends: eyes lock onto the balloon, not the cursor
    if ($script:balMode -eq 'descend') {
        $dxB = $script:balX - $ccx
        $dyB = ($script:balY + 30) - $ccy
        $tx = [Math]::Max(-1.0, [Math]::Min(1.0, $dxB / 240.0)) * 55
        $ty = [Math]::Max(-1.0, [Math]::Min(1.0, $dyB / 240.0)) * 35
    }
    # Looking around: glance left then right, ignore the cursor for a moment
    if ($script:fx -eq 'lookaround') {
        $p = $script:fxTotal - $script:fxTicks
        if ($p -lt 60) { $tx = -55; $ty = 5 }
        elseif ($p -lt 120) { $tx = 55; $ty = 5 }
    }
    # Focus on the window being shoved
    if ($script:state -eq 'push') {
        $tx = 55.0 * $script:pushSide
        $ty = 5
    }
    # Thinking: eyes drift up toward the thought cloud
    if ($script:state -eq 'think') {
        $tx = $script:propLook[0]; $ty = $script:propLook[1]
    }
    # Eyes locked onto The Shadow at the screen edge
    if ($script:shMode -eq 'show' -and $script:shT -gt 70) {
        $tx = -55.0 * $script:shDir
        $ty = 8
    }
    # Stargazing: eyes follow the meteor crossing the sky
    if ($script:state -eq 'stargaze') {
        $tx = 0; $ty = -38
        if ($null -ne $script:sky -and $script:sky.HasMeteor) {
            $mdx = $script:sky.LastX - $ccx
            $mdy = $script:sky.LastY - $ccy
            $tx = [Math]::Max(-1.0, [Math]::Min(1.0, $mdx / 500.0)) * 55
            $ty = [Math]::Max(-1.0, [Math]::Min(1.0, $mdy / 500.0)) * 38
        }
    }
    $eyeEase = 1 - [Math]::Pow(0.78, $k)
    $script:eyeOX += ($tx - $script:eyeOX) * $eyeEase
    $script:eyeOY += ($ty - $script:eyeOY) * $eyeEase
    $script:cursorNear = ([Math]::Sqrt($dx * $dx + $dy * $dy) -lt 150)

    # Typing -> confused "?" (wakes him if sleeping)
    # Scanning the keyboard 15x/sec is enough (saves ~75% of API calls with no visible difference)
    if ($script:featType -and $script:qmCd -le 0 -and $nowMs -ge $script:nextKeys) {
        $script:nextKeys = $nowMs + 66
        if ([ClawdInput]::AnyKeyDown()) {
            if ($script:fx -eq 'doze') { $script:fx = 'none'; Start-Fx 'hop' 20 }
            $script:qmTicks = 160
            $script:qmCd = 500
            Start-Blink 8
        }
    }

    # Blink (while sleeping the eyes stay closed)
    if ($script:fx -eq 'doze') { if ($script:blinkTicks -lt 2) { $script:blinkTicks = 2; $script:blinkLen = 99 } }
    elseif ($script:blinkTicks -gt 0) { $script:blinkTicks -= $k }
    elseif ($script:state -ne 'wave' -and $script:state -ne 'jump') {
        $script:blinkCd -= $k
        if ($script:blinkCd -le 0) {
            Start-Blink 10
            $script:blinkCd = $script:rand.Next($script:blinkMinT, $script:blinkMaxT)
        }
    }

    if ($script:fxTicks -gt 0) {
        $script:fxTicks -= $k
        if ($script:fxTicks -le 0) {
            if ($script:fx -eq 'doze') {
                $script:fx = 'none'
                if (-not ($script:state -eq 'idle' -and (Start-Extra 'stretch' 1))) { Start-Fx 'hop' 20 }
            }
            else {
                if ($script:fx -eq 'hop') { Start-Pulse 0.09 }   # land the hop with a little squash
                $script:fx = 'none'
            }
        }
    }

    # Thinking: every so often an idea strikes ("!" in the cloud) and he hops
    if ($script:state -eq 'think') {
        $ph1 = ($script:globalT - $script:actT0 - 11) % 260
        $ph0 = $ph1 - $k
        if ($ph0 -lt 200 -and $ph1 -ge 200 -and $script:fx -eq 'none') { Start-Fx 'hop' 18 }
    }

    # ===== Balloon logic =====
    if ($script:balMode -eq 'descend') {
        if ($script:state -ne 'walk') { Cancel-Balloon }
        else {
            $bs = $script:destW / 80.0
            $script:balY += 0.9 * $bs * $k
            # Natural wind (same strength as the rise): decaying random wander + two gusts
            $script:balWind = ($script:balWind + ($script:rand.NextDouble() - 0.5) * 0.16 * $sk) * [Math]::Pow(0.975, $k)
            $script:balWind = [Math]::Max(-1.5, [Math]::Min(1.5, $script:balWind))
            $script:balX += ($script:balWind + 0.6 * [Math]::Sin($script:globalT * 0.019) + 0.35 * [Math]::Sin($script:globalT * 0.047)) * $k
            # Soft edge: near the screen border the wind is gently pushed back so the
            # balloon curves away - instead of being pinned to a vertical wall line.
            $soft = 90
            if ($script:balX -lt ($script:wa.Left + $soft))  { $script:balWind += 0.07 * $k }
            if ($script:balX -gt ($script:wa.Right - $soft)) { $script:balWind -= 0.07 * $k }
            $script:balX = [Math]::Max(($script:wa.Left + 8), [Math]::Min(($script:wa.Right - 8), $script:balX))
            $script:balForm.Location = [System.Drawing.Point]::new([int]($script:balX - 35), [int]$script:balY)
            $script:balForm.Invalidate()
            $stringBot = $script:balY + (44 + 30) * $bs + 6
            $armX = $script:form.Left + $script:margin + $script:armLX
            $armY = $script:form.Top + $script:armLY
            if ($stringBot -ge $armY -and [Math]::Abs($script:balX - $armX) -lt 26) {
                # CAUGHT! enter the lift-off phase: slowly pulled upward
                $script:balForm.Hide()
                $script:balMode = 'lift'
                $script:balT = 0
                $script:theta = 0; $script:omega = 0
                $script:balVY = 0
                $script:onPlat = $false
                $w2 = $script:dragW
                $h2 = $script:dragH + [int](80 * $bs)
                $script:form.ClientSize = [System.Drawing.Size]::new($w2, $h2)
                $pivY2 = (8 + 44 * $bs) + (30 * $bs)
                $script:form.Location = [System.Drawing.Point]::new([int]($armX - $w2 / 2), [int]($armY - $pivY2))
                $script:balDriftX = [double]$script:form.Left
                $script:balPosY   = [double]$script:form.Top
                $script:balLastDX = 0
                Set-State 'balloon' 9999
                Update-PetVisual
            } elseif (($script:balY + 44 * $bs) -ge (($script:bottomY + $script:destH) - 6)) {
                Cancel-Balloon   # balloon landed too soon
            }
        }
    }
    elseif ($script:balMode -eq 'lift') {
        # Lift-off: pulled up slowly, body rotation handled in Paint
        $script:balT += $k
        $p = [Math]::Min(1.0, $script:balT / 55.0)
        $e = $p * $p * (3 - 2 * $p)
        $script:balPosY += (-0.7 * $e) * $k
        $drift = 0.3 * [Math]::Sin($script:globalT * 0.03)
        $script:balDriftX += $drift * $k
        $script:balLastDX = $drift
        $script:form.Location = [System.Drawing.Point]::new([int][Math]::Round($script:balDriftX), [int][Math]::Round($script:balPosY))
        if ($script:balT -ge 55) {
            $script:balMode = 'float'
            $script:balT = 0
            $script:balVY = -0.7
            $script:theta = 0
            $script:omega = 0.02   # a little initial swing to keep it alive
        }
        Update-PetVisual
        return
    }
    elseif ($script:balMode -eq 'float') {
        $script:balT += $k
        $script:balVY = [Math]::Max(-1.4, $script:balVY - 0.02 * $k)   # rises faster, smoothly
        # Natural wind (no fixed path): decaying random walk + two gusts of different frequency
        $script:balWind = ($script:balWind + ($script:rand.NextDouble() - 0.5) * 0.16 * $sk) * [Math]::Pow(0.975, $k)
        $script:balWind = [Math]::Max(-1.5, [Math]::Min(1.5, $script:balWind))
        $fw = $script:form.Width
        $crabX = $script:balDriftX + $fw / 2.0
        if ($crabX -lt ($script:wa.Left + 80))  { $script:balWind += 0.05 * $k }   # soft push off the edges
        if ($crabX -gt ($script:wa.Right - 80)) { $script:balWind -= 0.05 * $k }
        $drift = $script:balWind + 0.5 * [Math]::Sin($script:globalT * 0.017) + 0.3 * [Math]::Sin($script:globalT * 0.041)
        $accX = ($drift - $script:balLastDX) / $k
        $script:balLastDX = $drift
        $script:balDriftX += $drift * $k
        $crabX = $script:balDriftX + $fw / 2.0   # hard clamp keeps the crab on screen (gentle, ~24px)
        if ($crabX -lt ($script:wa.Left + 24))  { $script:balDriftX = $script:wa.Left + 24 - $fw / 2.0 }
        if ($crabX -gt ($script:wa.Right - 24)) { $script:balDriftX = $script:wa.Right - 24 - $fw / 2.0 }
        # Pendulum at the end of the string
        $stiff = 1.0 + ($script:theta * $script:theta * 1.6)
        $alpha = (-0.0075 * $script:theta * $stiff) - (0.03 * $script:omega) - (0.012 * $accX)
        $script:omega = [Math]::Max(-0.28, [Math]::Min(0.28, $script:omega + $alpha * $k))
        $script:theta += $script:omega * $k
        $script:balPosY += $script:balVY * $k
        $script:form.Location = [System.Drawing.Point]::new([int][Math]::Round($script:balDriftX), [int][Math]::Round($script:balPosY))
        if ($script:form.Top -le ($script:wa.Top + [int]($script:wa.Height * 0.16)) -or $script:balT -gt 480) {
            $script:balMode = 'pop'
            $script:balPopT = 0
        }
        Update-PetVisual
        return
    }
    elseif ($script:balMode -eq 'pop') {
        $script:balPopT += $k
        if ($script:balPopT -ge 13) {
            # Done popping -> back to the normal layout then free-fall
            $bs = $script:destW / 80.0
            $pivY2 = (8 + 44 * $bs) + (30 * $bs)
            $bodyX = $script:form.Left + $script:form.ClientSize.Width / 2.0 + 40 * [Math]::Sin($script:theta)
            $bodyY = $script:form.Top + $pivY2 + 40 * [Math]::Cos($script:theta)
            $script:form.ClientSize = [System.Drawing.Size]::new($script:formW, $script:destH)
            $newLeft = [Math]::Max($script:wa.Left, [Math]::Min(($script:wa.Right - $script:formW), [int]($bodyX - $script:formW / 2)))
            $newTop  = [Math]::Max($script:wa.Top, [int]($bodyY - ($script:destH - $script:crabH / 2.0)))
            $script:form.Location = [System.Drawing.Point]::new($newLeft, $newTop)
            $script:posX = [double]$newLeft
            $script:posY = [double]$newTop
            $script:fallVX = $script:balLastDX * 2
            $script:vy = 0
            $script:balMode = 'none'
            Set-State 'fall' 9999
        }
        Update-PetVisual
        return
    }

    # System awareness: check CPU & user idle every ~3 seconds
    if ($script:featSys -and $nowMs -ge $script:nextSys) {
        $script:nextSys = $nowMs + 3000
        $script:cpuEMA = 0.6 * $script:cpuEMA + 0.4 * [ClawdInput]::CpuPercent()
        $idleSec = [ClawdInput]::IdleSeconds()
        $prevMode = $script:sysMode
        if ($script:cpuEMA -gt 75) { $script:sysMode = 'busy' }
        elseif ($idleSec -gt 90)   { $script:sysMode = 'sleepy' }
        else                       { $script:sysMode = 'normal' }
        # User returns after a long idle -> wakes up startled
        if ($prevMode -eq 'sleepy' -and $script:sysMode -ne 'sleepy') {
            if ($script:fx -eq 'doze') { $script:fx = 'none'; Start-Fx 'hop' 20 }
        }
        # Just went idle -> hand unused pages back to the OS (lighter in the background)
        if ($prevMode -ne 'sleepy' -and $script:sysMode -eq 'sleepy') {
            [System.GC]::Collect(); [ClawdWin]::TrimMemory()
        }
    }

    # Platform window list refreshed periodically (0.6s) + floor detection
    if ($nowMs -ge $script:nextPlat) {
        $script:nextPlat = $nowMs + 600
        if ($script:featPlat) { $script:platforms = [ClawdWin]::PlatformsArr($script:selfHwnd) }
        else { $script:platforms = @() }

        # Dynamic floor: a fullscreen game hides the taskbar -> floor = bottom of the screen;
        # otherwise floor = top edge of the taskbar (working area)
        # (monitors can be unplugged or rearranged: re-read his monitor, or fall back to the primary)
        $cur = [System.Windows.Forms.Screen]::PrimaryScreen
        foreach ($s in [System.Windows.Forms.Screen]::AllScreens) { if ($s.DeviceName -eq $script:scr.DeviceName) { $cur = $s } }
        if ($cur.DeviceName -ne $script:scr.DeviceName -and -not $script:dragging) {
            # His monitor is gone: drop him in from the top of the primary one
            $script:scr = $cur
            $script:posX = [double]($cur.WorkingArea.Left + ($cur.WorkingArea.Width - $script:formW) / 2)
            $script:posY = [double]$cur.WorkingArea.Top
            $script:onPlat = $false
            $script:form.Location = [System.Drawing.Point]::new([int]$script:posX, [int]$script:posY)
            if ($script:state -ne 'fall') { $script:vy = 0; $script:fallVX = 0; Set-State 'fall' 9999 }
        }
        $script:scr = $cur
        $script:wa = $cur.WorkingArea
        $bnd = $cur.Bounds
        $floorBottom = $script:wa.Bottom
        if ([ClawdWin]::IsFullscreenForeground($bnd.Left, $bnd.Top, $bnd.Right, $bnd.Bottom)) {
            $floorBottom = $bnd.Bottom
        }
        $newBottomY = $floorBottom - $script:destH
        if ($newBottomY -ne $script:bottomY) {
            $oldB = $script:bottomY
            $script:bottomY = $newBottomY
            # Ground drops (taskbar gone) -> fall smoothly to the new bottom
            if ($newBottomY -gt $oldB -and -not $script:onPlat -and -not $script:dragging -and
                $script:balMode -eq 'none' -and ($script:state -eq 'idle' -or $script:state -eq 'walk' -or $script:state -eq 'wave' -or $script:state -eq 'jump')) {
                $script:posY = [double]$script:form.Top
                $script:posX = [double]$script:form.Left
                $script:vy = 0; $script:fallVX = 0
                if ($script:fx -ne 'none') { $script:fx = 'none'; $script:fxTicks = 0 }
                Set-State 'fall' 9999
            }
            # Ground rises (taskbar back) -> the supportY sync below will lift him
        }
    }

    # === FLOATING / FALLING (semi-implicit Euler, scaled by the frame's real duration) ===
    # Holy Trinity: acceleration (gravity) -> velocity -> position, every frame.
    if ($script:state -eq 'fall') {
        $oldFeet = $script:posY + $script:destH
        $drag = [Math]::Pow(0.995, $k)   # air drag
        $script:vy += (0.8 * $script:cfgGrav) * $k   # gravity
        $script:fallVX *= $drag
        $script:vy *= $drag
        $script:posX += $script:fallVX * $k
        $script:posY += $script:vy * $k

        # Thrown hard against a side with another monitor beyond it: fly on into that monitor
        $maxX = $script:wa.Right - $script:formW
        $side = 0
        if ($script:posX -ge $maxX -and $script:fallVX -gt 2) { $side = 1 }
        elseif ($script:posX -le $script:wa.Left -and $script:fallVX -lt -2) { $side = -1 }
        if ($side -ne 0) {
            $nb = Get-NeighbourScreen $side ($script:posY + $script:destH - $script:crabH / 2.0)
            if ($null -ne $nb) {
                $over = if ($side -gt 0) { $script:posX - $maxX } else { $script:wa.Left - $script:posX }
                Set-PetScreen $nb $true
                $script:posX = if ($side -gt 0) { $script:wa.Left + $over } else { $script:wa.Right - $script:formW - $over }
                $script:posY = [Math]::Max([double]$script:wa.Top, [Math]::Min($script:posY, [double]$script:bottomY))
                $oldFeet = $script:posY + $script:destH
                $maxX = $script:wa.Right - $script:formW
            }
        }

        # Walls & ceiling: bounce with restitution
        if ($script:posX -le $script:wa.Left) { $script:posX = $script:wa.Left; $script:fallVX = [Math]::Abs($script:fallVX) * 0.5 }
        if ($script:posX -ge $maxX) { $script:posX = $maxX; $script:fallVX = -[Math]::Abs($script:fallVX) * 0.5 }
        if ($script:posY -lt $script:wa.Top) { $script:posY = $script:wa.Top; $script:vy = [Math]::Abs($script:vy) * 0.4 }

        # Top edge of an app window = platform: he can land on it
        $landT = $null; $landH = [long]0
        if ($script:vy -gt 0) {
            $newFeet = $script:posY + $script:destH
            $crabL = $script:posX + $script:margin + 6
            $crabR = $script:posX + $script:formW - $script:margin - 6
            for ($i = 0; $i -lt $script:platforms.Length; $i += 5) {
                $T = $script:platforms[$i + 2]
                if ($T -le ($script:wa.Top + 20) -or $T -ge $script:wa.Bottom) { continue }
                if ($oldFeet -le ($T + 2) -and $newFeet -ge $T -and $crabR -ge $script:platforms[$i + 1] -and $crabL -le $script:platforms[$i + 3]) {
                    if ($null -eq $landT -or $T -lt $landT) { $landT = $T; $landH = $script:platforms[$i] }
                }
            }
        }

        $surfaceY = $script:bottomY
        $hitSurface = $false
        if ($null -ne $landT) {
            $surfaceY = $landT - $script:destH
            $hitSurface = $true
        } elseif ($script:posY -ge $script:bottomY) {
            $hitSurface = $true
        }

        if ($hitSurface) {
            $script:posY = $surfaceY
            if ($script:vy -gt 4.5) {
                # Bounce with restitution + friction
                $script:vy = -$script:vy * 0.32
                $script:fallVX *= 0.85
                Start-Fx 'squash' 12
            } else {
                $script:vy = 0
                $script:fallVX *= [Math]::Pow(0.85, $k)
                if ([Math]::Abs($script:fallVX) -lt 0.6) {
                    # Anti-jitter settle -> land on this platform
                    $script:fallVX = 0
                    $script:supportY = $script:posY
                    $script:onPlat = ($null -ne $landT)
                    if ($script:onPlat) { $script:platHwnd = $landH }
                    Start-Fx 'squash' 18
                    Set-State 'jump' 275
                }
            }
        }
        $script:form.Location = [System.Drawing.Point]::new([int][Math]::Round($script:posX), [int][Math]::Round($script:posY))
        Update-PetVisual
        return
    }

    # ===== Climbing the wall: phase machine =====
    if ($script:state -eq 'climb') {
        $half = $script:climbSide / 2.0
        $feetOff = $script:crabH / 2.0
        $wallRot = 90.0 * $script:climbWall
        $targetX = $script:wa.Left - ($half - $feetOff)
        if ($script:climbWall -lt 0) { $targetX = $script:wa.Right - ($half + $feetOff) }
        $slide = 1 - [Math]::Pow(0.82, $k)
        switch ($script:climbPhase) {
            'in' {
                # Rotating from standing to clinging to the wall
                $script:climbT += $k
                $p = [Math]::Min(1.0, $script:climbT / 22.0)
                $e = $p * $p * (3 - 2 * $p)
                $script:climbRot = $wallRot * $e
                $script:climbX += ($targetX - $script:climbX) * $slide
                if ($script:climbT -ge 22) { $script:climbX = $targetX; $script:climbPhase = 'up' }
            }
            'up' {
                $script:climbY -= 0.5 * $k
                Step-Legs
                if ($script:climbY -le $script:climbTarget) {
                    $script:climbPhase = 'pause'
                    $script:climbT = $script:rand.Next(90, 240)
                    $script:legFrame = 0
                }
            }
            'pause' {
                $script:climbT -= $k
                if ($script:climbT -le 0) {
                    if ($script:rand.NextDouble() -lt 0.5) {
                        $script:climbPhase = 'down'
                    } else {
                        Stop-Climb $true   # jump off the wall!
                        return
                    }
                }
            }
            'down' {
                $script:climbY += 0.55 * $k
                Step-Legs
                $floorCY = $script:bottomY + $script:destH - $script:crabH / 2.0
                if ($script:climbY -ge $floorCY) {
                    $script:climbY = $floorCY
                    $script:climbPhase = 'out'
                    $script:climbT = 0
                    $script:legFrame = 0
                }
            }
            'out' {
                # Rotating back upright while sliding in from the wall
                $script:climbT += $k
                $p = [Math]::Min(1.0, $script:climbT / 22.0)
                $e = $p * $p * (3 - 2 * $p)
                $script:climbRot = $wallRot * (1 - $e)
                $standCX = $script:wa.Left + $script:margin + $script:destW / 2.0
                if ($script:climbWall -lt 0) { $standCX = $script:wa.Right - $script:margin - $script:destW / 2.0 }
                $script:climbX += (($standCX - $half) - $script:climbX) * $slide
                if ($script:climbT -ge 22) {
                    Stop-Climb $false
                    return
                }
            }
        }
        if ($script:state -eq 'climb') {
            $script:form.Location = [System.Drawing.Point]::new([int][Math]::Round($script:climbX), [int][Math]::Round($script:climbY - $half))
        }
        Update-PetVisual
        return
    }

    # ===== Shoving a window from the side: approach the window edge then shove rhythmically =====
    if ($script:state -eq 'push') {
        $r3 = [ClawdWin]::GetRect($script:pushHwnd)
        if ($null -eq $r3) { Stop-Push; return }
        # Standing position against the window side
        $targetX = $r3[0] - $script:formW + $script:margin   # stand on the left, shove to the right
        if ($script:pushSide -lt 0) { $targetX = $r3[2] - $script:margin }
        switch ($script:pushPhase) {
            'approach' {
                $script:pushT += $k
                $d = $targetX - $script:posX
                if ([Math]::Abs($d) -le 2) {
                    $script:posX = $targetX
                    $script:pushPhase = 'tug'
                    $script:pushT = 0
                    $script:legFrame = 0
                    $script:dir = $script:pushSide   # facing the window
                } elseif ($script:pushT -gt 900) {
                    Stop-Push; return   # took too long (window ran away?) -> give up
                } else {
                    $script:dir = [Math]::Sign($d)
                    $script:posX += $script:dir * [Math]::Min(0.7 * $k, [Math]::Abs($d))
                    Step-Legs
                }
            }
            'tug' {
                $t0 = $script:pushT
                $script:pushT += $k
                $c = $script:pushT % 36
                if ($c -ge 18 -and $c -lt 26) {
                    $room = $false
                    if ($script:pushSide -gt 0 -and ($r3[2] + 2) -lt ($script:wa.Right - 40)) { $room = $true }
                    if ($script:pushSide -lt 0 -and ($r3[0] - 2) -gt ($script:wa.Left + 40)) { $room = $true }
                    if ($room) {
                        $moved = Step-Nudge $script:pushHwnd (2 * $script:pushSide * $k)
                        $script:posX += $moved   # advance along with the shoved window
                        Step-Legs 2
                    } else {
                        Stop-Push; return
                    }
                }
                if ([Math]::Floor($t0 / 36) -ne [Math]::Floor($script:pushT / 36)) {
                    $script:pushTugs++
                    if ($script:pushTugs -ge 4) { Stop-Push; return }
                }
            }
        }
        $script:form.Left = [int][Math]::Round($script:posX)
        $script:form.Top  = [int]$script:bottomY
        Update-PetVisual
        return
    }

    # === Active platform: follow the window movement, fall if it is gone/shifted ===
    if (@('lurk', 'peek', 'enter') -notcontains $script:state) {
        if ($script:onPlat) {
            $r = [ClawdWin]::GetRect($script:platHwnd)
            $drop = $false
            if ($null -eq $r) { $drop = $true }
            else {
                $script:supportY = [double]($r[1] - $script:destH)
                $crabL = $script:posX + $script:margin + 6
                $crabR = $script:posX + $script:formW - $script:margin - 6
                if ($crabR -lt ($r[0] + 10) -or $crabL -gt ($r[2] - 10)) { $drop = $true }
                if ($script:supportY -gt $script:bottomY -or $r[1] -le ($script:wa.Top + 20)) { $drop = $true }
            }
            if ($drop) {
                $script:onPlat = $false
                $script:posY = [double]$script:form.Top
                $script:vy = 0
                $script:fallVX = $script:dir * 1.2
                $script:fx = 'none'; $script:fxTicks = 0
                Set-State 'fall' 9999
                Update-PetVisual
                return
            }
            $script:form.Top = [int]$script:supportY
            # Mischief: tugging the window with a rhythmic YANK (window moves only on the yank)
            if ($script:fx -eq 'shove') {
                $els = $script:fxTotal - $script:fxTicks
                $c = $els % 36
                if ([Math]::Floor($els / 36) -ne [Math]::Floor(($els - $k) / 36)) { $script:legFrame = 0; $script:legWait = 2 }
                if ($c -ge 18 -and $c -lt 26) {
                    $r2 = [ClawdWin]::GetRect($script:platHwnd)
                    $okPush = $false
                    if ($null -ne $r2) {
                        if ($script:shoveDir -gt 0 -and $r2[0] -lt ($script:wa.Right - 280)) { $okPush = $true }
                        if ($script:shoveDir -lt 0 -and $r2[2] -gt ($script:wa.Left + 280)) { $okPush = $true }
                    }
                    if ($okPush) {
                        $moved = Step-Nudge $script:platHwnd ($script:shoveDir * 2 * $k)
                        $script:posX += $moved   # jerk along with the window
                        $script:form.Left = [int][Math]::Round($script:posX)
                        Step-Legs 2
                    } else {
                        $script:fx = 'none'; $script:fxTicks = 0
                    }
                }
            }
        } else {
            $script:supportY = [double]$script:bottomY
            if ($script:fx -eq 'shove') { $script:fx = 'none'; $script:fxTicks = 0 }
            # Sync to the active floor (e.g. taskbar reappears after exiting a game)
            if ($script:state -ne 'fall' -and $script:state -ne 'balloon' -and $script:form.Top -gt [int]$script:supportY) {
                $script:form.Top = [int]$script:supportY
            }
        }
    }

    # ===== Waking up from stand-by: peek from the edge, then step out into the screen =====
    if ($script:state -eq 'peek') {
        $script:ticks -= $k
        if ($script:ticks -le 0) { Start-Enter }
        Update-PetVisual
        return
    }
    if ($script:state -eq 'enter') {
        $script:posX += $script:dir * 1.3 * $script:cfgSpeed * $k
        Step-Legs 2
        $arrived = if ($script:dir -gt 0) { $script:posX -ge $script:enterTarget } else { $script:posX -le $script:enterTarget }
        if (-not $arrived) { Move-Glide $script:posX $script:supportY }
        else {
            $script:form.Location = [System.Drawing.Point]::new([int][Math]::Round($script:enterTarget), [int]$script:supportY)
            $script:posX = $script:enterTarget
            $script:legFrame = 0
            Set-State 'wave' 240   # hello!
        }
        Update-PetVisual
        return
    }

    $ticks0 = $script:ticks
    $script:ticks -= $k
    # Code sequence: start the wave animation right as the typing phase ends
    if ($script:state -eq 'code' -and $ticks0 -gt 175 -and $script:ticks -le 175) {
        Reset-Anim 'wave'
    }
    # Chasing the balloon: walk toward the balloon position (ignore the cursor-near freeze)
    if ($script:state -eq 'walk' -and $script:balMode -eq 'descend') {
        $armX = $script:form.Left + $script:margin + $script:armLX
        $ddx = $script:balX - $armX
        if ([Math]::Abs($ddx) -gt 8) {
            $script:dir = [Math]::Sign($ddx)
            $script:posX += $script:dir * (0.9 * $script:cfgSpeed) * $k
            $maxX = $script:wa.Right - $script:formW
            if ($script:posX -lt $script:wa.Left) { $script:posX = $script:wa.Left }
            if ($script:posX -gt $maxX) { $script:posX = $maxX }
            Move-Glide $script:posX $script:supportY
            Step-Legs 2
        } else {
            $script:legFrame = 0
        }
        Update-PetVisual
        if ($nowMs -ge $script:nextTop) { $script:nextTop = $nowMs + 10000; $script:form.TopMost = $true }
        return
    }
    if ($script:state -eq 'walk' -and -not $script:cursorNear) {
        # Ease-in/ease-out: start slow, speed up, slow down before stopping
        $elapsed = $script:walkTotal - $script:ticks
        $speedF = [Math]::Max(0.0, [Math]::Min(1.0, [Math]::Min(($elapsed + 5) / 35.0, ($script:ticks + 5) / 35.0)))
        $spdMul = 1.0
        if ($script:sysMode -eq 'busy') { $spdMul = 1.9 }   # restless: walks faster
        $script:posX += $script:dir * (0.45 * $script:cfgSpeed * $spdMul) * $speedF * $k
        # Advance the walk cycle (stepping frames only, on an even beat)
        Step-Legs
        $maxX = $script:wa.Right - $script:formW
        if ($script:posX -le $script:wa.Left) {
            $script:posX = $script:wa.Left
            # Reached the left wall: sometimes climbs instead of turning back
            if ($script:featClimb -and -not $script:onPlat -and ($script:wantClimb -or $script:rand.NextDouble() -lt 0.40)) {
                $script:wantClimb = $false
                $script:form.Left = [int]$script:posX
                Start-Climb 1
                return
            }
            if ($script:dir -ne 1) { Start-Pulse 0.05 }   # little bump on turning around
            $script:dir = 1
        }
        if ($script:posX -ge $maxX) {
            $script:posX = $maxX
            if ($script:featClimb -and -not $script:onPlat -and ($script:wantClimb -or $script:rand.NextDouble() -lt 0.40)) {
                $script:wantClimb = $false
                $script:form.Left = [int]$script:posX
                Start-Climb (-1)
                return
            }
            if ($script:dir -ne -1) { Start-Pulse 0.05 }
            $script:dir = -1
        }
        Move-Glide $script:posX $script:supportY   # the window follows at 60 fps (ClawdGlide)
    } elseif ($script:fx -ne 'shove') {
        # Standing: legs return to the neutral pose (unless dragging a window)
        $script:legFrame = 0
        $script:legWait = 2
    }

    if ($script:ticks -le 0) {
        # Claude still working -> keep looping the matching pose; never fall through to idle
        if ((Test-AgentWorking) -and -not $script:dragging -and $script:fx -eq 'none' -and $script:balMode -eq 'none' -and -not $script:starActive -and $script:shMode -eq 'none') {
            Start-WorkSession
            return
        }
        switch ($script:state) {
            'idle' {
                # Rare: a balloon drops from the sky (~3%, only on the floor)
                if ((-not $script:onPlat) -and $script:balMode -eq 'none' -and $script:rand.NextDouble() -lt 0.03) {
                    Start-Balloon
                    return
                }
                # Rare: shooting-star shower (~2.5%) - he stops, gazes at the sky, makes a wish
                if ($script:rand.NextDouble() -lt 0.025) {
                    Start-StarShow
                    return
                }
                # Very rare (~1%): The Shadow peeks from the screen edge
                if ((-not $script:onPlat) -and $script:shMode -eq 'none' -and $script:rand.NextDouble() -lt 0.01) {
                    Start-Shadow
                    return
                }
                # Ambient: when Claude is idle, Clawd still tinkers occasionally (Working/Cooking).
                # While Claude is actually working this is unreachable - that case is handled up top
                # by the lock-in force. Rare (~6% combined), spaced out by busyUntil, alternating.
                if ($script:globalT -ge $script:busyUntil -and $script:rand.NextDouble() -lt 0.06) {
                    Start-BusyNext
                    $script:busyUntil = $script:globalT + $script:ticks + $script:rand.Next(600, 1100)
                    return
                }
                # Mischief: perched on a window? sometimes drags it (~20%)
                if ($script:featMisch -and $script:onPlat -and $script:fx -eq 'none' -and $script:rand.NextDouble() -lt 0.20) {
                    $script:shoveDir = 1
                    if ($script:rand.NextDouble() -lt 0.5) { $script:shoveDir = -1 }
                    Start-Fx 'shove' 110
                    Set-State 'idle' $script:rand.Next($script:idleMinT, $script:idleMaxT)
                    return
                }
                # Mischief: a window nearby on the floor? sometimes shoves it from the side (~10%)
                if ($script:featMisch -and -not $script:onPlat -and $script:fx -eq 'none' -and $script:rand.NextDouble() -lt 0.10) {
                    $pt = Find-PushTarget
                    if ($null -ne $pt) {
                        Start-Push $pt
                        return
                    }
                }
                # Work mode: CPU busy -> pacing restlessly with short pauses
                if ($script:sysMode -eq 'busy') {
                    if ($script:rand.NextDouble() -lt 0.75) {
                        $script:dir *= -1
                        $wdur = $script:rand.Next(120, 280)
                        Set-State 'walk' $wdur
                        $script:walkTotal = $wdur
                    } else {
                        Set-State 'idle' $script:rand.Next(60, 160)   # short restless pause
                    }
                    return
                }
                # Old laptop left alone -> drowsy, dozes off more often
                if ($script:sysMode -eq 'sleepy' -and $script:rand.NextDouble() -lt 0.6) {
                    Start-Fx 'doze' $script:rand.Next(400, 800)
                    Set-State 'idle' $script:rand.Next(($script:idleMaxT), ($script:idleMaxT + 400))
                    return
                }
                # Near the screen edge (on the floor) -> sometimes lurks: peeks from the edge
                $nearL = ($script:posX - $script:wa.Left) -lt 60
                $nearR = (($script:wa.Right - $script:formW) - $script:posX) -lt 60
                if ($script:featLurk -and (-not $script:onPlat) -and ($nearL -or $nearR) -and $script:rand.NextDouble() -lt 0.45) {
                    $script:lurkDir = 1
                    if ($nearR) { $script:lurkDir = -1; $script:posX = [double]($script:wa.Right - $script:formW) }
                    else        { $script:posX = [double]$script:wa.Left }
                    $script:form.Left = [int]$script:posX
                    $script:form.Top  = [int]$script:supportY
                    Set-State 'lurk' 430   # peek out ~7s
                    return
                }
                $r = $script:rand.NextDouble()
                # The extra animations take a slice first (each falls through if its GIF is missing)
                if ($r -lt 0.15) {
                    $x = $script:rand.NextDouble()
                    $ok = if ($x -lt 0.45) { Start-Extra 'coffee' 2 }    # coffee break ~7%
                          elseif ($x -lt 0.65) { Start-Extra 'nap' 1 }   # a nap with a bubble ~3%
                          elseif ($x -lt 0.85) { Start-Extra 'stretch' 1 }   # stretch ~3%
                          else { Start-Extra 'sneeze' 1 }                # sneeze ~2%
                    if ($ok) { return }
                    $r = 0.15 + $script:rand.NextDouble() * 0.85
                }
                $r = ($r - 0.15) / 0.85   # the classic picks below, in their original proportions
                if ($r -lt 0.30) {   # wander 30%
                    if ($script:rand.NextDouble() -lt 0.5) { $script:dir *= -1 }
                    $wdur = $script:rand.Next(250, 560)   # walk 4-9s
                    Set-State 'walk' $wdur
                    $script:walkTotal = $wdur
                } elseif ($r -lt 0.43) {
                    Set-State 'wave' 240   # wave 13%
                } elseif ($r -lt 0.55) {
                    Set-State 'jump' 190   # jump 12%
                } elseif ($r -lt 0.64) {
                    Set-State 'dance' $script:rand.Next(280, 380)   # dance 9% (~4.5-6s of the GIF)
                } elseif ($r -lt 0.72) {
                    Start-Fx 'lookaround' 170   # look around 8%
                    Set-State 'idle' $script:rand.Next($script:idleMinT, $script:idleMaxT)
                } elseif ($r -lt 0.78) {
                    Set-State 'code' 380   # hello world 6%
                } elseif ($r -lt 0.89) {
                    Set-State 'think' $script:rand.Next(280, 380)   # ponders 11%
                } elseif ($r -lt 0.97) {
                    Start-Fx 'duck' 300   # hide 4%
                    Set-State 'idle' $script:rand.Next(($script:idleMinT + 60), ($script:idleMaxT + 65))
                } else {
                    Start-Fx 'doze' 320   # doze off 3%
                    Set-State 'idle' $script:rand.Next(($script:idleMinT + 80), ($script:idleMaxT + 85))
                }
            }
            default {
                Set-State 'idle' $script:rand.Next($script:idleMinT, $script:idleMaxT)   # idle 5-10s
            }
        }
    }

    # Nothing is sent to the compositor when the frame is pixel-identical (see StarOverlay.Render)
    Update-PetVisual

    if ($nowMs -ge $script:nextTop) { $script:nextTop = $nowMs + 10000; $script:form.TopMost = $true }
}

$script:clock = New-Object ClawdClock($script:form)
$script:clock.BaseUs = $script:frameUs
$script:clock.PeriodUs = $script:frameUs
$script:clock.Glide = $script:glide
# -PerfLog: per pose, how many script frames a second ran and what each cost (ms), plus the whole
# process's CPU (% of one core) - one JSON line every 5 s. Measures onTick + onPace together.
if ($PerfLog) {
    $script:perf = @{ t = 0L; at = -1.0; cpu = 0.0; states = @{}; startupMs = 0 }
    $script:clock.Add_Tick({ $script:perf.t = [System.Diagnostics.Stopwatch]::GetTimestamp() })
}
$script:clock.Add_Tick($script:onTick)
$script:clock.Add_Tick($script:onPace)
if ($PerfLog) {
    $script:clock.Add_Tick({
        $p = $script:perf
        $ms = ([System.Diagnostics.Stopwatch]::GetTimestamp() - $p.t) * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency
        $proc = [System.Diagnostics.Process]::GetCurrentProcess()
        if ($p.at -lt 0) {
            $p.at = $script:nowMs; $p.cpu = $proc.TotalProcessorTime.TotalMilliseconds
            $p.startupMs = [int]([DateTime]::Now - $proc.StartTime).TotalMilliseconds
            return
        }
        $key = if ($script:glide.Active) { "$($script:state)+glide" } else { $script:state }
        $s = $p.states[$key]
        if ($null -eq $s) { $s = @{ n = 0; ms = 0.0; max = 0.0; time = 0.0 }; $p.states[$key] = $s }
        $s.n++; $s.ms += $ms; $s.time += $script:k * $script:tickMs
        if ($ms -gt $s.max) { $s.max = $ms }
        if (($script:nowMs - $p.at) -ge 5000) {
            $cpu = $proc.TotalProcessorTime.TotalMilliseconds
            $rows = foreach ($k2 in $p.states.Keys) {
                $v = $p.states[$k2]
                [ordered]@{ state = $k2; fps = [Math]::Round(1000 * $v.n / [Math]::Max(1, $v.time), 1)
                            msAvg = [Math]::Round($v.ms / $v.n, 2); msMax = [Math]::Round($v.max, 1) }
            }
            $line = [ordered]@{ startupMs = $p.startupMs; cpuPct = [Math]::Round(100 * ($cpu - $p.cpu) / ($script:nowMs - $p.at), 1); states = @($rows) }
            try { [IO.File]::AppendAllText($PerfLog, ($line | ConvertTo-Json -Compress -Depth 4) + [Environment]::NewLine) } catch { }
            $p.at = $script:nowMs; $p.cpu = $cpu; $p.states = @{}
        }
    })
}

# ---------- Mouse interaction ----------
$script:form.Add_MouseEnter({
    if ($script:fx -eq 'doze') {
        $script:fx = 'none'
        Start-Fx 'hop' 20
        $script:hoverCd = 500
        return
    }
    if (($script:state -eq 'idle' -or $script:state -eq 'walk') -and $script:fx -eq 'none' -and $script:hoverCd -le 0) {
        # A little affection: hearts and rosy cheeks (a startled hop if that GIF is missing)
        if (-not (Start-Extra 'love' 1)) { Start-Fx 'hop' 20; Start-Blink 8 }
        $script:hoverCd = 500
    }
})
$script:form.Add_MouseDown({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if ($script:state -eq 'balloon') {
            # Grabbed while floating: the balloon lets go and drifts up & away on its own,
            # the crab drops into your grip at its current body position.
            $bs2 = $script:destW / 80.0
            $pivY2 = (8 + 44 * $bs2) + (30 * $bs2)
            $balCX  = $script:form.Left + $script:form.ClientSize.Width / 2.0   # balloon was at top-center
            $balTop = $script:form.Top + 8
            $bodyX = $script:form.Left + $script:form.ClientSize.Width / 2.0 + 40 * [Math]::Sin($script:theta)
            $bodyY = $script:form.Top + $pivY2 + 40 * [Math]::Cos($script:theta)
            $script:balMode = 'none'
            $script:form.ClientSize = [System.Drawing.Size]::new($script:formW, $script:destH)
            $script:form.Location = [System.Drawing.Point]::new([int]($bodyX - $script:formW / 2), [int]($bodyY - ($script:destH - $script:crabH / 2.0)))
            $script:posX = [double]$script:form.Left
            $script:posY = [double]$script:form.Top
            Set-State 'idle' $script:rand.Next($script:idleMinT, $script:idleMaxT)
            Update-PetVisual
            # let the freed balloon float off by itself (separate window, drifts up + wind)
            $script:balEscX   = [double]$balCX
            $script:balEscY   = [double]$balTop
            $script:balEscVY  = -1.2
            $script:balEscWind = $script:balLastDX * 3.0
            $script:balForm.ClientSize = [System.Drawing.Size]::new(70, [int]((44 + 34) * $bs2 + 14))
            $script:balForm.Location = [System.Drawing.Point]::new([int]($balCX - 35), [int]($balTop - 4))
            $script:balForm.Show(); $script:balForm.TopMost = $true
            $script:balEscape = $true
            # continue to the drag setup below
        }
        if ($script:state -eq 'climb') { Stop-Climb $false }   # taken off the wall: climb down first
        if ($script:starActive) { Cancel-StarShow; Set-State 'idle' $script:rand.Next($script:idleMinT, $script:idleMaxT) }
        if ($script:balMode -eq 'descend') { Cancel-Balloon }   # cancel the balloon chase
        $script:glide.Stop()   # the drag owns the window from here
        $script:dragging  = $true
        $script:moved     = $false
        $script:dragOff   = $_.Location
        $script:dragStart = [System.Windows.Forms.Cursor]::Position
        $script:lastCpX   = $script:dragStart.X
        $script:lastCpY   = $script:dragStart.Y
        $script:lastVelX  = 0
        $script:lastVelY  = 0
        $script:theta     = 0
        $script:omega     = 0
    }
})
$script:form.Add_MouseMove({
    if ($script:dragging) {
        $p = [System.Windows.Forms.Cursor]::Position
        if (-not $script:moved) {
            if ([Math]::Abs($p.X - $script:dragStart.X) -gt 5 -or [Math]::Abs($p.Y - $script:dragStart.Y) -gt 5) {
                # Start dangling: the window grows so the swing is not clipped.
                # The next position is driven by the timer (easing), not MouseMove.
                $script:moved = $true
                $script:ancX = [double]$p.X
                $script:ancY = [double]$p.Y
                $script:ancVX = 0; $script:ancVY = 0; $script:lastAncVX = 0
                $script:cvX = 0; $script:cvY = 0
                $script:onPlat = $false
                if ($script:fx -eq 'doze' -or $script:fx -eq 'duck') { $script:fx = 'none'; $script:fxTicks = 0 }
                # Resize + position + paint in sync, in one breath:
                # prevents a single dirty frame (old sprite + black area) from showing
                $script:form.ClientSize = [System.Drawing.Size]::new($script:dragW, $script:dragH)
                $script:form.Location = [System.Drawing.Point]::new([int]($p.X - $script:anchorX), [int]($p.Y - $script:anchorY))
                Update-PetVisual
            }
        }
    }
})
$script:form.Add_MouseUp({
    if ($_.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $script:dragging = $false
    if ($script:moved) {
        # === VELOCITY TRANSFER (handover) ===
        # The eased anchor velocity is handed to the body right at release - the throw
        # matches the motion you saw. The body position is preserved
        # (computed from anchor + hang direction) so the transition is smooth.
        $script:form.ClientSize = [System.Drawing.Size]::new($script:formW, $script:destH)
        $bodyX = $script:ancX + 40.0 * [Math]::Sin($script:theta)
        $bodyY = $script:ancY + 40.0 * [Math]::Cos($script:theta)
        # He now lives on the monitor he was dropped on (the nearest one if dropped in a gap)
        $drop = Get-ScreenAt $bodyX $bodyY
        if ($null -eq $drop) { $drop = [System.Windows.Forms.Screen]::FromPoint([System.Drawing.Point]::new([int]$bodyX, [int]$bodyY)) }
        Set-PetScreen $drop $true
        $newLeft = [Math]::Max($script:wa.Left, [Math]::Min($script:wa.Right - $script:formW, [int]($bodyX - $script:formW / 2)))
        $newTop  = [Math]::Min($script:bottomY, [int]($bodyY - ($script:destH - $script:crabH / 2.0)))
        $newTop  = [Math]::Max($script:wa.Top, $newTop)
        $script:form.Location = [System.Drawing.Point]::new($newLeft, $newTop)
        Update-PetVisual
        $script:posX = [double]$newLeft
        $script:posY = [double]$newTop
        # Throw strength = the real cursor velocity at release
        $script:fallVX = [Math]::Max(-45.0, [Math]::Min(45.0, $script:cvX * 0.9))
        $script:vy     = [Math]::Max(-45.0, [Math]::Min(45.0, $script:cvY * 0.9))
        if ($newTop -lt ($script:bottomY - 4) -or [Math]::Abs($script:fallVX) -gt 1.5 -or $script:vy -lt -1.5) {
            Set-State 'fall' 9999
        } else {
            $script:form.Top = $script:bottomY
            $script:fallVX = 0
            $script:vy = 0
            Set-State 'idle' $script:rand.Next($script:idleMinT, $script:idleMaxT)
        }
    } else {
        $script:posX = [double]$script:form.Left
        $r = $script:rand.NextDouble()
        if ($r -lt 0.40)     { Set-State 'wave' 240 }
        elseif ($r -lt 0.75) { Set-State 'jump' 190 }
        else                 { Set-State 'dance' $script:rand.Next(280, 380) }
    }
})

# ---------- Actions (shared by the right-click menu and the tray menu) ----------
# Calm enough to switch to a new pose (not mid-throw, mid-climb, on a balloon...)
function Test-CanPose {
    return (-not $script:dragging -and $script:balMode -eq 'none' -and -not $script:starActive -and
            @('idle', 'walk', 'wave', 'jump', 'dance', 'work', 'cook', 'cook-intro', 'think', 'lurk', 'coffee', 'magnifier', 'celebrate', 'love', 'sneeze', 'stretch', 'nap') -contains $script:state)
}
$script:actions = [ordered]@{
    'Wave'            = { if (Test-CanPose) { Set-State 'wave' 240 } }
    'Dance'           = { if (Test-CanPose) { Set-State 'dance' 340 } }
    'Think'           = { if (Test-CanPose) { Set-State 'think' 380 } }
    'Hello World!'    = { if (Test-CanPose) { Set-State 'code' 380 } }
    'Working'         = { if (Test-CanPose) { $script:lastBusy = 'work'; Set-State 'work' 460 } }
    'Cooking'         = { if (Test-CanPose) { $script:lastBusy = 'cook'; Set-State 'cook-intro' 50 } }
    'Hide'            = { if (Test-CanPose) { Start-Fx 'duck' 300; Set-State 'idle' 500 } }
    'Sleep'           = { if (Test-CanPose) { Start-Fx 'doze' 320; Set-State 'idle' 500 } }
    'Nap'             = { if (Test-CanPose) { $script:fx = 'none'; $null = Start-Extra 'nap' 1 } }
    'Coffee Break'    = { if (Test-CanPose) { $null = Start-Extra 'coffee' 2 } }
    'Search'          = { if (Test-CanPose) { $null = Start-Extra 'magnifier' 2 } }
    'Celebrate'       = { if (Test-CanPose) { $null = Start-Extra 'celebrate' 1.5 } }
    'Love'            = { if (Test-CanPose) { $null = Start-Extra 'love' 2 } }
    'Sneeze'          = { if (Test-CanPose) { $null = Start-Extra 'sneeze' 1 } }
    'Stretch'         = { if (Test-CanPose) { $null = Start-Extra 'stretch' 1 } }
    '-1'              = $null
    'Climb the Wall'  = {
        if (($script:state -eq 'idle' -or $script:state -eq 'walk') -and -not $script:onPlat -and $script:balMode -eq 'none') {
            $script:wantClimb = $true
            $cx2 = $script:form.Left + $script:formW / 2
            $script:dir = 1
            if (($cx2 - $script:wa.Left) -lt (($script:wa.Right - $cx2))) { $script:dir = -1 }   # toward the nearest wall
            Set-State 'walk' 6000
            $script:walkTotal = 6000
        }
    }
    'Drag the Window' = {
        if ($script:onPlat -and $script:fx -eq 'none' -and ($script:state -eq 'idle' -or $script:state -eq 'walk')) {
            $script:shoveDir = 1
            if ($script:rand.NextDouble() -lt 0.5) { $script:shoveDir = -1 }
            Start-Fx 'shove' 110
            Set-State 'idle' $script:rand.Next($script:idleMinT, $script:idleMaxT)
        }
    }
    'Push a Window'   = {
        if ((-not $script:onPlat) -and $script:fx -eq 'none' -and ($script:state -eq 'idle' -or $script:state -eq 'walk') -and $script:balMode -eq 'none') {
            $pt = Find-PushTarget
            if ($null -ne $pt) { Start-Push $pt }
        }
    }
    'Meteor Shower'   = {
        if (-not $script:starActive -and $script:state -ne 'fall' -and $script:state -ne 'balloon' -and -not $script:dragging) {
            Start-StarShow
        }
    }
    'Balloon Ride'    = {
        if ($script:balMode -eq 'none' -and $script:state -ne 'fall' -and -not $script:dragging -and -not $script:onPlat) {
            Start-Balloon
        }
    }
    'The Shadow'      = { Start-Shadow }
}
# Only offer the extra animations whose GIF is actually there
foreach ($pair in @(@('Nap', 'nap'), @('Coffee Break', 'coffee'), @('Search', 'magnifier'), @('Celebrate', 'celebrate'),
                    @('Love', 'love'), @('Sneeze', 'sneeze'), @('Stretch', 'stretch'))) {
    if (-not $script:anims.ContainsKey($pair[1])) { $script:actions.Remove($pair[0]) }
}

# ---------- Menus (Claude-style dark theme) ----------
$script:menuFore = [System.Drawing.Color]::FromArgb(236, 231, 223)
$script:menuBack = [System.Drawing.Color]::FromArgb(38, 36, 33)
$script:menuRenderer = New-Object ClawdMenuRenderer
function Set-MenuStyle($strip) {
    $strip.Renderer  = $script:menuRenderer
    $strip.BackColor = $script:menuBack
    $strip.ForeColor = $script:menuFore
    $strip.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
}
function Add-MenuItem($items, [string]$text, [scriptblock]$onClick) {
    if ($text -like '-*') { $null = $items.Add((New-Object System.Windows.Forms.ToolStripSeparator)); return $null }
    $it = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    $it.ForeColor = $script:menuFore
    if ($onClick) { $it.Add_Click($onClick) }
    $null = $items.Add($it)
    return $it
}
function Add-ActionItems($items) {
    foreach ($name in $script:actions.Keys) { $null = Add-MenuItem $items $name $script:actions[$name] }
}

# Right-click on Clawd
$menu = New-Object System.Windows.Forms.ContextMenuStrip
Set-MenuStyle $menu
$menu.ShowImageMargin = $false
Add-ActionItems $menu.Items
$null = Add-MenuItem $menu.Items '-' $null
$null = Add-MenuItem $menu.Items 'Bye Clawd (quit)' { Exit-Clawd }
# Foreground the menu once it's shown so a click anywhere outside dismisses it
# (the pet window is NoActivate, which otherwise breaks click-away-to-close).
$menu.Add_Opened({ [ClawdWin]::SetForeground($menu.Handle.ToInt64()) })
$script:form.ContextMenuStrip = $menu

# ---------- Settings persistence (clawd.json) ----------
# Small in-place edits so the user's own formatting and keys are kept as they are.
function Save-CfgValue([string]$key, [string]$jsonValue, [string]$section = '') {
    try {
        $txt = if (Test-Path $cfgPath) { [IO.File]::ReadAllText($cfgPath) } else { "{`n}" }
        $pat = '("' + [regex]::Escape($key) + '"\s*:\s*)("[^"]*"|-?[\d.]+|true|false|null)'
        $ins = {
            param([string]$obj, [string]$indent)
            $open = $obj.IndexOf('{')
            $empty = ($obj.Substring($open + 1).Trim() -eq '}')
            $line = "`n$indent`"$key`": $jsonValue" + $(if ($empty) { "`n" } else { ',' })
            return $obj.Insert($open + 1, $line)
        }
        if ($section) {
            $m = [regex]::Match($txt, '"' + [regex]::Escape($section) + '"\s*:\s*\{[^{}]*\}')
            if ($m.Success) {
                $block = $m.Value
                $nb = if ([regex]::IsMatch($block, $pat)) { [regex]::Replace($block, $pat, ('${1}' + $jsonValue)) } else { & $ins $block '    ' }
                $txt = $txt.Remove($m.Index, $m.Length).Insert($m.Index, $nb)
            } else {
                $key0 = $key; $val0 = $jsonValue
                $key = $section; $jsonValue = "{ `"$key0`": $val0 }"
                $txt = & $ins $txt '  '
            }
        } elseif ([regex]::IsMatch($txt, $pat)) {
            $txt = ([regex]$pat).Replace($txt, ('${1}' + $jsonValue), 1)
        } else {
            $txt = & $ins $txt '  '
        }
        [IO.File]::WriteAllText($cfgPath, $txt, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# ---------- Start with Windows (a shortcut in the Startup folder, like autostart-on.ps1) ----------
# Inside Clawd.exe the host sets CLAWD_EXE: the shortcut (and a restart) then launch the exe itself.
$script:hostExe = $env:CLAWD_EXE
$script:startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Clawd Pet.lnk'
function Test-Autostart { return (Test-Path $script:startupLnk) }
# "Start in stand-by": the Startup shortcut passes "standby" to start-clawd.vbs (or Clawd.exe) -> -Standby
$script:standbyOnStartup = [bool](Get-Cfg 'standbyOnStartup' $false)
function Set-Autostart([bool]$on) {
    try {
        if ($on) {
            $ws = New-Object -ComObject WScript.Shell
            $lnk = $ws.CreateShortcut($script:startupLnk)
            $lnk.TargetPath = if ($script:hostExe) { $script:hostExe } else { Join-Path $PSScriptRoot 'start-clawd.vbs' }
            $lnk.Arguments = if ($script:standbyOnStartup) { 'standby' } else { '' }
            $lnk.WorkingDirectory = if ($script:hostExe) { Split-Path $script:hostExe } else { $PSScriptRoot }
            $lnk.Description = 'Clawd Pet - desktop crab'
            $lnk.Save()
        } else {
            foreach ($name in @('Clawd Pet.lnk', 'start-clawd.vbs')) {
                $p = Join-Path ([Environment]::GetFolderPath('Startup')) $name
                if (Test-Path $p) { Remove-Item $p -Force }
            }
        }
    } catch { }
}

# ---------- Stand-by ----------
# In stand-by Clawd is fully asleep: no window, the frame clock is stopped (zero CPU), the Codex
# watcher process is stopped and his memory is handed back to Windows. Only the tray icon stays.
# Waking him up: he peeks out from a screen edge (Lurking) and steps out into the screen.
$script:petHidden = $false
$script:enterTarget = 0.0
function Set-PetHidden([bool]$hide) {
    if ($hide -eq $script:petHidden) { return }
    $script:petHidden = $hide
    if ($hide) {
        # Put him back in a plain standing layout first, whatever he was doing
        $script:dragging = $false
        if ($script:starActive) { Cancel-StarShow }
        if ($script:shMode -ne 'none') { Stop-Shadow }
        $script:balMode = 'none'; $script:balEscape = $false; $script:balForm.Hide()
        $script:climbPhase = 'none'; $script:pushPhase = 'none'
        $script:fx = 'none'; $script:fxTicks = 0
        $script:form.ClientSize = [System.Drawing.Size]::new($script:formW, $script:destH)
        $script:onPlat = $false
        $script:state = 'idle'
        $script:clock.Stop()
        $script:statusOv.Hide()
        $script:form.Hide()
        if ($script:codexWatcher -and -not $script:codexWatcher.HasExited) { $script:codexWatcher.Kill() }
        [System.GC]::Collect(); [ClawdWin]::TrimMemory()
    } else {
        Start-CodexWatcher
        Sync-Clock
        Start-Wake
        $script:form.Show()
        $script:form.TopMost = $true
        $script:clock.Start()
    }
    $script:miShowHide.Text = if ($hide) { 'Wake up Clawd' } else { 'Stand-by (hide Clawd)' }
    if ($hide) { $script:tray.ShowBalloonTip(3000, 'Clawd is in stand-by', 'Click the tray icon and choose "Wake up Clawd" to bring him back.', [System.Windows.Forms.ToolTipIcon]::Info) }
    $script:tray.Text = if ($hide) { 'Clawd (stand-by)' } else { 'Clawd' }
}

# Peek out from an edge of his monitor that has no other monitor beyond it (so he never shows
# up half on the neighbouring screen), hold there a moment, then step out ('enter').
function Start-Wake {
    $y = $script:bottomY + $script:destH / 2.0
    $leftFree  = ($null -eq (Get-NeighbourScreen -1 $y))
    $rightFree = ($null -eq (Get-NeighbourScreen 1 $y))
    $fromLeft = if ($leftFree -and -not $rightFree) { $true } elseif ($rightFree -and -not $leftFree) { $false } else { $script:rand.NextDouble() -lt 0.5 }
    $script:lurkDir = if ($fromLeft) { 1 } else { -1 }
    $script:posX = if ($fromLeft) { [double]$script:wa.Left } else { [double]($script:wa.Right - $script:formW) }
    $script:posY = [double]$script:bottomY
    $script:supportY = [double]$script:bottomY
    $script:form.ClientSize = [System.Drawing.Size]::new($script:formW, $script:destH)
    $script:form.Location = [System.Drawing.Point]::new([int]$script:posX, [int]$script:bottomY)
    Initialize-LurkAnim
    Set-State 'peek' ([int][Math]::Ceiling(($script:anims['lurk'].peakMs + 900) / $script:tickMs))
}

# Step out from behind the edge: start with only part of him on screen and walk in
function Start-Enter {
    $vis = 0.35 * $script:destW
    if ($script:lurkDir -gt 0) {
        $script:dir = 1
        $script:posX = $script:wa.Left - $script:margin - $script:destW + $vis
        $script:enterTarget = [double]($script:wa.Left + 24)
    } else {
        $script:dir = -1
        $script:posX = $script:wa.Right - $script:margin - $vis
        $script:enterTarget = [double]($script:wa.Right - $script:formW - 24)
    }
    $script:form.Location = [System.Drawing.Point]::new([int][Math]::Round($script:posX), [int]$script:supportY)
    Set-State 'enter' 9999
    Start-Pulse 0.05
}

# Quit cleanly whether or not the window is showing (a hidden form may not raise FormClosed)
function Exit-Clawd {
    $script:clock.Stop()
    $script:form.Close()
    [System.Windows.Forms.Application]::ExitThread()
}

# ---------- Tray icon (notification area, next to the clock) ----------
$script:trayHIcon = [IntPtr]::Zero
# Clawd's own sprite, in his current colour, as a 32x32 icon
function Update-TrayIcon {
    $s = $script:destW
    $tmp = New-Object System.Drawing.Bitmap($s, $script:destH, ([System.Drawing.Imaging.PixelFormat]::Format32bppPArgb))
    $tg = [System.Drawing.Graphics]::FromImage($tmp)
    $tg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $tg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $tg.DrawImage($script:sNoEyes, ([System.Drawing.Rectangle]::new(0, 0, $s, $script:destH)), $script:fullSrc, [System.Drawing.GraphicsUnit]::Pixel)
    $ox = $script:eyeOX; $oy = $script:eyeOY; $script:eyeOX = 0; $script:eyeOY = 0
    Draw-Eyes $tg 0 0 $false
    $script:eyeOX = $ox; $script:eyeOY = $oy
    $tg.Dispose()
    $top = $script:destH - $script:crabH   # crop away the empty space above his head
    $srcH = $script:destH - $top
    $ico = New-Object System.Drawing.Bitmap(32, 32, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb))
    $ig = [System.Drawing.Graphics]::FromImage($ico)
    $ig.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $ig.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $dh = [int][Math]::Round(32.0 * $srcH / $s)
    $ig.DrawImage($tmp, ([System.Drawing.Rectangle]::new(0, [int]((32 - $dh) / 2), 32, $dh)), ([System.Drawing.Rectangle]::new(0, $top, $s, $srcH)), [System.Drawing.GraphicsUnit]::Pixel)
    $ig.Dispose(); $tmp.Dispose()
    $h = $ico.GetHicon()
    $ico.Dispose()
    $old = $script:trayHIcon
    $script:tray.Icon = [System.Drawing.Icon]::FromHandle($h)
    $script:trayHIcon = $h
    [ClawdWin]::FreeIcon($old)
}

# A little colour chip for the Color menu (the coral body tone, recoloured)
function New-ColorSwatch([string]$name) {
    $b = New-Object System.Drawing.Bitmap(12, 12, ([System.Drawing.Imaging.PixelFormat]::Format32bppPArgb))
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.Clear([System.Drawing.Color]::FromArgb(217, 119, 87))
    $g.Dispose()
    $c = $script:colors[$name]
    if ($c[0] -lt 0) { return $b }
    $r = [ClawdFrames]::Recolor($b, $c[0], $c[1], $c[2])
    $b.Dispose()
    return $r
}

$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Text = 'Clawd'
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenu.ShowItemToolTips = $true
Set-MenuStyle $trayMenu
$trayMenu.ShowImageMargin = $false
$trayMenu.ShowCheckMargin = $true

$title = Add-MenuItem $trayMenu.Items 'Clawd' $null
$title.Enabled = $false
$title.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$null = Add-MenuItem $trayMenu.Items '-' $null
$script:miShowHide = Add-MenuItem $trayMenu.Items 'Stand-by (hide Clawd)' { Set-PetHidden (-not $script:petHidden) }

# Animations: the same list as the right-click menu
$miAnims = Add-MenuItem $trayMenu.Items 'Animations' $null
Set-MenuStyle $miAnims.DropDown
$miAnims.DropDown.ShowImageMargin = $false
Add-ActionItems $miAnims.DropDownItems

# Colour
$miColor = Add-MenuItem $trayMenu.Items 'Color' $null
Set-MenuStyle $miColor.DropDown
$miColor.DropDown.ShowCheckMargin = $true
$miColor.DropDown.ShowImageMargin = $true
$script:colorItems = @{}
foreach ($cn in $script:colors.Keys) {
    $it = Add-MenuItem $miColor.DropDownItems $cn {
        param($item)
        $name = [string]$item.Tag
        Set-ClawdColor $name
        foreach ($k2 in $script:colorItems.Keys) { $script:colorItems[$k2].Checked = ($k2 -eq $name) }
        Save-CfgValue 'color' "`"$name`""
        Update-TrayIcon
        Start-Pulse 0.08
        Update-PetVisual
    }
    $it.Tag = $cn
    $it.Image = New-ColorSwatch $cn
    $script:colorItems[$cn] = $it
}

# Size (applied by restarting Clawd - every sprite is pre-scaled to it)
$miSize = Add-MenuItem $trayMenu.Items 'Size' $null
Set-MenuStyle $miSize.DropDown
$miSize.DropDown.ShowCheckMargin = $true
$miSize.DropDown.ShowImageMargin = $false
foreach ($sz in @(@('Tiny', 44), @('Small', 56), @('Medium', 68), @('Large', 90))) {
    $it = Add-MenuItem $miSize.DropDownItems $sz[0] {
        param($item)
        $px = [int]$item.Tag
        if ($px -eq $script:destW) { return }
        Save-CfgValue 'size' "$px"
        $script:restart = $true
        Exit-Clawd
    }
    $it.Tag = $sz[1]
    $it.Checked = ($script:destW -eq $sz[1])
}
$null = Add-MenuItem $trayMenu.Items '-' $null

# Toggles
$script:miWatch = Add-MenuItem $trayMenu.Items 'Claude status bubble' {
    $on = -not $script:miWatch.Checked
    $script:miWatch.Checked = $on
    $script:featWatch = $on -and ($script:featClaudeWatch -or $script:featCodexWatch)
    if ($script:featWatch) { Start-CodexWatcher }
    elseif ($script:statusOv.Visible) { $script:statusOv.Hide(); $script:watchVis = 0 }
    Save-CfgValue 'agentWatch' $(if ($on) { 'true' } else { 'false' }) 'features'
}
$script:miWatch.Checked = $script:featWatch
$script:miWatch.Enabled = ($script:featClaudeWatch -or $script:featCodexWatch)
$script:miSound = Add-MenuItem $trayMenu.Items 'Sound when Claude finishes' {
    $script:featSound = -not $script:featSound
    $script:miSound.Checked = $script:featSound
    Save-CfgValue 'sound' $(if ($script:featSound) { 'true' } else { 'false' }) 'features'
}
$script:miSound.Checked = $script:featSound
$script:miAuto = Add-MenuItem $trayMenu.Items 'Start with Windows' {
    Set-Autostart (-not (Test-Autostart))
    $script:miAuto.Checked = (Test-Autostart)
    $script:miStandbyStart.Enabled = $script:miAuto.Checked
}
# ...and when Windows starts him, stay in stand-by (tray icon only) until woken up.
# Turning it on also puts him in stand-by right away (that is what people expect from it).
$script:miStandbyStart = Add-MenuItem $trayMenu.Items 'Start in stand-by' {
    $script:standbyOnStartup = -not $script:standbyOnStartup
    $script:miStandbyStart.Checked = $script:standbyOnStartup
    Save-CfgValue 'standbyOnStartup' $(if ($script:standbyOnStartup) { 'true' } else { 'false' })
    if (Test-Autostart) { Set-Autostart $true }   # rewrite the shortcut with / without "standby"
    if ($script:standbyOnStartup -and -not $script:petHidden) {
        Set-PetHidden $true
        $script:tray.ShowBalloonTip(4000, 'Clawd is in stand-by', 'He will also start in stand-by with Windows. Click the tray icon and choose "Wake up Clawd" to bring him back.', [System.Windows.Forms.ToolTipIcon]::Info)
    }
}
$script:miStandbyStart.ToolTipText = 'When Windows starts, Clawd starts hidden in the tray (stand-by) until you wake him up'
$script:miStandbyStart.Checked = $script:standbyOnStartup
$null = Add-MenuItem $trayMenu.Items '-' $null
$null = Add-MenuItem $trayMenu.Items 'Quit Clawd' { Exit-Clawd }
foreach ($it in $trayMenu.Items) { if ($it -is [System.Windows.Forms.ToolStripMenuItem]) { $it.ForeColor = $script:menuFore } }
# Re-read the live state each time it opens (the Startup shortcut can change outside Clawd)
$trayMenu.Add_Opening({
    $script:miAuto.Checked = (Test-Autostart)
    $script:miStandbyStart.Enabled = $script:miAuto.Checked
})
$script:tray.ContextMenuStrip = $trayMenu
# Left click opens the same menu (by default only a right click does)
$script:trayShowMenu = [System.Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'Instance,NonPublic')
$script:tray.Add_MouseUp({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $script:trayShowMenu) { [void]$script:trayShowMenu.Invoke($script:tray, $null) }
})

function Start-CodexWatcher {
    if (-not ($script:featWatch -and $script:featCodexWatch)) { return }
    if ($script:codexWatcher -and -not $script:codexWatcher.HasExited) { return }
    $watcherPath = Join-Path $PSScriptRoot 'tools\codex-watch.ps1'
    $script:codexWatcher = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$watcherPath`" -ParentId $PID -OutputPath `"$script:codexWatchFile`""
}

# Logic time restarts on the clock's frame grid, right before the clock does: the first frame of a
# pose begun now is then shown for its full length (not skipped by the time spent starting up)
function Sync-Clock {
    $script:nowMs = [Math]::Ceiling($script:clock.NowMs / $script:frameMs) * $script:frameMs
    $script:lastMs = $script:nowMs
}

# ---------- Start ----------
$script:selfHwnd = $script:form.Handle.ToInt64()
$script:supportY = [double]$script:bottomY
Set-ClawdColor $script:colorName
if ($script:colorItems.ContainsKey($script:colorName)) { $script:colorItems[$script:colorName].Checked = $true }
Update-TrayIcon
$script:tray.Visible = $true
# Release the one-off sprite-processing garbage back to the OS before we settle in
[System.GC]::Collect()
[ClawdWin]::TrimMemory()
if ($Standby) {
    # Started in stand-by (e.g. by Windows): asleep, tray icon only, until woken from the tray
    $script:petHidden = $true
    $script:miShowHide.Text = 'Wake up Clawd'
    $script:tray.Text = 'Clawd (stand-by)'
} else {
    Start-CodexWatcher
    Sync-Clock
    if (-not (Start-Extra 'stretch' 1)) { Set-State 'idle' 150 }
    $script:clock.Start()
    $script:form.Show()
}
$script:restart = $false
# The window is shown by hand (not by Application.Run) so stand-by can start without it
$script:form.Add_FormClosed({ [System.Windows.Forms.Application]::ExitThread() })
try { [System.Windows.Forms.Application]::Run() }
finally {
    $script:clock.Stop()
    $script:tray.Visible = $false
    $script:tray.Dispose()
    [ClawdWin]::FreeIcon($script:trayHIcon)
    if ($script:codexWatcher -and -not $script:codexWatcher.HasExited) { $script:codexWatcher.Kill() }
    if ([IO.File]::Exists($script:codexWatchFile)) { [IO.File]::Delete($script:codexWatchFile) }
}
$script:mutex.ReleaseMutex()
if ($script:restart) {
    if ($script:hostExe) { Start-Process $script:hostExe }
    else { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"" }
}
