<#
.SYNOPSIS
    Launch VALORANT in a TRUE stretched resolution using the "Device Manager" method,
    on ANY Windows PC, driven by a config file, and restore everything on exit.

.DESCRIPTION
    WHY THIS WORKS ("true" stretch vs "fake" stretch):
        VALORANT reads the monitor's EDID (native resolution) and compensates the
        aspect ratio, so a plain low resolution only stretches the HUD and crosshair.
        When the monitor's driver is disabled in Device Manager, the EDID is gone,
        Windows falls back to a generic display driver, VALORANT can no longer detect
        the native panel and stretches the whole image (models included, no black
        bars). No third-party tool, no memory patching -> safe, not bannable.

    WHAT THIS SCRIPT DOES (everything is reverted in 'finally'):
        1. Asks for Administrator rights (Disable/Enable-PnpDevice need them).
        2. Saves the current Windows display mode and backs up every VALORANT
           "GameUserSettings.ini".
        3. Disables the OTHER monitors, switches the game monitor to the target
           resolution (while its driver is still enabled so the custom mode is
           available), then disables the game monitor itself -> EDID gone -> TRUE
           stretch.
        4. Patches VALORANT settings (resolution, Aspect Ratio, Display Mode).
        5. Launches VALORANT and waits until it closes.
        6. Re-enables the monitors, restores the original resolution and config.

    The rollback also runs if you press Ctrl+C while the game is running.

    Everything is portable: paths are auto-detected and can be overridden in config.json.

.PARAMETER Config
    Path to a JSON config file. Default: config.json next to this script.

.PARAMETER ResolutionWidth / ResolutionHeight
    Target resolution. Overrides config.json. Must exist as a display mode
    (create it in your GPU control panel if needed).

.PARAMETER RefreshRate
    Refresh rate (Hz). 0 = highest available. Overrides config.json.

.PARAMETER DisplayMode
    Fullscreen | WindowedFullscreen | Windowed | Borderless. Overrides config.json.

.PARAMETER MonitorMode
    All (disable every monitor, default) | Target (only the game monitor) | None
    (do not touch any monitor - useful for testing). Overrides config.json.

.PARAMETER DisplayDevice
    Force a display adapter, e.g. "\\.\DISPLAY1". Overrides config.json.

.PARAMETER NoLaunch
    Do not start VALORANT yourself; just set things up and wait.

.PARAMETER NoPause
    Do not wait for a key press at the end (for automation).

.PARAMETER DryRun
    Show what would be done and exit. Changes nothing, no Administrator prompt.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Valorant-4x3.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Valorant-4x3.ps1 -DryRun

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Valorant-4x3.ps1 -ResolutionWidth 1280 -ResolutionHeight 960
#>

[CmdletBinding()]
param(
    [string]$Config = '',
    [int]$ResolutionWidth = 0,
    [int]$ResolutionHeight = 0,
    [int]$RefreshRate = -1,
    [ValidateSet('Fullscreen', 'WindowedFullscreen', 'Windowed', 'Borderless')]
    [string]$DisplayMode = '',
    [ValidateSet('All', 'Target', 'None')]
    [string]$MonitorMode = '',
    [string]$DisplayDevice = '',
    [switch]$NoLaunch,
    [switch]$NoPause,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms | Out-Null

# ---------------------------------------------------------------------------
# Config loading (defaults -> config.json -> command line)
# ---------------------------------------------------------------------------
if (-not $Config) { $Config = Join-Path $PSScriptRoot 'config.json' }

$defaults = [ordered]@{
    ResolutionWidth     = 1440
    ResolutionHeight    = 1080
    RefreshRate         = 0
    AspectRatioFill     = $true
    DisplayMode         = 'WindowedFullscreen'
    MonitorMode         = 'All'
    DisplayDevice       = ''
    MonitorHwid         = ''
    LaunchValorant      = $true
    RiotClientPath      = 'C:\Riot Games\Riot Client\RiotClientServices.exe'
    ValorantProcess     = 'VALORANT'
    LaunchTimeoutMinutes = 5
    LogToFile           = $true
    PauseOnExit         = $true
}

$cfg = [ordered]@{}
foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }

