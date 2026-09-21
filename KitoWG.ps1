<#
    ============================================================
      KitoWG  -  WireGuard + Cloudflare WARP (COMPLETELY FREE)
    ============================================================
      Cloudflare WARP is a WireGuard-based VPN that is completely
      free, unlimited, and requires NO ACCOUNT. This module:

        1) Installs the WireGuard client (if needed).
        2) Creates a WARP account for you automatically
           (local key generation + the WARP registration API).
        3) Picks a RANDOM country from the WARP endpoints
           and opens the WireGuard tunnel.
        4) Verifies the exit IP and its country. On failure it
           rolls back automatically (your internet is not cut off).

      Actions (-Action):
        Install   : Install / verify WireGuard
        Register  : Create a free WARP account
        Up        : Open the tunnel (default) - pick a country and connect
        Scan      : Test endpoints, learn the country mapping
        Down      : Close the tunnel, back to the normal connection
        Status    : Active tunnel + exit IP/country
        Reset     : Delete the WARP account and start over

      Country: -Country Random  (random, outside your own country)
               -Country ALL     (any)
               -Country DE,NL   (specific countries)

      Examples:
        KitoWG.ps1 -Action Up -Country Random
        KitoWG.ps1 -Action Up -Country DE,NL -Attempts 8
        KitoWG.ps1 -Action Scan -MaxScan 15
        KitoWG.ps1 -Action Down

      NOTE: The WARP exit country depends on the endpoint you connect
      to and on your location; country selection is "best effort".
      The endpoint -> country mapping is learned as you use it and is
      cached. For an exact country, you can drop your own .conf files
      (ProtonVPN Free / Windscribe Free) into the wgconf folder.
    ============================================================
#>

[CmdletBinding()]
param(
    [ValidateSet('Install','Register','Up','Scan','Down','Status','Reset')]
    [string]$Action = 'Up',

    [string]$Country    = 'Random',        # Random | ALL | DE,NL,US
    [int]   $Attempts   = 5,               # Number of endpoints to try if the country does not match
    [int]   $MaxScan    = 12,              # Endpoints to test in Scan mode
    [string]$Interface  = 'KitoWG',        # Tunnel (adapter) name
    [string]$Endpoint,                     # Specific endpoint: ip:port
    [string]$Profile,                      # Your own .conf file
    [string]$ProfileDir,                   # Country-based .conf folder
    [switch]$FetchEndpoints,                # Download a list of working endpoints
    [switch]$Strict,                       # Do not retry from scratch if the country does not match
    [switch]$DryRun,
    [switch]$NoElevate
)

$ErrorActionPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$LogFile    = Join-Path $ScriptDir 'kitoip.log'
$WgDir      = 'C:\Program Files\WireGuard'
$WgExe      = Join-Path $WgDir 'wireguard.exe'
$WgTool     = Join-Path $WgDir 'wg.exe'
$AccountFile= Join-Path $ScriptDir 'warp-account.json'
$CacheFile  = Join-Path $ScriptDir 'warp_endpoints.json'
$ConfDir    = Join-Path $ScriptDir 'wgconf'
$TunnelName = $Interface

