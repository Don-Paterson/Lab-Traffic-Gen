<#
.SYNOPSIS
    Generates background traffic load across a Check Point lab gateway.

.DESCRIPTION
    One script, two roles. Run it with -Role Server on the machine that receives
    traffic (A-Host or A-DMZ) and with -Role Client on the machine that sends it
    (A-GUI). It starts iperf3 and PsPing in the background, tracks what it
    started in a state file, and can report on or stop exactly those processes.

    Three loads can run at once, each optional:
      TCP throughput   - steady multi-stream TCP, spreads across both SND cores
      UDP packet rate  - small datagrams, high packets/sec, stresses the SNDs
      Connection rate  - repeated TCP connects, stresses the firewall workers

.PARAMETER Role
    Server on the receiving host, Client on the sending host. Required for
    -Action Start. Stop and Status read the role from the state file.

.PARAMETER Action
    Start, Stop, Status (default) or Install.

.PARAMETER Load
    Light, Medium (default) or Heavy. See $Profiles below for the values.
    Named -Load rather than -Profile because $Profile is a PowerShell
    automatic variable and shadowing it inside a script is asking for trouble.

.PARAMETER Target
    Client only. IP of the machine running -Role Server.
      192.168.11.201  A-Host  (gateway eth0 -> eth2)
      192.168.12.101  A-DMZ   (gateway eth0 -> eth3)
      192.168.21.201  B-Host  (across the site-to-site VPN; untested)

.PARAMETER Duration
    Seconds to run before stopping on its own. Default 3600.

.PARAMETER NoConnectionRate
    Client only. Skip the PsPing connection-rate loop.

.PARAMETER NoUdp
    Client only. Skip the UDP packet-rate load.

.EXAMPLE
    .\LabTraffic.ps1 -Role Server -Action Start

.EXAMPLE
    .\LabTraffic.ps1 -Role Client -Action Start -Load Medium -Target 192.168.11.201

.EXAMPLE
    .\LabTraffic.ps1 -Action Status
    .\LabTraffic.ps1 -Action Stop

.NOTES
    Lab use only. This generates a handful of long-lived flows plus repeated
    identical connections, which is far more uniform than production traffic.
    Requires a Check Point rule allowing Client -> Server on TCP/UDP 5201-5202
    and TCP 3389. See the README.
#>

