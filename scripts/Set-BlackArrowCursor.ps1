#requires -Version 5.1

<#
.SYNOPSIS
    Makes only the normal-select (Arrow) mouse pointer black while keeping the
    exact Windows 11 Aero arrow shape. Every other pointer stays standard Aero.

.DESCRIPTION
    The built-in "Black" mouse pointer style in Settings swaps in a different
    (accessibility) arrow design. Windows ships no black Aero arrow, so this
    script generates one on the machine from the local
    %SystemRoot%\Cursors\aero_arrow.cur by inverting its colors (white fill
    becomes black, the dark outline becomes white, alpha is unchanged). No
    cursor artwork is bundled with this repo.

    The generated cursor is written to
    %LOCALAPPDATA%\CustomCursors\AeroBlack\aero_arrow.cur, registered as the
    "Aero (Black arrow)" scheme, and applied for the current user. No elevation
    is required.

    To undo: open main.cpl > Pointers, choose the "Windows Default" scheme, and
    click Apply.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$schemeName = 'Aero (Black arrow)'
$sourceArrow = Join-Path $env:SystemRoot 'Cursors\aero_arrow.cur'
$cursorDir = Join-Path $env:LOCALAPPDATA 'CustomCursors\AeroBlack'
$blackArrow = Join-Path $cursorDir 'aero_arrow.cur'
$windowsCursors = Join-Path $env:SystemRoot 'cursors'
$cursorsKey = 'HKCU:\Control Panel\Cursors'
$schemesKey = 'HKCU:\Control Panel\Cursors\Schemes'

# Order matches the comma-separated value format under
# HKCU\Control Panel\Cursors\Schemes. Everything except Arrow is the stock
# Windows Aero scheme (Crosshair and IBeam are empty = system default).
$roles = [ordered]@{
    Arrow       = $blackArrow
    Help        = Join-Path $windowsCursors 'aero_helpsel.cur'
    AppStarting = Join-Path $windowsCursors 'aero_working.ani'
    Wait        = Join-Path $windowsCursors 'aero_busy.ani'
    Crosshair   = ''
    IBeam       = ''
    NWPen       = Join-Path $windowsCursors 'aero_pen.cur'
    No          = Join-Path $windowsCursors 'aero_unavail.cur'
    SizeNS      = Join-Path $windowsCursors 'aero_ns.cur'
    SizeWE      = Join-Path $windowsCursors 'aero_ew.cur'
    SizeNWSE    = Join-Path $windowsCursors 'aero_nwse.cur'
    SizeNESW    = Join-Path $windowsCursors 'aero_nesw.cur'
    SizeAll     = Join-Path $windowsCursors 'aero_move.cur'
    UpArrow     = Join-Path $windowsCursors 'aero_up.cur'
    Hand        = Join-Path $windowsCursors 'aero_link.cur'
    Pin         = Join-Path $windowsCursors 'aero_pin.cur'
    Person      = Join-Path $windowsCursors 'aero_person.cur'
}

