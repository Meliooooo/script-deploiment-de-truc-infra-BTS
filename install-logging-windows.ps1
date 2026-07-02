<#
.SYNOPSIS
    Deploys Sysmon + Winlogbeat on a Windows host and forwards logs to Logstash.

.DESCRIPTION
    Portable, idempotent installer. Safe to re-run (it reconciles state each time).
    Two ways to obtain the binaries:

      1. LOCAL SOURCE  : pass -SourcePath <folder> that already contains
                         winlogbeat.zip AND Sysmon.zip.
      2. INTERNET      : omit -SourcePath -> downloads Winlogbeat from Elastic,
                         Sysmon from Sysinternals and the SwiftOnSecurity config
                         from GitHub.

    Works as a manual one-liner OR as a GPO startup script (use the .bat wrapper).
    Requires Administrator privileges (to install Windows services / the Sysmon driver).

.PARAMETER LogstashHost
    IP address or hostname of your Logstash server. REQUIRED.

.PARAMETER LogstashPort
    Beats input port on Logstash (default 5044).

.PARAMETER SourcePath
    Local folder or UNC share containing winlogbeat.zip and Sysmon.zip.
    Omit to download from the internet instead.

.PARAMETER WinlogbeatVersion
    Winlogbeat version (default 9.0.0).

.EXAMPLE
    # Internet mode, manual run:
    .\install-logging-windows.ps1 -LogstashHost 10.0.0.5

.EXAMPLE
    # Local source mode (binaries already staged on a share):
    .\install-logging-windows.ps1 -LogstashHost 10.0.0.5 -SourcePath \\fileserver\share

.EXAMPLE
    # Non-default port and version:
    .\install-logging-windows.ps1 -LogstashHost logs.corp.local -LogstashPort 5045 -WinlogbeatVersion 9.0.0
#>
param(
    [Parameter(Mandatory = $true, HelpMessage = "IP/hostname of your Logstash server")]
    [string]$LogstashHost,

    [int]    $LogstashPort     = 5044,
    [string] $WinlogbeatVersion = "9.0.0",
    [string] $SourcePath,        # if set -> local source mode; if empty -> internet mode
    [string] $SysmonConfigUrl   = "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml",
    [string] $InstallDir        = "C:\Program Files\winlogbeat",
    [int]    $NetworkWaitMinutes = 5,
    [string] $LogFile           = "C:\ProgramData\install-logging-windows.log"
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

$LogstashEP = "${LogstashHost}:${LogstashPort}"
$useInternet = [string]::IsNullOrWhiteSpace($SourcePath)
$stage       = "C:\ProgramData\beats-stage"
$downloadDir = "$stage\downloads"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Log([string]$msg) {
    $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $msg
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop } catch {}
    Write-Host $line
}

function Download-File {
    param([string]$Url, [string]$OutFile, [int]$MinBytes = 0, [int]$Retries = 2)
    for ($attempt = 1; $attempt -le ($Retries + 1); $attempt++) {
        Write-Log "    download attempt $attempt : $Url"
        try {
            # .NET WebClient handles large files more reliably than IWR and avoids
            # the in-memory buffering that can hang on transparent proxies.
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("user-agent", "install-logging-windows/1.0")
            $wc.DownloadFile($Url, $OutFile)
            $size = (Get-Item $OutFile).Length
            if ($MinBytes -gt 0 -and $size -lt $MinBytes) {
                throw "truncated: got $size bytes, expected >= $MinBytes (transparent proxy?)"
            }
            Write-Log "    downloaded OK ($size bytes)"
            return $true
        } catch {
            Write-Log "    download attempt $attempt failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 3
        }
    }
    return $false
}

# Expand an archive, flattening a single top-level folder if present (handles both
# the official Elastic zip, which has a top folder, and flat zips).
function Expand-BeatArchive([string]$Zip, [string]$Dest) {
    $tmp = "$stage\extract-tmp"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $Zip -DestinationPath $tmp -Force -ErrorAction Stop
    $top = Get-ChildItem $tmp -ErrorAction SilentlyContinue
    $src = if (($top.Count -eq 1) -and $top.PSIsContainer) { $top[0].FullName } else { $tmp }
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Force -Path $Dest | Out-Null }
    Copy-Item -Path "$src\*" -Destination $Dest -Recurse -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Log "===== install-logging-windows START (computer=$env:COMPUTERNAME user=$env:USERNAME) ====="