[CmdletBinding()]
param(
    [ValidateSet('Server', 'Client')]
    [string]$Role,

    [ValidateSet('Start', 'Stop', 'Status', 'Install')]
    [string]$Action = 'Status',

    [ValidateSet('Light', 'Medium', 'Heavy')]
    [string]$Load = 'Medium',

    [string]$Target = '192.168.11.201',

    [int]$Duration = 3600,

    [switch]$NoConnectionRate,

    [switch]$NoUdp,

    [string]$InstallPath = 'C:\LabTraffic'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

$TcpPort  = 5201
$UdpPort  = 5202
$ConnPort = 3389      # RDP: a Windows kernel listener, keeps up with PsPing

$Profiles = @{
    Light  = @{ TcpRate = '50M';  Streams = 2; UdpRate = '20M';  UdpLen = 256; ConnPerSec = 5  }
    Medium = @{ TcpRate = '300M'; Streams = 4; UdpRate = '100M'; UdpLen = 256; ConnPerSec = 20 }
    Heavy  = @{ TcpRate = '800M'; Streams = 8; UdpRate = '300M'; UdpLen = 256; ConnPerSec = 40 }
}

# If these downloads fail (no internet in the lab), drop iperf3.exe and
# psping.exe into the bin folder by hand and the script will use them.
#
# iperf3 asset names carry the version (iperf-<ver>-win64.zip), so there is no
# static "latest" URL. Resolve-IperfUrl asks the GitHub API for the current
# release; $IperfUrl below is the offline/API-failure fallback.
$IperfVersion = '3.21'
$IperfUrl     = "https://github.com/ar51an/iperf3-win-builds/releases/download/$IperfVersion/iperf-$IperfVersion-win64.zip"
$PspingUrl    = 'https://live.sysinternals.com/psping64.exe'

$BinPath   = Join-Path $InstallPath 'bin'
$StatePath = Join-Path $InstallPath 'state.json'
$LoopPath  = Join-Path $InstallPath 'connrate.ps1'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step { param([string]$Message) Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "  $Message" -ForegroundColor Yellow }

function Test-Admin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-Folders {
    foreach ($path in @($InstallPath, $BinPath)) {
        if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
}

function Resolve-IperfUrl {
    <#
      Finds the download URL for the current iperf3 Windows build.
      Passed to Get-Tool as a scriptblock so it only runs when the exe is
      actually missing. Falls back to the pinned $IperfUrl on any failure.
    #>
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/ar51an/iperf3-win-builds/releases/latest' `
                                     -Headers @{ 'User-Agent' = 'Lab-Traffic-Gen' } -UseBasicParsing
        # Plain win64 build: skip the -static-auth, -dynamic-auth and win7 variants
        $asset = $release.assets |
                 Where-Object { $_.name -match '^iperf-[\d.]+-win64\.zip$' } |
                 Select-Object -First 1
        if ($asset) {
            Write-Step "Using iperf3 $($release.tag_name)"
            return $asset.browser_download_url
        }
        Write-Warn "No win64 asset in the latest release, falling back to $IperfVersion"
    }
    catch {
        Write-Warn "GitHub API lookup failed, falling back to $IperfVersion"
    }
    return $IperfUrl
}

function Get-Tool {
    <#
      Returns the full path to a tool, fetching it if missing.
      Looks in bin, then beside the script, then downloads.

      -Url takes either a string or a scriptblock. A scriptblock is only
      invoked if the download is actually needed, which keeps the GitHub API
      lookup out of the way when the tool is already present.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,      # iperf3.exe / psping.exe
        [Parameter(Mandatory)][object]$Url,
        [switch]$IsZip
    )

    $dest = Join-Path $BinPath $Name
    if (Test-Path $dest) { return $dest }

    $beside = Join-Path $PSScriptRoot $Name
    if (Test-Path $beside) {
        Copy-Item $beside $dest -Force
        Write-Ok "$Name copied from script folder"
        return $dest
    }

    # Resolve a deferred URL now that we know we need it.
    if ($Url -is [scriptblock]) { $Url = & $Url }

    Write-Step "Downloading $Name ..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if ($IsZip) {
            $zip = Join-Path $env:TEMP "labtraffic_$([IO.Path]::GetRandomFileName()).zip"
            Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing
            $extract = Join-Path $env:TEMP ([IO.Path]::GetFileNameWithoutExtension($zip))
            Expand-Archive -Path $zip -DestinationPath $extract -Force
            $found = Get-ChildItem -Path $extract -Filter $Name -Recurse | Select-Object -First 1
            if (-not $found) { throw "$Name not found inside the archive" }
            # iperf3 needs its DLLs alongside it
            Copy-Item (Join-Path $found.DirectoryName '*') $BinPath -Force
            Remove-Item $zip, $extract -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing
        }
    }
    catch {
        throw ("Could not fetch {0}: {1}`n" -f $Name, $_.Exception.Message) +
              ("Place {0} in {1} manually and run again." -f $Name, $BinPath)
    }

    if (-not (Test-Path $dest)) { throw "$Name still missing after download" }
    Write-Ok "$Name ready"
    return $dest
}

function Get-State {
    if (-not (Test-Path $StatePath)) { return $null }
    try { return Get-Content $StatePath -Raw | ConvertFrom-Json }
    catch { Write-Warn 'State file unreadable, ignoring it'; return $null }
}

function Set-State {
    param([Parameter(Mandatory)]$State)
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8
}

function Clear-State {
    if (Test-Path $StatePath) { Remove-Item $StatePath -Force }
}

function Get-TrackedProcess {
    <#
      Returns the live process for a tracked entry, or $null.
      Start time is checked as well as PID, so a recycled PID is not mistaken
      for one of ours and killed.
    #>
    param([Parameter(Mandatory)]$Entry)

    $proc = Get-Process -Id $Entry.Id -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    if ($Entry.StartTime) {
        $recorded = [datetime]$Entry.StartTime
        if ([math]::Abs(($proc.StartTime - $recorded).TotalSeconds) -gt 5) { return $null }
    }
    return $proc
}

