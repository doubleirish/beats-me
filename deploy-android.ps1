<#
.SYNOPSIS
  Builds beats-me and deploys it to an Android phone over Wi-Fi debugging.

.DESCRIPTION
  Connects to the phone automatically. It tries devices adb already sees, then
  the last-used address, then mDNS discovery, and pairs only as a last resort.
  It rebuilds the arm64 release APK only when the sources changed, then
  installs and launches the app.

.PARAMETER Attach
  Use `flutter run --release` instead (stays attached: logs + hot restart).
.PARAMETER Logs
  After install and launch, stream the app's logcat output (Ctrl+C to stop).
.PARAMETER Force
  Rebuild even if no source changes were detected.
.PARAMETER Pair
  Go straight to the Wi-Fi pairing flow.
.PARAMETER Device
  adb serial to deploy to (skips detection and selection).
#>
[CmdletBinding()]
param(
    [switch]$Attach,
    [switch]$Logs,
    [switch]$Force,
    [switch]$Pair,
    [string]$Device
)

$ErrorActionPreference = 'Stop'
$AppId = 'com.beatsme.beats_me'
$Root = $PSScriptRoot
$StateDir = Join-Path $Root '.deploy'
$DeviceFile = Join-Path $StateDir 'device.json'
$BuildFile = Join-Path $StateDir 'last-build.json'
$BuildNumberFile = Join-Path $StateDir 'build-number'
$Apk = Join-Path $Root 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'

function Info($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# ---------- tool resolution ----------
function Resolve-Flutter {
    $local = Join-Path $Root '..\flutter-sdk\bin\flutter.bat'
    if (Test-Path $local) { return (Resolve-Path $local).Path }
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Fail 'Flutter not found (looked in ..\flutter-sdk and PATH).'
}

function Resolve-Adb {
    $candidates = @()
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe' }
    if ($env:ANDROID_HOME) { $candidates += Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe' }
    if ($env:ANDROID_SDK_ROOT) { $candidates += Join-Path $env:ANDROID_SDK_ROOT 'platform-tools\adb.exe' }
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Fail 'adb not found. Install the Android SDK platform-tools.'
}

$Flutter = Resolve-Flutter
$Adb = Resolve-Adb

# Runs adb and returns its combined output as strings, without throwing on stderr.
function Invoke-Adb {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Adb @args 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $prev }
}

# ---------- state ----------
function Read-Json($path) {
    if (Test-Path $path) {
        try { return Get-Content $path -Raw | ConvertFrom-Json } catch { }
    }
    return $null
}

function Write-Json($path, $obj) {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory $StateDir | Out-Null }
    $obj | ConvertTo-Json | Set-Content $path -Encoding UTF8
}

# ---------- device connection ----------
function Get-AdbDevices {
    $list = @()
    foreach ($line in (Invoke-Adb devices)) {
        if ($line -match '^(\S+)\s+(device|unauthorized|offline)\b') {
            $list += [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2] }
        }
    }
    return $list
}

function Get-OnlineDevices {
    $all = Get-AdbDevices
    foreach ($d in $all) {
        if ($d.State -eq 'unauthorized') { Warn "$($d.Serial) is unauthorized - accept the debugging prompt on the phone." }
        elseif ($d.State -eq 'offline') { Warn "$($d.Serial) is offline." }
    }
    return @($all | Where-Object State -eq 'device')
}

function Get-MdnsServices($type) {
    $out = Invoke-Adb mdns services
    $found = @()
    foreach ($line in $out) {
        if ($line -match "^(\S+)\s+_adb-tls-$type\._tcp\.?\s+(\d+\.\d+\.\d+\.\d+:\d+)") {
            $found += [pscustomobject]@{ Name = $Matches[1]; Address = $Matches[2] }
        }
    }
    return $found
}

function Connect-Address($address) {
    $out = (Invoke-Adb connect $address) -join ' '
    if ($out -match 'connected to') {
        Ok "Connected to $address"
        return $true
    }
    Warn "Could not connect to ${address}: $out"
    return $false
}