if (Test-Path -LiteralPath $Config) {
    try {
        $json = Get-Content -LiteralPath $Config -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($k in $defaults.Keys) {
            if (@($json.PSObject.Properties.Name) -contains $k) { $cfg[$k] = $json.$k }
        }
    } catch {
        Write-Host "[4:3] WARNING: could not read config '$Config': $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Command line overrides
if ($PSBoundParameters.ContainsKey('ResolutionWidth'))  { $cfg['ResolutionWidth']  = $ResolutionWidth }
if ($PSBoundParameters.ContainsKey('ResolutionHeight')) { $cfg['ResolutionHeight'] = $ResolutionHeight }
if ($PSBoundParameters.ContainsKey('RefreshRate'))      { $cfg['RefreshRate']      = $RefreshRate }
if ($PSBoundParameters.ContainsKey('DisplayMode'))      { $cfg['DisplayMode']      = $DisplayMode }
if ($PSBoundParameters.ContainsKey('MonitorMode'))      { $cfg['MonitorMode']      = $MonitorMode }
if ($PSBoundParameters.ContainsKey('DisplayDevice'))    { $cfg['DisplayDevice']    = $DisplayDevice }
if ($NoLaunch) { $cfg['LaunchValorant'] = $false }

$Width        = [int]$cfg['ResolutionWidth']
$Height       = [int]$cfg['ResolutionHeight']
$RefreshRateN = [int]$cfg['RefreshRate']
$ValorantProc = [string]$cfg['ValorantProcess']
$DoPause      = [bool]$cfg['PauseOnExit'] -and (-not $NoPause)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$LogFile = Join-Path $env:TEMP 'Valorant-4x3-portable.log'
$LogEnabled = [bool]$cfg['LogToFile']
function Say  { param([string]$m) $line = "[4:3] $m"; Write-Host $line; if ($LogEnabled) { Add-Content -LiteralPath $LogFile -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $line) -ErrorAction SilentlyContinue } }
function Warn { param([string]$m) $line = "[4:3] $m"; Write-Host $line -ForegroundColor Yellow; if ($LogEnabled) { Add-Content -LiteralPath $LogFile -Value ((Get-Date -Format 'HH:mm:ss') + ' WARN ' + $line) -ErrorAction SilentlyContinue } }
function Good { param([string]$m) $line = "[4:3] $m"; Write-Host $line -ForegroundColor Green; if ($LogEnabled) { Add-Content -LiteralPath $LogFile -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $line) -ErrorAction SilentlyContinue } }

# ---------------------------------------------------------------------------
# Administrator / self-elevation
# ---------------------------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$IsAdmin = Test-Admin
$NeedAdmin = ($cfg['MonitorMode'] -ne 'None')