function Start-Tracked {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList `
                          -WindowStyle Minimized -PassThru
    Start-Sleep -Milliseconds 400
    if ($proc.HasExited) {
        Write-Warn "$Label exited immediately (exit code $($proc.ExitCode)) - check the target and policy"
        return $null
    }
    Write-Ok "$Label started (PID $($proc.Id))"
    return [pscustomobject]@{
        Label     = $Label
        Id        = $proc.Id
        Name      = $proc.ProcessName
        StartTime = $proc.StartTime.ToString('o')
        Command   = "$FilePath $($ArgumentList -join ' ')"
    }
}

function Write-ConnRateScript {
    $body = @'
param(
    [Parameter(Mandatory)][string]$Psping,
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][double]$Interval,
    [Parameter(Mandatory)][int]$Duration
)
$deadline = (Get-Date).AddSeconds($Duration)
while ((Get-Date) -lt $deadline) {
    & $Psping -accepteula -q -n 200 -i $Interval "${Target}:${Port}" | Out-Null
    Start-Sleep -Milliseconds 200
}
'@
    Set-Content -Path $LoopPath -Value $body -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Firewall (server role)
# ---------------------------------------------------------------------------

function Set-LocalFirewall {
    if (-not (Test-Admin)) {
        Write-Warn 'Not running as Administrator: skipping Windows firewall rules.'
        Write-Warn 'If the client cannot connect, re-run this as Administrator once.'
        return
    }

    $rules = @(
        @{ Name = 'LabTraffic iperf3 TCP'; Protocol = 'TCP'; Ports = "$TcpPort-$UdpPort" },
        @{ Name = 'LabTraffic iperf3 UDP'; Protocol = 'UDP'; Ports = "$TcpPort-$UdpPort" }
    )

    foreach ($rule in $rules) {
        $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
        if ($existing) { continue }
        New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound `
                            -Protocol $rule.Protocol -LocalPort $rule.Ports `
                            -Action Allow -Profile Any | Out-Null
        Write-Ok "Firewall rule added: $($rule.Name)"
    }
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Invoke-StartServer {
    Initialize-Folders
    $iperf = Get-Tool -Name 'iperf3.exe' -Url { Resolve-IperfUrl } -IsZip
    Set-LocalFirewall

    $tracked = @()
    foreach ($port in @($TcpPort, $UdpPort)) {
        $entry = Start-Tracked -Label "iperf3 server :$port" -FilePath $iperf `
                               -ArgumentList @('-s', '-p', "$port")
        if ($entry) { $tracked += $entry }
    }

    if (-not $tracked) { throw 'No server processes started.' }

    Set-State ([pscustomobject]@{
        Role      = 'Server'
        Load      = $null
        Target    = $null
        Duration  = 0
        StartedAt = (Get-Date).ToString('o')
        Processes = $tracked
    })

    Write-Host ''
    Write-Host 'Server ready. Leave this host alone and start the client on A-GUI.' -ForegroundColor Green
}