function Try-MdnsConnect {
    Info 'Looking for the phone via mDNS...'
    $services = Get-MdnsServices 'connect'
    $connected = $false
    foreach ($s in $services) {
        if (Connect-Address $s.Address) {
            $script:LastAddress = $s.Address
            $connected = $true
        }
    }
    if (-not $services) { Warn 'No phones advertising wireless debugging were found.' }
    Start-Sleep -Milliseconds 500
    return $connected
}

function Start-Pairing {
    Write-Host ''
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ' PHONE SETUP (one time)'
    Write-Host '  1. Settings > About phone > tap "Build number" 7 times.'
    Write-Host '  2. Settings > System > Developer options > turn on'
    Write-Host '     "Wireless debugging" (phone and PC on the same Wi-Fi).'
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
    if (Start-QrPairing) { return }
    Write-Host ' Falling back to pairing code:'
    Write-Host '  3. Wireless debugging > "Pair device with pairing code".'
    Write-Host '     Keep that dialog open while you pair.'
    Read-Host 'Press Enter once the pairing dialog is open on the phone' | Out-Null

    $pairing = @(Get-MdnsServices 'pairing')
    if ($pairing.Count -ge 1) {
        $address = $pairing[0].Address
        Ok "Found pairing service at $address"
    } else {
        $address = Read-Host 'Pairing IP:port (from the pairing dialog)'
    }
    $code = Read-Host '6-digit pairing code'
    if (-not $address -or -not $code) { Fail 'Pairing cancelled.' }

    $out = (Invoke-Adb pair $address $code) -join ' '
    if ($out -notmatch 'Successfully paired') { Fail "Pairing failed: $out" }
    Ok 'Paired.'
    Start-Sleep -Seconds 2
}

function Show-QrCode($text) {
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { return $false }
    $script = @'
import sys
try:
    import segno
except ImportError:
    import subprocess
    subprocess.call([sys.executable, '-m', 'pip', 'install', '--user', '-q', 'segno'], stdout=subprocess.DEVNULL)
    import importlib, site
    importlib.invalidate_caches()
    site.main()
    import segno
m = [list(r) for r in segno.make(sys.argv[1], error='m').matrix]
b = 2
w = len(m) + 2 * b
g = [[0] * w for _ in range(w)]
for y, r in enumerate(m):
    for x, v in enumerate(r):
        g[y + b][x + b] = v
if w % 2: g.append([0] * w)
sys.stdout.reconfigure(encoding='utf-8')
# Light modules are drawn as filled blocks, so this assumes a dark terminal theme.
for y in range(0, len(g), 2):
    print(''.join({(0,0):'\u2588',(1,0):'\u2584',(0,1):'\u2580',(1,1):' '}[(g[y][x], g[y+1][x])] for x in range(w)))
'@
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $prevEnc = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $out = $script | & $py.Source - $text 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $false }
        $out | ForEach-Object { Write-Host $_ }
        return $true
    } catch { return $false }
    finally { $ErrorActionPreference = $prev; [Console]::OutputEncoding = $prevEnc }
}

# Pairs via the phone's "Pair device with QR code"; no IPs or codes to type.
function Start-QrPairing {
    $chars = 'abcdefghjkmnpqrstuvwxyz23456789'.ToCharArray()
    $suffix = -join (1..5 | ForEach-Object { $chars | Get-Random })
    $name = "beatsme-$suffix"
    $password = -join (1..8 | ForEach-Object { $chars | Get-Random })

    Write-Host ''
    Write-Host ' On the phone: Developer options > Wireless debugging >'
    Write-Host '   "Pair device with QR code", then scan this:'
    Write-Host ''
    if (-not (Show-QrCode "WIFI:T:ADB;S:$name;P:$password;;")) {
        Warn 'Could not render a QR code (needs Python); falling back.'
        return $false
    }
    Info 'Waiting for the scan (up to 90s, Ctrl+C to abort)...'
    $address = $null
    for ($i = 0; $i -lt 45 -and -not $address; $i++) {
        $svc = @(Get-MdnsServices 'pairing') | Where-Object Name -eq $name | Select-Object -First 1
        if ($svc) { $address = $svc.Address } else { Start-Sleep -Seconds 2 }
    }
    if (-not $address) { Warn 'QR code was not scanned in time.'; return $false }

    $out = (Invoke-Adb pair $address $password) -join ' '
    if ($out -notmatch 'Successfully paired') { Warn "QR pairing failed: $out"; return $false }
    Ok 'Paired via QR code.'
    Start-Sleep -Seconds 2
    return $true
}