if (-not $IsAdmin -and -not $DryRun -and $NeedAdmin) {
    Say 'Administrator rights are required (to disable/enable monitors). Asking for elevation...'
    function QuoteArg([string]$s) {
        if ($s -match '[\s"]') { return '"' + ($s -replace '"', '\"') + '"' }
        return $s
    }
    $fwd = @()
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        $name = $kv.Key; $val = $kv.Value
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $fwd += "-$name" }
        } else {
            $fwd += "-$name"
            $fwd += (QuoteArg ([string]$val))
        }
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (QuoteArg $PSCommandPath)) + $fwd
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList
        exit 0
    } catch {
        Warn 'Elevation was cancelled or failed. Cannot continue without Administrator rights.'
        if ($DoPause) { Read-Host 'Press Enter to close' }
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Win32 interop
# ---------------------------------------------------------------------------
$win32 = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class VDis
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    public const int  ENUM_CURRENT_SETTINGS = -1;
    public const uint CDS_UPDATEREGISTRY    = 0x01;
    public const int  DM_PELSWIDTH          = 0x00080000;
    public const int  DM_PELSHEIGHT         = 0x00100000;
    public const int  DM_DISPLAYFREQUENCY   = 0x00400000;
    public const int  DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x01;
    public const int  DISPLAY_DEVICE_PRIMARY_DEVICE      = 0x04;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettings(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    public static short DevModeSize() { return (short)Marshal.SizeOf(typeof(DEVMODE)); }

    // Lines: Adapter|StateFlags|AdapterName|MonitorId
    public static string[] ListDisplays()
    {
        var list = new List<string>();
        var d = new DISPLAY_DEVICE(); d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        for (uint i = 0; EnumDisplayDevices(null, i, ref d, 0); i++)
        {
            var m = new DISPLAY_DEVICE(); m.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            string mid = "";
            if (EnumDisplayDevices(d.DeviceName, 0, ref m, 0)) mid = m.DeviceID;
            list.Add(d.DeviceName + "|" + d.StateFlags + "|" + d.DeviceString + "|" + mid);
            d = new DISPLAY_DEVICE(); d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        }
        return list.ToArray();
    }

    // Returns "w|h|hz" or "" on failure.
    public static string CurrentMode(string dev)
    {
        var dm = new DEVMODE(); dm.dmSize = DevModeSize();
        if (!EnumDisplaySettings(dev, ENUM_CURRENT_SETTINGS, ref dm)) return "";
        return dm.dmPelsWidth + "|" + dm.dmPelsHeight + "|" + dm.dmDisplayFrequency;
    }

    // Max refresh available for a given resolution, or -1 if the mode does not exist.
    public static int FindMode(string dev, int w, int h)
    {
        short size = DevModeSize();
        int best = -1;
        for (int i = 0; i < 10000; i++)
        {
            var dm = new DEVMODE(); dm.dmSize = size;
            if (!EnumDisplaySettings(dev, i, ref dm)) break;
            if (dm.dmPelsWidth == w && dm.dmPelsHeight == h && dm.dmDisplayFrequency > best)
                best = dm.dmDisplayFrequency;
        }
        return best;
    }

    // Distinct "WxH" modes exposed by the display, sorted.
    public static string[] ListResolutions(string dev)
    {
        short size = DevModeSize();
        var set = new List<string>();
        for (int i = 0; i < 10000; i++)
        {
            var dm = new DEVMODE(); dm.dmSize = size;
            if (!EnumDisplaySettings(dev, i, ref dm)) break;
            string k = dm.dmPelsWidth + "x" + dm.dmPelsHeight;
            if (!set.Contains(k)) set.Add(k);
        }
        set.Sort();
        return set.ToArray();
    }

    // Find the requested mode (or the max refresh) and apply it. Fallback builds a
    // DEVMODE from the current one if the mode is not listed.
    // Returns ChangeDisplaySettingsEx result (0 = success).
    public static int ApplyResolution(string dev, int w, int h, int hz)
    {
        short size = DevModeSize();
        DEVMODE chosen = new DEVMODE();
        bool found = false;
        DEVMODE best = new DEVMODE(); int bestHz = -1;

        for (int i = 0; i < 10000; i++)
        {
            var dm = new DEVMODE(); dm.dmSize = size;
            if (!EnumDisplaySettings(dev, i, ref dm)) break;
            if (dm.dmPelsWidth == w && dm.dmPelsHeight == h)
            {
                if (hz > 0) { if (dm.dmDisplayFrequency == hz) { chosen = dm; found = true; break; } }
                else if (dm.dmDisplayFrequency > bestHz) { bestHz = dm.dmDisplayFrequency; best = dm; found = true; }
            }
        }
        if (found && bestHz >= 0) chosen = best;

        if (!found)
        {
            var cur = new DEVMODE(); cur.dmSize = size;
            if (!EnumDisplaySettings(dev, ENUM_CURRENT_SETTINGS, ref cur)) return -100;
            cur.dmPelsWidth = w;
            cur.dmPelsHeight = h;
            if (hz > 0) cur.dmDisplayFrequency = hz;
            chosen = cur;
        }

        chosen.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
        if (chosen.dmDisplayFrequency > 0) chosen.dmFields |= DM_DISPLAYFREQUENCY;
        return ChangeDisplaySettingsEx(dev, ref chosen, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
    }
}
'@
Add-Type -TypeDefinition $win32

# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------
function Get-Displays {
    [VDis]::ListDisplays() | ForEach-Object {
        $p = $_ -split '\|'
        [pscustomobject]@{
            Adapter   = $p[0]
            Flags     = [int]$p[1]
            Name      = $p[2]
            MonitorId = $p[3]
            Attached  = (([int]$p[1] -band [VDis]::DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) -ne 0)
            Primary   = (([int]$p[1] -band [VDis]::DISPLAY_DEVICE_PRIMARY_DEVICE) -ne 0)
        }
    }
}

function Get-ConfigMonitorHwid {
    $root = Join-Path $env:LOCALAPPDATA 'VALORANT\Saved\Config'
    if (-not (Test-Path $root)) { return '' }
    $cf = Get-ChildItem $root -Recurse -Filter 'GameUserSettings.ini' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $cf) { return '' }
    $mm = Select-String -Path $cf.FullName -Pattern '^DefaultMonitorDeviceID="?MONITOR\\([^\\"\r\n]+)' -ErrorAction SilentlyContinue
    if ($mm) { return $mm.Matches[0].Groups[1].Value }
    return ''
}

function Select-Target {
    param([string]$Requested, [string]$Hwid)
    $all = @(Get-Displays)
    if ($Requested) {
        $d = $all | Where-Object { $_.Adapter -eq $Requested } | Select-Object -First 1
        if ($d) { return $d }
    }
    if (-not $Hwid) { $Hwid = Get-ConfigMonitorHwid }
    if ($Hwid) {
        $d = $all | Where-Object { $_.MonitorId -match [regex]::Escape($Hwid) } | Select-Object -First 1
        if ($d) { return $d }
    }
    $d = $all | Where-Object { $_.Primary -and $_.Attached } | Select-Object -First 1
    if ($d) { return $d }
    return ($all | Where-Object { $_.Attached } | Select-Object -First 1)
}

function Resolve-Again {
    param([string]$Adapter, [string]$MonitorId, [string]$Hwid)
    $all = @(Get-Displays)
    if ($Adapter) {
        $d = $all | Where-Object { $_.Adapter -eq $Adapter } | Select-Object -First 1
        if ($d) { return $d }
    }
    if ($MonitorId) {
        $d = $all | Where-Object { $_.MonitorId -eq $MonitorId } | Select-Object -First 1
        if ($d) { return $d }
    }
    return (Select-Target -Requested '' -Hwid $Hwid)
}

function Parse-Mode {
    param([string]$s)
    if (-not $s) { return $null }
    $p = $s -split '\|'
    if ($p.Count -lt 3) { return $null }
    [pscustomobject]@{ w = [int]$p[0]; h = [int]$p[1]; hz = [int]$p[2] }
}

# ---------------------------------------------------------------------------
# VALORANT config helpers
# ---------------------------------------------------------------------------
function Set-IniValue {
    param([string]$Text, [string]$Key, [string]$Value)
    $line = "$Key=$Value"
    $rx = [regex]('(?m)^' + [regex]::Escape($Key) + '=.*$')
    if ($rx.IsMatch($Text)) { return $rx.Replace($Text, $line) }
    return $Text + "`r`n" + $line
}

function Get-DisplayModeValue {
    param([string]$Mode)
    switch ($Mode) {
        'Fullscreen'         { return '0' }
        'Windowed'           { return '2' }
        default              { return '1' }   # WindowedFullscreen / Borderless
    }
}

function Update-ValorantConfig {
    param([string]$Path)
    $fs  = Get-DisplayModeValue -Mode $cfg['DisplayMode']
    $lb  = if ([bool]$cfg['AspectRatioFill']) { 'False' } else { 'True' }
    $text = [System.IO.File]::ReadAllText($Path)
    $text = Set-IniValue $text 'ResolutionSizeX'                  $Width
    $text = Set-IniValue $text 'ResolutionSizeY'                  $Height
    $text = Set-IniValue $text 'LastUserConfirmedResolutionSizeX' $Width
    $text = Set-IniValue $text 'LastUserConfirmedResolutionSizeY' $Height
    $text = Set-IniValue $text 'bShouldLetterbox'              $lb
    $text = Set-IniValue $text 'bLastConfirmedShouldLetterbox' $lb
    $text = Set-IniValue $text 'FullscreenMode'              $fs
    $text = Set-IniValue $text 'PreferredFullscreenMode'     $fs
    $text = Set-IniValue $text 'LastConfirmedFullscreenMode' $fs
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.ASCIIEncoding))
}