function Invoke-StartClient {
    Initialize-Folders
    $settings = $Profiles[$Load]
    $iperf = Get-Tool -Name 'iperf3.exe' -Url { Resolve-IperfUrl } -IsZip

    Write-Step "Checking $Target`:$TcpPort ..."
    $reach = Test-NetConnection -ComputerName $Target -Port $TcpPort -WarningAction SilentlyContinue
    if (-not $reach.TcpTestSucceeded) {
        throw "Cannot reach $Target on TCP $TcpPort. Check that the server role is running, " +
              'the Windows firewall rules exist, and the Check Point policy allows this traffic.'
    }
    Write-Ok 'Server reachable'

    $tracked = @()

    $tcpArgs = @('-c', $Target, '-p', "$TcpPort", '-b', $settings.TcpRate,
                 '-P', "$($settings.Streams)", '-t', "$Duration", '-i', '0')
    $entry = Start-Tracked -Label "TCP load ($($settings.TcpRate) x$($settings.Streams))" `
                           -FilePath $iperf -ArgumentList $tcpArgs
    if ($entry) { $tracked += $entry }

    if (-not $NoUdp) {
        $udpArgs = @('-c', $Target, '-p', "$UdpPort", '-u', '-b', $settings.UdpRate,
                     '-l', "$($settings.UdpLen)", '-t', "$Duration", '-i', '0')
        $entry = Start-Tracked -Label "UDP load ($($settings.UdpRate), $($settings.UdpLen)B)" `
                               -FilePath $iperf -ArgumentList $udpArgs
        if ($entry) { $tracked += $entry }
    }

    if (-not $NoConnectionRate) {
        $psping = Get-Tool -Name 'psping.exe' -Url $PspingUrl
        Write-ConnRateScript
        $interval = [math]::Round(1 / $settings.ConnPerSec, 3)
        $loopArgs = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
                      '-File', "`"$LoopPath`"",
                      '-Psping', "`"$psping`"", '-Target', $Target, '-Port', "$ConnPort",
                      '-Interval', "$interval", '-Duration', "$Duration")
        $entry = Start-Tracked -Label "Connection rate (~$($settings.ConnPerSec)/sec)" `
                               -FilePath 'powershell.exe' -ArgumentList $loopArgs
        if ($entry) { $tracked += $entry }
    }

    if (-not $tracked) { throw 'No client processes started.' }

    Set-State ([pscustomobject]@{
        Role      = 'Client'
        Load      = $Load
        Target    = $Target
        Duration  = $Duration
        StartedAt = (Get-Date).ToString('o')
        Processes = $tracked
    })

    Write-Host ''
    Write-Host "Load running for $([math]::Round($Duration/60)) minutes, or until -Action Stop." -ForegroundColor Green
    Write-Host 'On the active gateway: cpview (CPU tab) and fwaccel stats -s' -ForegroundColor Gray
}

function Invoke-Stop {
    $state = Get-State
    if (-not $state) {
        Write-Warn 'Nothing tracked here. If something is still running, check Task Manager.'
        return
    }

    $stopped = 0
    foreach ($entry in $state.Processes) {
        $proc = Get-TrackedProcess -Entry $entry
        if ($proc) {
            try {
                Stop-Process -Id $proc.Id -Force
                Write-Ok "Stopped $($entry.Label) (PID $($entry.Id))"
                $stopped++
            }
            catch { Write-Warn "Could not stop PID $($entry.Id): $($_.Exception.Message)" }
        }
        else {
            Write-Step "$($entry.Label) had already finished"
        }
    }

    # The connection-rate loop may have a psping child mid-run.
    Get-Process -Name 'psping', 'psping64' -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force } catch { }
    }

    Clear-State
    Write-Host ''
    Write-Host "Stopped $stopped process(es)." -ForegroundColor Green
}

function Invoke-Status {
    $state = Get-State
    if (-not $state) {
        Write-Host 'No LabTraffic session tracked on this machine.' -ForegroundColor Gray
        return
    }

    $started = [datetime]$state.StartedAt
    $uptime  = (Get-Date) - $started

    Write-Host ''
    Write-Host "Role      : $($state.Role)"
    if ($state.Role -eq 'Client') {
        Write-Host "Load      : $($state.Load)"
        Write-Host "Target    : $($state.Target)"
        $left = $state.Duration - $uptime.TotalSeconds
        if ($left -gt 0) { Write-Host ("Remaining : {0:N0} min" -f ($left / 60)) }
        else { Write-Host 'Remaining : expired' }
    }
    Write-Host ("Started   : {0:yyyy-MM-dd HH:mm:ss} ({1:N0} min ago)" -f $started, $uptime.TotalMinutes)
    Write-Host ''

    $live = 0
    foreach ($entry in $state.Processes) {
        $proc = Get-TrackedProcess -Entry $entry
        if ($proc) {
            Write-Ok   "RUNNING  $($entry.Label)  (PID $($entry.Id))"
            $live++
        }
        else {
            Write-Warn "STOPPED  $($entry.Label)"
        }
    }

    Write-Host ''
    if ($live -eq 0) {
        Write-Host 'Nothing is running. Run -Action Stop to clear the state file.' -ForegroundColor Gray
    }
}

function Invoke-Install {
    if (-not (Test-Admin)) { throw 'Install needs an elevated PowerShell window.' }
    if (-not $Role) { throw 'Specify -Role Server or -Role Client for Install.' }

    Initialize-Folders
    $scriptCopy = Join-Path $InstallPath 'LabTraffic.ps1'
    if ($PSCommandPath -and ($PSCommandPath -ne $scriptCopy)) {
        Copy-Item $PSCommandPath $scriptCopy -Force
    }

    $taskName = "LabTraffic-$Role"
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptCopy`" -Role $Role -Action Start"
    if ($Role -eq 'Client') { $arguments += " -Load $Load -Target $Target -Duration $Duration" }

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                           -Principal $principal -Force | Out-Null

    Write-Ok "Scheduled task '$taskName' registered (runs at logon)."
    Write-Warn "Remove it with: Unregister-ScheduledTask -TaskName $taskName"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host "LabTraffic - $Action" -ForegroundColor White
Write-Host ('-' * 40) -ForegroundColor DarkGray

switch ($Action) {
    'Start' {
        if (-not $Role) { throw 'Specify -Role Server or -Role Client.' }

        $existing = Get-State
        if ($existing) {
            $live = @($existing.Processes | Where-Object { Get-TrackedProcess -Entry $_ })
            if ($live.Count -gt 0) {
                throw "A LabTraffic session is already running here ($($live.Count) process(es)). " +
                      'Run -Action Stop first, or -Action Status to see it.'
            }
            Clear-State
        }

        if ($Role -eq 'Server') { Invoke-StartServer } else { Invoke-StartClient }
    }
    'Stop'    { Invoke-Stop }
    'Status'  { Invoke-Status }
    'Install' { Invoke-Install }
}

Write-Host ''