function Select-Device($devices, $preferred) {
    if ($devices.Count -eq 1) { return $devices[0].Serial }
    Write-Host 'Several devices are connected:'
    $default = 1
    for ($i = 0; $i -lt $devices.Count; $i++) {
        $mark = ''
        if ($devices[$i].Serial -eq $preferred) { $default = $i + 1; $mark = ' (last used)' }
        Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $devices[$i].Serial, $mark)
    }
    $choice = Read-Host "Choose a device [$default]"
    if (-not $choice) { $choice = $default }
    $n = 0
    if (-not [int]::TryParse("$choice", [ref]$n) -or $n -lt 1 -or $n -gt $devices.Count) { Fail 'Invalid choice.' }
    return $devices[$n - 1].Serial
}

function Connect-Phone {
    $state = Read-Json $DeviceFile
    $script:LastAddress = if ($state) { $state.address } else { $null }
    $lastSerial = if ($state) { $state.serial } else { $null }

    Invoke-Adb start-server | Out-Null

    if ($Device) {
        if ($Device -match '^\d+\.\d+\.\d+\.\d+:\d+$') { Connect-Address $Device | Out-Null }
        $serial = $Device
    } else {
        if ($Pair) { Start-Pairing; Try-MdnsConnect | Out-Null }

        $devices = @(Get-OnlineDevices)
        if (-not $devices -and $script:LastAddress) {
            Info "Reconnecting to last address $($script:LastAddress)..."
            Connect-Address $script:LastAddress | Out-Null
            $devices = @(Get-OnlineDevices)
        }
        if (-not $devices) {
            Try-MdnsConnect | Out-Null
            $devices = @(Get-OnlineDevices)
        }
        if (-not $devices -and -not $Pair) {
            Warn 'No phone found. Make sure Wireless debugging is ON and the phone is awake.'
            $answer = Read-Host 'Pair this PC with the phone now? (y/N)'
            if ($answer -match '^[yY]') {
                Start-Pairing
                Try-MdnsConnect | Out-Null
                $devices = @(Get-OnlineDevices)
            }
        }
        if (-not $devices) {
            $manual = Read-Host 'IP:port from the main Wireless debugging screen (blank to abort)'
            if (-not $manual) { Fail 'No device connected.' }
            if (Connect-Address $manual) { $script:LastAddress = $manual }
            $devices = @(Get-OnlineDevices)
        }
        if (-not $devices) { Fail 'Could not connect to a phone.' }
        $serial = Select-Device $devices $lastSerial
    }

    $online = Get-OnlineDevices | Where-Object Serial -eq $serial
    if (-not $online) { Fail "Device $serial is not online." }

    if ($serial -match '^\d+\.\d+\.\d+\.\d+:\d+$') { $script:LastAddress = $serial }
    Write-Json $DeviceFile ([ordered]@{ serial = $serial; address = $script:LastAddress })
    $model = ((Invoke-Adb -s $serial shell getprop ro.product.model) -join '').Trim()
    Ok "Using $serial $(if ($model) { "($model)" })"
    return $serial
}