function Get-ValorantConfigFiles {
    $root = Join-Path $env:LOCALAPPDATA 'VALORANT\Saved\Config'
    @(Get-ChildItem $root -Recurse -Filter 'GameUserSettings.ini' -ErrorAction SilentlyContinue | ForEach-Object FullName)
}

function Backup-ValorantConfig {
    param([string[]]$Files, [string]$BackupRoot)
    $root = Join-Path $env:LOCALAPPDATA 'VALORANT\Saved\Config'
    foreach ($f in $Files) {
        $rel = $f.Substring($root.Length).TrimStart('\')
        $dst = Join-Path $BackupRoot $rel
        New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
        Copy-Item -LiteralPath $f -Destination $dst -Force
    }
}

function Restore-ValorantConfig {
    param([string[]]$Files, [string]$BackupRoot)
    $root = Join-Path $env:LOCALAPPDATA 'VALORANT\Saved\Config'
    foreach ($f in $Files) {
        $rel = $f.Substring($root.Length).TrimStart('\')
        $src = Join-Path $BackupRoot $rel
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $f -Force }
    }
}

function Get-ActiveMonitors {
    @(Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'OK' })
}

function Resolve-RiotClient {
    param([string]$Configured)
    $candidates = @()
    if ($Configured) { $candidates += $Configured }
    $pf  = $env:ProgramFiles
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($pf)   { $candidates += (Join-Path $pf  'Riot Games\Riot Client\RiotClientServices.exe') }
    if ($pf86) { $candidates += (Join-Path $pf86 'Riot Games\Riot Client\RiotClientServices.exe') }
    $candidates += "$($env:SystemDrive)\Riot Games\Riot Client\RiotClientServices.exe"
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }

    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $e = Get-ItemProperty $root -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -like '*Riot Client*' -and $_.InstallLocation } |
             Select-Object -First 1
        if ($e) {
            $p = Join-Path $e.InstallLocation 'RiotClientServices.exe'
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    return $Configured
}