if (-not ('CrutkasSetup.CursorNative' -as [type])) {
    Add-Type -Namespace CrutkasSetup -Name CursorNative -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr LoadCursorFromFile(string lpFileName);

[DllImport("user32.dll", SetLastError = true)]
public static extern bool DestroyCursor(IntPtr hCursor);

[DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
'@
}

function Test-CursorLoads {
    param([Parameter(Mandatory)][string]$Path)

    $handle = [CrutkasSetup.CursorNative]::LoadCursorFromFile($Path)
    if ($handle -eq [IntPtr]::Zero) {
        return $false
    }
    [void][CrutkasSetup.CursorNative]::DestroyCursor($handle)
    return $true
}

function ConvertTo-InvertedCursor {
    # A .cur file is an ICONDIR (type 2) followed by image entries. Each Aero
    # entry is an uncompressed 32bpp BGRA DIB (40-byte BITMAPINFOHEADER,
    # doubled height, straight alpha) followed by a 1bpp AND mask. Inverting
    # RGB in place keeps size, layout, hotspots, and alpha unchanged.
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $data = [byte[]]$Bytes.Clone()

    if ($data.Length -lt 6 -or
        [BitConverter]::ToUInt16($data, 0) -ne 0 -or
        [BitConverter]::ToUInt16($data, 2) -ne 2) {
        throw 'Source is not a .cur file.'
    }

    $count = [BitConverter]::ToUInt16($data, 4)
    if ($count -eq 0 -or (6 + 16 * $count) -gt $data.Length) {
        throw 'Source .cur file has an invalid image directory.'
    }

    for ($k = 0; $k -lt $count; $k++) {
        $entry = 6 + 16 * $k
        $size = [BitConverter]::ToInt32($data, $entry + 8)
        $offset = [BitConverter]::ToInt32($data, $entry + 12)
        if ($offset -lt 0 -or $size -lt 40 -or ([int64]$offset + $size) -gt $data.Length) {
            throw "Cursor image $k is out of bounds."
        }

        $headerSize = [BitConverter]::ToInt32($data, $offset)
        $width = [BitConverter]::ToInt32($data, $offset + 4)
        $height = [Math]::Abs([BitConverter]::ToInt32($data, $offset + 8)) / 2
        $bitCount = [BitConverter]::ToUInt16($data, $offset + 14)
        $compression = [BitConverter]::ToInt32($data, $offset + 16)
        if ($headerSize -ne 40 -or $bitCount -ne 32 -or $compression -ne 0) {
            throw "Cursor image $k is not an uncompressed 32bpp bitmap; this Windows build uses a format the script does not handle."
        }

        $start = $offset + $headerSize
        $end = $start + $width * $height * 4
        if ($end -gt $offset + $size) {
            throw "Cursor image $k pixel data is truncated."
        }

        for ($i = $start; $i -lt $end; $i += 4) {
            $data[$i] = 255 - $data[$i]
            $data[$i + 1] = 255 - $data[$i + 1]
            $data[$i + 2] = 255 - $data[$i + 2]
        }
    }

    return , $data
}

if (-not (Test-Path -LiteralPath $sourceArrow)) {
    throw "Windows Aero arrow not found at $sourceArrow."
}

Write-Host "==> Generating black Aero arrow from $sourceArrow"
$newBytes = ConvertTo-InvertedCursor -Bytes ([IO.File]::ReadAllBytes($sourceArrow))

New-Item -Path $cursorDir -ItemType Directory -Force | Out-Null

$upToDate = $false
if (Test-Path -LiteralPath $blackArrow) {
    $existing = [IO.File]::ReadAllBytes($blackArrow)
    $upToDate = ($existing.Length -eq $newBytes.Length) -and
        ([Convert]::ToBase64String($existing) -eq [Convert]::ToBase64String($newBytes))
}

if ($upToDate) {
    Write-Host "[OK] $blackArrow is already up to date."
}
else {
    $tempPath = Join-Path $cursorDir "aero_arrow.$([guid]::NewGuid().ToString('N')).cur"
    try {
        [IO.File]::WriteAllBytes($tempPath, $newBytes)
        if (-not (Test-CursorLoads -Path $tempPath)) {
            throw 'Windows could not load the generated cursor.'
        }
        Move-Item -LiteralPath $tempPath -Destination $blackArrow -Force
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
    Write-Host "[OK] Wrote $blackArrow"
}

if (-not (Test-CursorLoads -Path $blackArrow)) {
    throw "Windows could not load $blackArrow."
}

Write-Host "==> Registering and applying the '$schemeName' pointer scheme"
if (-not (Test-Path -LiteralPath $schemesKey)) {
    New-Item -Path $schemesKey -Force | Out-Null
}
Set-ItemProperty -LiteralPath $schemesKey -Name $schemeName -Value (@($roles.Values) -join ',')

foreach ($role in $roles.Keys) {
    Set-ItemProperty -LiteralPath $cursorsKey -Name $role -Value $roles[$role]
}
Set-ItemProperty -LiteralPath $cursorsKey -Name '(default)' -Value $schemeName
Set-ItemProperty -LiteralPath $cursorsKey -Name 'Scheme Source' -Value 1 -Type DWord

# SPI_SETCURSORS (0x57) reloads the cursors from the registry values written
# above; SPIF_SENDCHANGE (2) broadcasts the change. SPIF_UPDATEINIFILE is not
# used because it makes SPI_SETCURSORS report failure even when it succeeds.
if (-not [CrutkasSetup.CursorNative]::SystemParametersInfo(0x57, 0, [IntPtr]::Zero, 2)) {
    throw "SystemParametersInfo(SPI_SETCURSORS) failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
}

Write-Host "[SUCCESS] Black Aero arrow applied. Undo: main.cpl > Pointers > Scheme 'Windows Default' > Apply."