# ---------- build ----------
function Get-SourceFingerprint {
    $shared = Join-Path $Root '..\shared_core'
    $inputs = @(
        @{ Path = Join-Path $Root 'lib'; Dir = $true },
        @{ Path = Join-Path $Root 'android'; Dir = $true },
        @{ Path = Join-Path $Root 'assets'; Dir = $true },
        @{ Path = Join-Path $Root 'pubspec.yaml'; Dir = $false },
        @{ Path = Join-Path $Root 'pubspec.lock'; Dir = $false },
        @{ Path = Join-Path $shared 'lib'; Dir = $true },
        @{ Path = Join-Path $shared 'pubspec.yaml'; Dir = $false }
    )
    # Generated/IDE files that change without source edits.
    $exclude = '\\(build|\.gradle|\.cxx|\.idea|\.kotlin)\\|\\local\.properties$|\\GeneratedPluginRegistrant\.java$|\.iml$'

    $files = @()
    foreach ($i in $inputs) {
        if (-not (Test-Path $i.Path)) { continue }
        if ($i.Dir) {
            $files += Get-ChildItem $i.Path -Recurse -File -Force | Where-Object { $_.FullName -notmatch $exclude }
        } else {
            $files += Get-Item $i.Path
        }
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in ($files | Sort-Object FullName)) {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $hash = [BitConverter]::ToString($sha.ComputeHash($bytes))
        [void]$sb.AppendLine("$($f.FullName.Substring($Root.Length))|$hash")
    }
    $all = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    return ([BitConverter]::ToString($sha.ComputeHash($all))).Replace('-', '')
}

function Build-Apk {
    $fingerprint = Get-SourceFingerprint
    $last = Read-Json $BuildFile
    if (-not $Force -and $last -and $last.fingerprint -eq $fingerprint -and (Test-Path $Apk)) {
        Ok "No source changes since build $($last.buildNumber) - reusing existing APK."
        return
    }

    $buildNumber = 1
    if (Test-Path $BuildNumberFile) {
        $buildNumber = [int](Get-Content $BuildNumberFile -Raw).Trim() + 1
    }

    Info "Building release APK (arm64, build $buildNumber)..."
    & $Flutter build apk --release --target-platform android-arm64 --split-per-abi --build-number $buildNumber
    if ($LASTEXITCODE -ne 0) { Fail "flutter build failed (exit $LASTEXITCODE)." }
    if (-not (Test-Path $Apk)) { Fail "APK not found at $Apk" }

    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory $StateDir | Out-Null }
    Set-Content $BuildNumberFile $buildNumber
    Write-Json $BuildFile ([ordered]@{ fingerprint = $fingerprint; buildNumber = $buildNumber; builtAt = (Get-Date).ToString('s') })
}

# ---------- install / launch ----------
function Install-Apk($serial) {
    Info 'Installing...'
    $out = (Invoke-Adb -s $serial install -r $Apk) -join "`n"
    if ($out -match 'Success') { Ok 'Installed.'; return }

    if ($out -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|INSTALL_FAILED_VERSION_DOWNGRADE') {
        Warn 'The installed app has a different signature or a newer version, so it cannot be updated in place.'
        $answer = Read-Host 'Uninstall it first? This DELETES the app''s data on the phone (y/N)'
        if ($answer -match '^[yY]') {
            Invoke-Adb -s $serial uninstall $AppId | Out-Null
            $out = (Invoke-Adb -s $serial install $Apk) -join "`n"
            if ($out -match 'Success') { Ok 'Installed.'; return }
        }
    }
    Fail "Install failed:`n$out"
}

function Start-App($serial) {
    Invoke-Adb -s $serial shell monkey -p $AppId -c android.intent.category.LAUNCHER 1 | Out-Null
    Ok 'Launched.'
}

function Show-Logs($serial) {
    $appPid = $null
    for ($i = 0; $i -lt 20 -and -not $appPid; $i++) {
        $appPid = ((Invoke-Adb -s $serial shell pidof $AppId) -join '').Trim()
        if (-not $appPid) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $appPid) { Fail 'App process not found; cannot show logs.' }
    Info "Streaming logs for PID $appPid (Ctrl+C to stop)..."
    & $Adb -s $serial logcat --pid=$appPid
}

# ---------- main ----------
Set-Location $Root
$serial = Connect-Phone

if ($Attach) {
    Info 'Starting flutter run (release, attached)...'
    & $Flutter run --release -d $serial
    exit $LASTEXITCODE
}

Build-Apk
Install-Apk $serial
Start-App $serial
if ($Logs) { Show-Logs $serial }
Info 'Done.'
