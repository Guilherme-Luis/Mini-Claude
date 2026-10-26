# Builds dist\Clawd.exe: one file with the script, tools and assets embedded and the native helpers
# compiled in (see src\ClawdHost.cs). Uses the C# compiler that ships with Windows (.NET Framework 4),
# so nothing needs installing. Re-run after changing anything; then just run dist\Clawd.exe.
#   powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
param([string]$Out = (Join-Path $PSScriptRoot 'dist\Clawd.exe'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = $PSScriptRoot
$obj  = Join-Path $root 'build'   # intermediate files
[void][IO.Directory]::CreateDirectory($obj)
[void][IO.Directory]::CreateDirectory((Split-Path $Out))
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path $csc)) { throw "C# compiler not found: $csc" }

# ---- Icon: Clawd's own sprite (head and legs, eyes included), crisp at every size ----
$ico = Join-Path $obj 'clawd.ico'
$still = New-Object Drawing.Bitmap (Join-Path $root 'assets\Clawd-Still.png')
$entries = foreach ($s in 16, 24, 32, 48, 64, 128, 256) {
    $bmp = New-Object Drawing.Bitmap $s, $s, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = if ($s -ge 64) { 'NearestNeighbor' } else { 'HighQualityBicubic' }
    $g.PixelOffsetMode = 'Half'
    $h = [int][Math]::Round($s * 800 / 1200.0)   # the crab is 1200 x 800 source px (x 736.., y 1050..)
    $g.DrawImage($still, ([Drawing.Rectangle]::new(0, [int](($s - $h) / 2), $s, $h)), ([Drawing.Rectangle]::new(736, 1050, 1200, 800)), [Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)   # PNG-compressed icon images (Windows Vista+)
    $bmp.Dispose()
    , @($s, $ms.ToArray())
}
$still.Dispose()
$fs = [IO.File]::Create($ico); $bw = New-Object IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$entries.Count)
$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
    $bw.Write([byte]($e[0] % 256)); $bw.Write([byte]($e[0] % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$e[1].Length); $bw.Write([uint32]$offset)
    $offset += $e[1].Length
}
foreach ($e in $entries) { $bw.Write($e[1]) }
$bw.Close()

# ---- Manifest: the same as powershell.exe's (not DPI-aware, so sizes and positions are unchanged) ----
$manifest = Join-Path $obj 'Clawd.manifest'
@'
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <description>Clawd Pet</description>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security><requestedPrivileges><requestedExecutionLevel level="asInvoker" uiAccess="false"/></requestedPrivileges></security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{e2011457-1546-43c5-a5fe-008deee3d3f0}"/>
      <supportedOS Id="{35138b9a-5d96-4fbd-8e2d-a2440225f93a}"/>
      <supportedOS Id="{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}"/>
      <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}"/>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings><longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware></windowsSettings>
  </application>
</assembly>
'@ | Set-Content $manifest -Encoding UTF8

# ---- Payload: everything clawd-pet.ps1 reads from its own folder ----
$files = @('clawd-pet.ps1', 'download-assets.ps1', 'clawd.json', 'src\ClawdNative.cs') +
         @(Get-ChildItem (Join-Path $root 'tools') -File | Where-Object { $_.Extension -in '.ps1', '.cmd' } | ForEach-Object { "tools\$($_.Name)" }) +
         @(Get-ChildItem (Join-Path $root 'assets') -File | Where-Object { $_.Extension -in '.gif', '.png' } | ForEach-Object { "assets\$($_.Name)" })
$md5 = [Security.Cryptography.MD5]::Create()
$all = New-Object IO.MemoryStream
foreach ($f in $files + @('src\ClawdHost.cs')) { $b = [IO.File]::ReadAllBytes((Join-Path $root $f)); $all.Write($b, 0, $b.Length) }
$version = [BitConverter]::ToString($md5.ComputeHash($all.ToArray())).Replace('-', '')
$verFile = Join-Path $obj 'payload.version'
[IO.File]::WriteAllText($verFile, $version)

# ---- Compile (a response file keeps the long resource list off the command line) ----
$sma = [PSObject].Assembly.Location
$rsp = @('/nologo', '/target:winexe', '/optimize+', '/platform:anycpu', "/out:`"$Out`"", "/win32icon:`"$ico`"", "/win32manifest:`"$manifest`"",
         '/r:System.dll', '/r:System.Drawing.dll', '/r:System.Windows.Forms.dll', "/r:`"$sma`"",
         "/resource:`"$verFile`",payload.version")
foreach ($f in $files) { $rsp += "/resource:`"$(Join-Path $root $f)`",payload/$($f.Replace('\', '/'))" }
$rsp += "`"$(Join-Path $root 'src\ClawdHost.cs')`"", "`"$(Join-Path $root 'src\ClawdNative.cs')`""
$rspFile = Join-Path $obj 'csc.rsp'
$rsp | Set-Content $rspFile -Encoding UTF8
& $csc "@$rspFile"
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
'{0}  {1:0.0} MB  ({2} files embedded, payload {3})' -f $Out, ((Get-Item $Out).Length / 1MB), $files.Count, $version.Substring(0, 8)