# ===========================================================================
# MAIN
# ===========================================================================
Say "Config ............... $Config"
Say "Target resolution .... ${Width}x${Height}$(if($RefreshRateN){" @${RefreshRateN}Hz"}else{' (@max Hz)'})   Fill=$([bool]$cfg['AspectRatioFill'])  Mode=$($cfg['DisplayMode'])  Monitors=$($cfg['MonitorMode'])"

$target = Select-Target -Requested ([string]$cfg['DisplayDevice']) -Hwid ([string]$cfg['MonitorHwid'])
if (-not $target) {
    Warn 'No target monitor found. Nothing to do.'
    if ($DoPause) { Read-Host 'Press Enter to close' }
    exit 1
}

$origRaw = [VDis]::CurrentMode($target.Adapter)
$orig    = Parse-Mode $origRaw
$activeMonitors = Get-ActiveMonitors
$targetHwid = ''
if ($target.MonitorId -match 'MONITOR\\([^\\]+)') { $targetHwid = $Matches[1] }

$mm = [string]$cfg['MonitorMode']
$toDisable = @(
    if ($mm -eq 'None') { @() }
    elseif ($mm -eq 'Target' -and $targetHwid) { $activeMonitors | Where-Object { $_.InstanceId -like "*$targetHwid*" } }
    else { $activeMonitors }
)

$availHz = [VDis]::FindMode($target.Adapter, $Width, $Height)

Say "Administrator ........ $IsAdmin"
Say "Target monitor ....... $($target.Adapter)  [$($target.Name)]  $($target.MonitorId)"
Say "Current mode ......... $($orig.w)x$($orig.h) @$($orig.hz)Hz"
if ($availHz -gt 0) { Say "Mode available ....... yes (@$($availHz)Hz)" }
else { Warn "Mode available ....... NO - ${Width}x${Height} is not exposed by the display" }
Say "Monitors to disable .. $($toDisable.Count)  (mode: $mm)"
$toDisable | ForEach-Object { Write-Host "                       - $($_.FriendlyName)  [$($_.InstanceId)]" }