# ------------------------------------------------------------------
#  Logging
# ------------------------------------------------------------------
function Write-Log {
    param([string]$Msg, [string]$Color = 'Gray')
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host $Msg -ForegroundColor $Color
    Add-Content -Path $LogFile -Value "[$stamp] [WG] $Msg" -ErrorAction SilentlyContinue
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ------------------------------------------------------------------
#  Exit IP / country lookup (goes through the tunnel)
# ------------------------------------------------------------------
function Get-PublicGeo {
    param([int]$Timeout = 10)
    try {
        $r = Invoke-RestMethod -Uri 'https://ipwho.is/' -TimeoutSec $Timeout -ErrorAction Stop
        if ($r.success -eq $true -and $r.ip) {
            return [pscustomobject]@{ IP=$r.ip; CC=$r.country_code; Country=$r.country; City=$r.city }
        }
    } catch {}
    try {
        $r2 = Invoke-RestMethod -Uri 'http://ip-api.com/json/?fields=status,country,countryCode,city,query' -TimeoutSec $Timeout -ErrorAction Stop
        if ($r2.status -eq 'success') {
            return [pscustomobject]@{ IP=$r2.query; CC=$r2.countryCode; Country=$r2.country; City=$r2.city }
        }
    } catch {}
    return $null
}

function Test-Internet {
    param([int]$Retries = 3, [int]$Sleep = 3)
    for ($i = 1; $i -le $Retries; $i++) {
        $g = Get-PublicGeo -Timeout 8
        if ($g) { return $g }
        Start-Sleep -Seconds $Sleep
    }
    return $null
}

# ------------------------------------------------------------------
#  Cache (endpoint -> country) management
# ------------------------------------------------------------------
function Get-Cache {
    if (Test-Path $CacheFile) {
        try { return @(Get-Content $CacheFile -Raw | ConvertFrom-Json) } catch {}
    }
    return @()
}
function Add-Cache {
    param([string]$Ep, [string]$Ip, [string]$CC, [string]$CountryName, [string]$City)
    $c = @(Get-Cache | Where-Object { $_.endpoint -ne $Ep })
    $c += [pscustomobject]@{ endpoint=$Ep; ip=$Ip; cc=$CC; country=$CountryName; city=$City; ts=(Get-Date).ToString('s') }
    ($c | ConvertTo-Json -Depth 4) | Set-Content -Path $CacheFile -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------
#  Candidate endpoint list
# ------------------------------------------------------------------
function Get-EndpointCandidates {
    param([switch]$Fetch)

    $list = New-Object 'System.Collections.Generic.List[string]'

    # Endpoints compiled from known WARP ranges that are reported to work
    $curated = @(
        '162.159.192.1:2408','162.159.192.1:500','162.159.193.1:2408','162.159.195.1:2408',
        '162.159.192.11:854','162.159.192.20:854','162.159.192.24:854','162.159.192.49:854',
        '162.159.192.55:854','162.159.192.66:854','162.159.192.68:854','162.159.192.72:854',
        '162.159.192.108:854','162.159.192.143:854','162.159.192.214:854','162.159.192.227:854',
        '162.159.192.243:854','162.159.195.121:854','162.159.195.138:854','162.159.195.162:854',
        '162.159.195.163:854','162.159.195.185:854','162.159.195.202:854','162.159.195.214:854',
        '162.159.195.230:854','162.159.195.249:854','162.159.195.253:854',
        '188.114.96.103:1014','188.114.96.154:2371','188.114.96.186:1014','188.114.96.196:2371',
        '188.114.97.101:1014','188.114.97.107:2371','188.114.97.126:1014','188.114.97.132:2371',
        '188.114.98.4:1014','188.114.98.31:2371','188.114.98.67:1014','188.114.98.96:2371',
        '188.114.98.147:1014','188.114.99.32:1014','188.114.99.49:2371','188.114.99.87:1014',
        '188.114.99.112:2371','188.114.99.148:1014','188.114.99.161:2371','188.114.99.177:1014',
        '162.159.204.1:2408','162.159.204.1:500'
    )
    $list.AddRange([string[]]$curated)

    if ($Fetch) {
        $urls = @(
            'https://raw.githubusercontent.com/freedomnet25500/clean-ip-warp-list/main/ip%20list'
        )
        foreach ($u in $urls) {
            try {
                $resp = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 25 -Headers @{ 'User-Agent'='Mozilla/5.0' }
                $m = [regex]::Matches($resp.Content, '\b\d{1,3}(?:\.\d{1,3}){3}:\d{2,5}\b')
                foreach ($x in $m) { $list.Add($x.Value) }
            } catch { Write-Log ("Endpoint source could not be fetched: {0}" -f $u) 'DarkGray' }
        }
    }

    return @($list | Select-Object -Unique)
}

# ------------------------------------------------------------------
#  WireGuard presence / installation
# ------------------------------------------------------------------
function Test-WireGuard {
    (Test-Path $WgExe) -and (Test-Path $WgTool)
}

function Install-WireGuard {
    Write-Log 'Installing the WireGuard client (winget)...' 'Yellow'
    $ok = $false
    try {
        & winget install --id WireGuard.WireGuard -e `
            --accept-package-agreements --accept-source-agreements --silent 2>&1 |
            ForEach-Object { Write-Host $_ }
        $ok = Test-WireGuard
    } catch { }

    if (-not $ok) {
        Write-Log 'winget failed, downloading the official MSI...' 'Yellow'
        $msi = Join-Path $env:TEMP 'wireguard-installer.exe'
        try {
            Invoke-WebRequest -Uri 'https://download.wireguard.com/windows-client/wireguard-installer.exe' `
                -OutFile $msi -UseBasicParsing -TimeoutSec 180
            Start-Process -FilePath $msi -ArgumentList '/quiet' -Wait
            $ok = Test-WireGuard
        } catch { Write-Log ("Download/install error: {0}" -f $_.Exception.Message) 'Red' }
    }

    if ($ok) { Write-Log 'WireGuard installed.' 'Green' }
    else     { Write-Log 'ERROR: WireGuard could not be installed. Install it manually: https://www.wireguard.com/install/' 'Red' }
    return $ok
}

# ------------------------------------------------------------------
#  WARP account
# ------------------------------------------------------------------
function New-WarpAccount {
    if (-not (Test-WireGuard)) {
        if (-not (Install-WireGuard)) { return $null }
    }

    Write-Log 'Generating a local WireGuard key pair...' 'Yellow'
    $priv = (& $WgTool genkey 2>$null) -join ''
    $priv = $priv.Trim()
    if (-not $priv) { Write-Log 'ERROR: Key could not be generated.' 'Red'; return $null }
    $pub  = (($priv | & $WgTool pubkey 2>$null) -join '').Trim()
    if (-not $pub)  { Write-Log 'ERROR: Public key could not be generated.' 'Red'; return $null }

    Write-Log 'Registering with the Cloudflare WARP API (free, no account)...' 'Yellow'
    $tos = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $payload = @{
        key          = $pub
        install_id   = ''
        warp_enabled = $true
        tos          = $tos
        type         = 'Windows'
        locale       = 'en_US'
    } | ConvertTo-Json -Compress

    try {
        $r = Invoke-RestMethod -Method Post -Uri 'https://api.cloudflareclient.com/v0a2158/reg' `
            -ContentType 'application/json' -Body $payload -TimeoutSec 30 `
            -Headers @{ 'User-Agent'='okhttp/3.12.1'; 'CF-Client-Version'='a-6.10-2158' }
    } catch {
        Write-Log ("WARP registration error: {0}" -f $_.Exception.Message) 'Red'
        return $null
    }

    $acc = [ordered]@{
        private_key   = $priv
        public_key    = $pub
        peer_public   = $r.config.peers[0].public_key
        address_v4    = $r.config.interface.addresses.v4
        address_v6    = $r.config.interface.addresses.v6
        account_type  = $r.account.account_type
        device_id     = $r.id
        created       = (Get-Date).ToString('s')
    }
    ($acc | ConvertTo-Json) | Set-Content -Path $AccountFile
    Write-Log ("WARP account ready. Type: {0}, interface: {1}" -f $acc.account_type, $acc.address_v4) 'Green'
    return $acc
}

function Get-WarpAccount {
    if (Test-Path $AccountFile) {
        try { return Get-Content $AccountFile -Raw | ConvertFrom-Json } catch {}
    }
    return (New-WarpAccount)
}

# ------------------------------------------------------------------
#  Build the .conf
# ------------------------------------------------------------------
function New-WarpConf {
    param($Account, [string]$EndpointAddr, [string]$Path)
    $addr = "$($Account.address_v4)/32"
    if ($Account.address_v6) { $addr = "$addr, $($Account.address_v6)/128" }
    $conf = @"
[Interface]
PrivateKey = $($Account.private_key)
Address = $addr
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = $($Account.peer_public)
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $EndpointAddr
PersistentKeepalive = 25
"@
    Set-Content -Path $Path -Value $conf -Encoding ASCII
}

# ------------------------------------------------------------------
#  Open / close the tunnel
# ------------------------------------------------------------------
function Stop-Tunnel {
    param([string]$Name = $TunnelName)
    $svc = "WireGuardTunnel`$$Name"
    $exists = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($exists) {
        Write-Log ("Closing tunnel: {0}" -f $Name) 'Yellow'
        & $WgExe /uninstalltunnelservice $Name 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    } else {
        # call it anyway even if the service is absent (there may be leftovers)
        & $WgExe /uninstalltunnelservice $Name 2>&1 | Out-Null
    }
}

function Start-Tunnel {
    param([string]$ConfPath, [string]$Name = $TunnelName)
    Stop-Tunnel -Name $Name
    Write-Log ("Opening tunnel: {0}" -f $Name) 'Yellow'
    & $WgExe /installtunnelservice $ConfPath 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    $svc = Get-Service -Name "WireGuardTunnel`$$Name" -ErrorAction SilentlyContinue
    return ($svc -and $svc.Status -eq 'Running')
}

# ------------------------------------------------------------------
#  Administrator rights
# ------------------------------------------------------------------
if (-not (Test-Admin) -and -not $NoElevate -and $Action -ne 'Status') {
    Write-Host 'Administrator rights required. Opening the UAC prompt...' -ForegroundColor Yellow
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$($MyInvocation.MyCommand.Path)`"",
                 '-Action',$Action,'-Country',"`"$Country`"",'-Attempts',$Attempts,'-MaxScan',$MaxScan,
                 '-Interface',"`"$Interface`"",'-NoElevate')
    if ($Endpoint)  { $argList += @('-Endpoint', $Endpoint) }
    if ($Profile)   { $argList += @('-Profile', "`"$Profile`"") }
    if ($ProfileDir){ $argList += @('-ProfileDir', "`"$ProfileDir`"") }
    if ($DryRun)    { $argList += '-DryRun' }
    if ($Strict)    { $argList += '-Strict' }
    if ($FetchEndpoints) { $argList += '-FetchEndpoints' }
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList }
    catch { Write-Host 'Elevation cancelled.' -ForegroundColor Red }
    return
}

# ------------------------------------------------------------------
#  Banner
# ------------------------------------------------------------------
Clear-Host
Write-Host ''
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host '     K I T O W G  -  WireGuard / WARP  (FREE)' -ForegroundColor Cyan
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Log ("Action={0} Country={1}" -f $Action, $Country) 'White'

# ------------------------------------------------------------------
#  STATUS
# ------------------------------------------------------------------
if ($Action -eq 'Status') {
    $svc = Get-Service -Name "WireGuardTunnel`$$TunnelName" -ErrorAction SilentlyContinue
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$TunnelName*" }
    Write-Host ("    Tunnel service: {0}" -f $(if ($svc) { $svc.Status } else { 'NONE' }))
    Write-Host ("    Adapter       : {0}" -f $(if ($adapters) { ($adapters.Name -join ', ') } else { '-' }))
    $g = Get-PublicGeo
    if ($g) { Write-Host ("    Exit IP       : {0}  ({1} / {2})" -f $g.IP, $g.Country, $g.CC) -ForegroundColor Green }
    else    { Write-Host '    Exit IP       : unavailable' -ForegroundColor Yellow }
    $acc = if (Test-Path $AccountFile) { Get-Content $AccountFile -Raw | ConvertFrom-Json } else { $null }
    if ($acc) { Write-Host ("    WARP account  : {0} ({1})" -f $acc.account_type, $acc.device_id) }
    Write-Host ''
    return
}

# ------------------------------------------------------------------
#  DOWN
# ------------------------------------------------------------------
if ($Action -eq 'Down') {
    Stop-Tunnel
    Start-Sleep -Seconds 2
    $g = Get-PublicGeo
    Write-Log 'Tunnel closed. Back to the normal connection.' 'Green'
    if ($g) { Write-Log ("Exit IP: {0}  ({1})" -f $g.IP, $g.Country) 'Green' }
    Write-Host ''
    return
}

# ------------------------------------------------------------------
#  RESET
# ------------------------------------------------------------------
if ($Action -eq 'Reset') {
    Stop-Tunnel
    Remove-Item $AccountFile -ErrorAction SilentlyContinue
    Write-Log 'WARP account deleted. A new account will be created on the next Up.' 'Green'
    Write-Host ''
    return
}

# ------------------------------------------------------------------
#  INSTALL
# ------------------------------------------------------------------
if ($Action -eq 'Install') {
    if (Test-WireGuard) { Write-Log 'WireGuard is already installed.' 'Green' }
    else { [void](Install-WireGuard) }
    Write-Host ''
    return
}

# ------------------------------------------------------------------
#  Current state (reference for the country filter)
# ------------------------------------------------------------------
$own = Get-PublicGeo
$ownCC = if ($own) { $own.CC } else { $null }
if ($own) { Write-Log ("Current exit IP: {0} ({1})" -f $own.IP, $own.Country) 'Gray' }

# ------------------------------------------------------------------
#  REGISTER
# ------------------------------------------------------------------
if ($Action -eq 'Register') {
    $acc = New-WarpAccount
    if ($acc) { Write-Log 'WARP account created.' 'Green' } else { Write-Log 'Registration failed.' 'Red' }
    Write-Host ''
    return
}

# ------------------------------------------------------------------
#  Your own profile folder (optional, exact country selection)
# ------------------------------------------------------------------
function Get-ProfilesByCountry {
    param([string]$Dir, [string]$Filter)
    if (-not $Dir -or -not (Test-Path $Dir)) { return @() }
    $files = Get-ChildItem -Path $Dir -Filter *.conf -File
    $out = @()
    foreach ($f in $files) {
        # The country code is taken from the first 2 characters of the filename: DE_frankfurt.conf
        $cc = ($f.BaseName -split '[_\-\.]')[0].ToUpper()
        $out += [pscustomobject]@{ File=$f.FullName; CC=$cc }
    }
    if ($Filter -and $Filter -ne 'ALL') {
        if ($Filter -eq 'Random') { return @($out | Where-Object { $_.CC -ne $ownCC -and $_.CC -ne 'TR' }) }
        $codes = @($Filter.Split(',') | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
        return @($out | Where-Object { $codes -contains $_.CC })
    }
    return $out
}

function Connect-Profile {
    param([string]$Path, [string]$Label)
    Write-Log ("Using profile: {0}" -f $Path) 'Yellow'
    # Use your own config as-is; copy it to change the tunnel name
    $target = Join-Path $ConfDir "$TunnelName.conf"
    New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null
    Copy-Item $Path $target -Force
    if (-not (Start-Tunnel -ConfPath $target)) {
        Write-Log 'Tunnel could not be started.' 'Red'
        return $null
    }
    $g = Test-Internet
    return $g
}

# ------------------------------------------------------------------
#  UP  /  SCAN
# ------------------------------------------------------------------
$confPath = Join-Path $ConfDir "$TunnelName.conf"
New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null

# 1) If a user profile was provided
if ($Profile) {
    $g = Connect-Profile -Path $Profile -Label 'profile'
    if ($g) { Write-Log ("Connected: {0} ({1})" -f $g.IP, $g.Country) 'Green' } else { Write-Log 'Could not establish a connection.' 'Red' }
    Write-Host ''
    return
}
if ($ProfileDir) {
    $p = Get-ProfilesByCountry -Dir $ProfileDir -Filter $Country | Get-Random
    if ($p) {
        $g = Connect-Profile -Path $p.File
        if ($g) { Write-Log ("Connected: {0} ({1}) - {2}" -f $g.IP, $g.Country, $p.CC) 'Green' }
    } else {
        Write-Log 'No suitable .conf found in the profile folder.' 'Red'
    }
    Write-Host ''
    return
}

# 2) WARP account
$acc = Get-WarpAccount
if (-not $acc) { Write-Log 'Could not obtain a WARP account, operation stopped.' 'Red'; Write-Host ''; return }

# 3) Endpoint selection
$candidates = @()
if ($Endpoint) { $candidates = @($Endpoint) }
else {
    $all = Get-EndpointCandidates -Fetch:$FetchEndpoints
    $cache = Get-Cache

    # Cache records matching the country filter
    $wantAll = ($Country.Trim().ToUpper() -eq 'ALL')
    $cachedOk = @()
    if ($cache.Count -gt 0) {
        switch ($Country.Trim().ToUpper()) {
            'ALL'    { $cachedOk = @($cache) }
            'RANDOM' { $cachedOk = @($cache | Where-Object { $_.cc -and $_.cc -ne $ownCC -and $_.cc -ne 'TR' }) }
            default  {
                $codes = @($Country.Split(',') | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
                $cachedOk = @($cache | Where-Object { $codes -contains $_.cc })
            }
        }
    }

    if ($cachedOk.Count -gt 0) {
        $candidates = @($cachedOk | Sort-Object { Get-Random } | ForEach-Object { $_.endpoint })
        Write-Log ("Found {0} suitable endpoints in the cache." -f $candidates.Count) 'Gray'
    }
    # If the cache is empty/unsuitable, pick randomly from all candidates
    if ($candidates.Count -eq 0) {
        $candidates = @($all | Sort-Object { Get-Random })
    }
}

$maxTry = if ($Action -eq 'Scan') { $MaxScan } else { $Attempts }
$maxTry = [Math]::Max(1, $maxTry)

Write-Log ("{0} endpoints will be tried (filter: {1})..." -f $maxTry, $Country) 'Yellow'

$chosen = $null
$chosenGeo = $null
$tried = 0
$lastWorking = $null
$lastWorkingGeo = $null

foreach ($ep in $candidates) {
    if ($tried -ge $maxTry) { break }
    $tried++
    Write-Log ("[{0}/{1}] Trying: {2}" -f $tried, $maxTry, $ep) 'Gray'

    if ($DryRun) {
        Write-Log 'DryRun: tunnel not opened.' 'Yellow'
        continue
    }

    New-WarpConf -Account $acc -EndpointAddr $ep -Path $confPath
    $up = Start-Tunnel -ConfPath $confPath
    if (-not $up) { Write-Log '  the tunnel service did not start.' 'DarkGray'; continue }

    $geo = Test-Internet -Retries 2 -Sleep 3
    if (-not $geo) {
        Write-Log '  connection could not be verified, rolling back.' 'DarkGray'
        Stop-Tunnel
        continue
    }

    Write-Log ("  exit: {0} ({1}) - {2}" -f $geo.IP, $geo.Country, $geo.CC) 'Gray'
    Add-Cache -Ep $ep -Ip $geo.IP -CC $geo.CC -CountryName $geo.Country -City $geo.City

    if (-not $lastWorking) { $lastWorking = $ep; $lastWorkingGeo = $geo }

    # Filter check
    $match = $false
    switch ($Country.Trim().ToUpper()) {
        'ALL'    { $match = $true }
        'RANDOM' { $match = ($geo.CC -and $geo.CC -ne $ownCC -and $geo.CC -ne 'TR') }
        default  {
            $codes = @($Country.Split(',') | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
            $match = ($codes -contains $geo.CC)
        }
    }

    if ($match) {
        $chosen = $ep; $chosenGeo = $geo
        Write-Log ("  COUNTRY MATCHED: {0}" -f $geo.Country) 'Green'
        break
    } else {
        Write-Log ("  country not suitable ({0}), next endpoint..." -f $geo.CC) 'DarkGray'
        if (-not $Strict) { Stop-Tunnel }
    }
    if ($Action -eq 'Scan') { Stop-Tunnel }
}

# ------------------------------------------------------------------
#  Result
# ------------------------------------------------------------------
Write-Host ''
if ($chosen) {
    Write-Host '  ---------------- RESULT ----------------' -ForegroundColor Cyan
    Write-Host ("    BEFORE: {0}" -f $(if ($own) { "$($own.IP) ($($own.Country))" } else { '-' })) -ForegroundColor White
    Write-Host ("    AFTER : {0}  ({1} / {2})" -f $chosenGeo.IP, $chosenGeo.Country, $chosenGeo.CC) -ForegroundColor Green
    Write-Host ("    Endpoint: {0}" -f $chosen) -ForegroundColor White
    Write-Host '  --------------------------------------' -ForegroundColor Cyan
    Write-Log 'Tunnel active (KitoWG). To close: KitoWG.ps1 -Action Down' 'Green'
}
elseif ($lastWorking) {
    if ($Strict) {
        Write-Log ("Country filter did not match. Last working endpoint: {0} (Strict: tunnel closed)." -f $lastWorking) 'Yellow'
    } else {
        Write-Log ("Country did not fully match; reopening the last working endpoint: {0}" -f $lastWorking) 'Yellow'
        New-WarpConf -Account $acc -EndpointAddr $lastWorking -Path $confPath
        $reUp = Start-Tunnel -ConfPath $confPath
        $reGeo = $null
        if ($reUp) { $reGeo = Test-Internet -Retries 3 -Sleep 3 }
        if ($reGeo) {
            Write-Host '  ---------------- RESULT ----------------' -ForegroundColor Cyan
            Write-Host ("    BEFORE: {0}" -f $(if ($own) { "$($own.IP) ($($own.Country))" } else { '-' })) -ForegroundColor White
            Write-Host ("    AFTER : {0}  ({1} / {2})" -f $reGeo.IP, $reGeo.Country, $reGeo.CC) -ForegroundColor Yellow
            Write-Host ("    Endpoint: {0}" -f $lastWorking) -ForegroundColor White
            Write-Host '  --------------------------------------' -ForegroundColor Cyan
            Write-Log 'Tunnel active (country filter did not fully match). To close: KitoWG.ps1 -Action Down' 'Yellow'
        } else {
            Stop-Tunnel
            Write-Log 'The last working endpoint could not be reopened; tunnel closed.' 'Red'
        }
    }
}
else {
    Write-Log 'Could not connect with any endpoint.' 'Red'
    Stop-Tunnel
}
Write-Host ''
Write-Log ("Log: {0}" -f $LogFile) 'DarkGray'
Write-Host ''