Write-Log "Logstash=$LogstashEP | source=$(if ($useInternet) {'INTERNET'} else {$SourcePath}) | winlogbeat=$WinlogbeatVersion | dir=$InstallDir"

# Admin check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Log "WARNING: not running as Administrator - service/driver install will likely fail" }

if (-not (Test-Path $stage))      { New-Item -ItemType Directory -Force -Path $stage      | Out-Null }
if (-not (Test-Path $downloadDir)) { New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null }
New-Item -ItemType Directory -Force -Path "C:\ProgramData\winlogbeat\logs" | Out-Null

# ---------------------------------------------------------------------------
# If using a LOCAL SOURCE, wait for the share to be reachable (covers the GPO
# startup race where the network is not up yet).
# ---------------------------------------------------------------------------
if (-not $useInternet) {
    $ready = $false
    for ($i = 1; $i -le ($NetworkWaitMinutes * 12); $i++) {
        if (Test-Path "$SourcePath\winlogbeat.zip") { $ready = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $ready) { Write-Log "ABORT: $SourcePath\winlogbeat.zip unreachable after $NetworkWaitMinutes min"; exit 1 }
    Write-Log "Source path reachable"
}

# ===========================================================================
# 1. SYSMON
# ===========================================================================
$sysmonSvc = Get-Service -Name "Sysmon*","Sysmon64" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($sysmonSvc) {
    Write-Log "Sysmon already installed ($($sysmonSvc.Name)=$($sysmonSvc.Status)) - skipping"
} else {
    Write-Log "Installing Sysmon..."
    try {
        $sysmonStage = "$stage\Sysmon"
        if (Test-Path $sysmonStage) { Remove-Item $sysmonStage -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $sysmonStage | Out-Null

        if ($useInternet) {
            $ok = Download-File -Url "https://download.sysinternals.com/files/Sysmon.zip" `
                                -OutFile "$downloadDir\Sysmon.zip" -MinBytes 1000000
            if (-not $ok) { throw "Sysmon.zip download failed" }
            Expand-Archive "$downloadDir\Sysmon.zip" -DestinationPath $sysmonStage -Force
            # SwiftOnSecurity config
            $cfgOk = Download-File -Url $SysmonConfigUrl -OutFile "$sysmonStage\sysmonconfig.xml" -MinBytes 10000
            if (-not $cfgOk) { Write-Log "  WARN: could not download Sysmon config - will use defaults" }
        } else {
            Copy-Item "$SourcePath\Sysmon.zip" "$downloadDir\Sysmon.zip" -Force
            Expand-Archive "$downloadDir\Sysmon.zip" -DestinationPath $sysmonStage -Force
        }

        $exe = Join-Path $sysmonStage "Sysmon64.exe"
        if (-not (Test-Path $exe)) { $exe = Join-Path $sysmonStage "Sysmon.exe" }
        if (-not (Test-Path $exe)) { throw "Sysmon executable not found in archive" }
        $cfg = Join-Path $sysmonStage "sysmonconfig.xml"

        if (Test-Path $cfg) {
            Write-Log "  $exe -accepteula -i `"$cfg`""
            & $exe -accepteula -i $cfg *>&1 | ForEach-Object { Write-Log "    sysmon: $_" }
        } else {
            Write-Log "  $exe -accepteula -i  (defaults)"
            & $exe -accepteula -i *>&1 | ForEach-Object { Write-Log "    sysmon: $_" }
        }
        Start-Sleep -Seconds 3
        $s2 = Get-Service -Name "Sysmon*","Sysmon64" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($s2) { Write-Log "Sysmon installed OK ($($s2.Name)=$($s2.Status))" }
        else { Write-Log "WARN: Sysmon service not found after install" }
    } catch {
        Write-Log "ERROR (Sysmon): $($_.Exception.Message)"
    }
}

# ===========================================================================
# 2. WINLOGBEAT
# ===========================================================================
try {
    Write-Log "Deploying Winlogbeat to $InstallDir"

    # Stop + remove any existing service first: the running process locks
    # winlogbeat.exe and the overwrite would fail with "access denied".
    $existing = Get-Service winlogbeat -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "  stopping existing winlogbeat service before overwrite"
        Stop-Service winlogbeat -Force -ErrorAction SilentlyContinue
        try { (Get-Service winlogbeat).WaitForStatus('Stopped', '00:00:30') } catch {}
        Start-Sleep -Seconds 1
        sc.exe delete winlogbeat | Out-Null
        Start-Sleep -Seconds 2
    }

    # Acquire winlogbeat.zip
    $wlbZip = "$downloadDir\winlogbeat.zip"
    if ($useInternet) {
        $url = "https://artifacts.elastic.co/downloads/beats/winlogbeat/winlogbeat-$WinlogbeatVersion-windows-x86_64.zip"
        $ok = Download-File -Url $url -OutFile $wlbZip -MinBytes 10000000   # >= 10 MB sanity floor
        if (-not $ok) { throw "winlogbeat.zip download failed (check connectivity / proxy)" }
    } else {
        Copy-Item "$SourcePath\winlogbeat.zip" $wlbZip -Force -ErrorAction Stop
    }

    Expand-BeatArchive -Zip $wlbZip -Dest $InstallDir

    $exePath = Join-Path $InstallDir "winlogbeat.exe"
    if (-not (Test-Path $exePath)) { throw "winlogbeat.exe missing after extraction (corrupt/truncated zip?)" }
    $exeSize = (Get-Item $exePath).Length
    if ($exeSize -lt 52428800) {  # < 50 MB -> almost certainly truncated
        throw "winlogbeat.exe only $exeSize bytes after extraction - archive is truncated. Use -SourcePath with a known-good zip."
    }
    Write-Log "  winlogbeat.exe OK ($exeSize bytes)"

    # Clean Logstash config + Sysmon/PowerShell event sources
    $yml = @"
winlogbeat.event_logs:
  - name: Application
  - name: Security
  - name: System
  - name: Microsoft-Windows-Sysmon/Operational
  - name: Microsoft-Windows-PowerShell/Operational
  - name: Windows PowerShell

output.logstash:
  hosts: ["$LogstashEP"]

logging.level: info
logging.to_files: true
logging.files:
  path: C:/ProgramData/winlogbeat/logs
  name: winlogbeat
  keepfiles: 7
  permissions: 0640

path.data: C:/ProgramData/winlogbeat
path.logs: C:/ProgramData/winlogbeat/logs
"@
    Set-Content -Path (Join-Path $InstallDir "winlogbeat.yml") -Value $yml -Encoding UTF8 -Force
    Write-Log "  winlogbeat.yml written (-> $LogstashEP)"

    # Validate config
    $test = & $exePath test config -c "$InstallDir\winlogbeat.yml" --path.home "$InstallDir" --path.data "C:\ProgramData\winlogbeat" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "winlogbeat test config failed (exit $LASTEXITCODE): $test"
    }
    Write-Log "  config test OK"

    # Create the Windows service (self-contained - does not rely on the Elastic
    # install-service script, which may be absent or named differently).
    $binPath = "`"$exePath`" --environment=windows_service" +
               " -c `"$InstallDir\winlogbeat.yml`"" +
               " --path.home `"$InstallDir`"" +
               " --path.data `"$env:PROGRAMDATA\winlogbeat`"" +
               " --path.logs `"$env:PROGRAMDATA\winlogbeat\logs`"" +
               " -E logging.files.redirect_stderr=true"
    New-Service -Name winlogbeat -DisplayName Winlogbeat -BinaryPathName $binPath -StartupType Automatic | Out-Null
    sc.exe config winlogbeat start= delayed-auto | Out-Null
    Start-Sleep -Seconds 2
    Start-Service winlogbeat -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $wlb = Get-Service winlogbeat -ErrorAction SilentlyContinue
    Write-Log "  winlogbeat service: status=$($wlb.Status) startType=$($wlb.StartType)"
} catch {
    Write-Log "ERROR (Winlogbeat): $($_.Exception.Message)"
}

Write-Log "===== install-logging-windows END ====="