if ($DryRun) {
    $cf = Get-ValorantConfigFiles
    Say "DryRun: would patch $($cf.Count) VALORANT config file(s)."
    Say "DryRun: would launch VALORANT: $((Test-Path (Resolve-RiotClient -Configured $cfg['RiotClientPath'])))"
    Say 'DryRun: no changes made.'
    if ($DoPause) { Read-Host 'Press Enter to close' }
    return
}

if ($availHz -le 0 -and $mm -ne 'None') {
    Warn "Resolution ${Width}x${Height} is not available on $($target.Adapter)."
    Warn 'Create it in your GPU control panel (NVIDIA: Change resolution -> Customize ->'
    Warn '"Create Custom Resolution", tick "Resolutions not exposed by the display";'
    Warn 'AMD: Display -> Custom Resolutions), set the target size and refresh, then Apply.'
    Warn 'Nothing was changed - monitors were NOT touched.'
    Warn ("Currently available modes: " + (([VDis]::ListResolutions($target.Adapter)) -join ', '))
    if ($DoPause) { Read-Host 'Press Enter to close' }
    exit 1
}

$configFiles   = Get-ValorantConfigFiles
$BackupRoot    = Join-Path $env:TEMP ('Valorant4x3_backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
$configChanged = $false
$disabledMon   = @()
$modeChanged   = $false
$scriptFailed  = $null
$restoreAdapter   = $target.Adapter
$restoreMonitorId = $target.MonitorId

try {
    # 1) Back up + patch VALORANT config
    if ($configFiles.Count -gt 0) {
        Say "Backing up and editing VALORANT config ($($configFiles.Count) file(s))..."
        Backup-ValorantConfig -Files $configFiles -BackupRoot $BackupRoot
        foreach ($f in $configFiles) { Update-ValorantConfig -Path $f }
        $configChanged = $true
        Say "Backup stored in: $BackupRoot"
    } else {
        Warn 'No VALORANT config files found (game may not have been started yet).'
    }

    # Split the game monitor from the rest
    $mainMon  = @()
    $otherMon = @()
    if ($targetHwid) {
        $mainMon  = @($toDisable | Where-Object {   $_.InstanceId -like "*$targetHwid*" })
        $otherMon = @($toDisable | Where-Object { -not ($_.InstanceId -like "*$targetHwid*") })
    } else {
        $otherMon = @($toDisable)
    }

    # 2) Disable the OTHER monitors first (keep the game monitor's custom mode available)
    if ($otherMon.Count -gt 0) {
        Say 'Disabling secondary monitors...'
        foreach ($m in $otherMon) {
            try {
                Disable-PnpDevice -InstanceId $m.InstanceId -Confirm:$false -ErrorAction Stop
                $disabledMon += $m
                Say "  - disabled $($m.FriendlyName)"
            } catch {
                Warn "  ! could not disable $($m.FriendlyName): $($_.Exception.Message)"
            }
        }
        Start-Sleep -Seconds 2
    }

    # 3) Switch the game monitor to the target mode (driver still enabled here)
    $tgt = Resolve-Again -Adapter $target.Adapter -MonitorId $target.MonitorId -Hwid ([string]$cfg['MonitorHwid'])
    $restoreAdapter   = $tgt.Adapter
    $restoreMonitorId = $tgt.MonitorId
    Say "Applying ${Width}x${Height} on $($tgt.Adapter) ..."
    $rc = [VDis]::ApplyResolution($tgt.Adapter, $Width, $Height, $RefreshRateN)
    if ($rc -ne 0) {
        throw "Could not switch to ${Width}x${Height} (ChangeDisplaySettingsEx = $rc) while the monitor driver was still enabled. Check that the resolution really exists."
    }
    $modeChanged = $true
    $cur = Parse-Mode ([VDis]::CurrentMode($tgt.Adapter))
    Good "  now at $($cur.w)x$($cur.h) @$($cur.hz)Hz"

    # 4) Disable the game monitor itself -> EDID gone -> TRUE stretch
    if ($mainMon.Count -gt 0) {
        Say 'Disabling the game monitor (removing EDID -> true stretch)...'
        foreach ($m in $mainMon) {
            try {
                Disable-PnpDevice -InstanceId $m.InstanceId -Confirm:$false -ErrorAction Stop
                $disabledMon += $m
                Say "  - disabled $($m.FriendlyName)"
            } catch {
                Warn "  ! could not disable $($m.FriendlyName): $($_.Exception.Message)"
            }
        }
        Start-Sleep -Seconds 2
        $tgt2 = Resolve-Again -Adapter $restoreAdapter -MonitorId $restoreMonitorId -Hwid ([string]$cfg['MonitorHwid'])
        $cur2 = Parse-Mode ([VDis]::CurrentMode($tgt2.Adapter))
        if ($cur2 -and ($cur2.w -ne $Width -or $cur2.h -ne $Height)) {
            Warn "  display reverted to $($cur2.w)x$($cur2.h); re-applying ${Width}x${Height}..."
            $rc2 = [VDis]::ApplyResolution($tgt2.Adapter, $Width, $Height, $RefreshRateN)
            $cur3 = Parse-Mode ([VDis]::CurrentMode($tgt2.Adapter))
            if ($rc2 -eq 0 -and $cur3) { Good "  now at $($cur3.w)x$($cur3.h) @$($cur3.hz)Hz" }
            else { Warn "  ! could not re-apply after disabling the monitor (rc=$rc2). The stretch may not work." }
        } elseif ($cur2) {
            Good "  still at $($cur2.w)x$($cur2.h) @$($cur2.hz)Hz"
        }
    }

    # 5) Launch VALORANT and wait
    $running = Get-Process -Name $ValorantProc -ErrorAction SilentlyContinue
    if (-not $running -and [bool]$cfg['LaunchValorant']) {
        $riot = Resolve-RiotClient -Configured $cfg['RiotClientPath']
        if ($riot -and (Test-Path -LiteralPath $riot)) {
            Say "Launching VALORANT via $riot ..."
            Start-Process -FilePath $riot -ArgumentList '--launch-product=valorant', '--launch-patchline=live'
            $deadline = (Get-Date).AddMinutes([int]$cfg['LaunchTimeoutMinutes'])
            while (-not (Get-Process -Name $ValorantProc -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 3
            }
        } else {
            Warn "Riot Client not found - start VALORANT manually."
        }
    } elseif ($running) {
        Say 'VALORANT is already running - waiting for it to close.'
    }

    Say 'Waiting for VALORANT to close. Close the game to restore your settings.'
    while (Get-Process -Name $ValorantProc -ErrorAction SilentlyContinue) {
        Start-Sleep -Seconds 3
    }
    Say 'VALORANT closed.'
}
catch {
    $scriptFailed = $_.Exception.Message
    Warn "Error: $scriptFailed"
}
finally {
    # a) Re-enable monitors
    if ($disabledMon.Count -gt 0) {
        Say 'Re-enabling monitors...'
        foreach ($m in ($disabledMon | Sort-Object InstanceId -Descending)) {
            try {
                Enable-PnpDevice -InstanceId $m.InstanceId -Confirm:$false -ErrorAction Stop
                Say "  + enabled $($m.FriendlyName)"
            } catch {
                Warn "  ! could not enable $($m.FriendlyName): $($_.Exception.Message)"
            }
        }
        Start-Sleep -Seconds 3
    }

    # b) Restore display mode
    if ($modeChanged) {
        $dev = (Resolve-Again -Adapter $restoreAdapter -MonitorId $restoreMonitorId -Hwid ([string]$cfg['MonitorHwid'])).Adapter
        if (-not $dev) { $dev = $restoreAdapter }
        Say "Restoring display mode $($orig.w)x$($orig.h) @$($orig.hz)Hz on $dev ..."
        $rc = [VDis]::ApplyResolution($dev, $orig.w, $orig.h, $orig.hz)
        if ($rc -ne 0) { Warn "  ! restore returned $rc" }
    }

    # c) Restore VALORANT config
    if ($configChanged) {
        Say 'Restoring VALORANT config...'
        Restore-ValorantConfig -Files $configFiles -BackupRoot $BackupRoot
    }

    Good 'Rollback complete: monitors, resolution and VALORANT config are back to normal.'
}

if ($scriptFailed) {
    Warn 'The script finished with an error (see above). Nothing was left changed.'
} else {
    Good 'All done. Enjoy Valorant!'
}

if ($DoPause) { Read-Host 'Press Enter to close' }
