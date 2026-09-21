<#
    ============================================================
      KitoMenu  -  SINGLE TERMINAL, UNIFIED MENU  (v6)
    ============================================================
      Everything is done FROM THIS WINDOW; there are NO separate
      .bat files. KitoIP.bat only launches this menu.

      Contents:
        * Animated splash screen (logo + typewriter effect + spinner)
        * Foreign IP via proxy   (KitoVPN.ps1 -Mode Foreign)
        * Fastest Connect        (KitoVPN.ps1 -Mode Fast)
        * Proxy Hunt             (KitoVPN.ps1 -Mode Hunt)
        * Proxy List             (KitoVPN.ps1 -Mode List)
        * Country Selection      (Random / ALL / DE,NL,US ...)
        * Proxy Off / Status
        * Bulk import from file for 100,000+ proxies
        * Change LAN IP          (KitoIP.ps1)
        * WireGuard WARP VPN     (KitoWG.ps1)
    ============================================================
#>

[CmdletBinding()]
param(
    [switch]$NoSplash,
    [switch]$NoPause
)

$ErrorActionPreference = 'SilentlyContinue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

$SettingsFile = Join-Path $ScriptDir 'kito_settings.json'
$LocalFile    = Join-Path $ScriptDir 'proxies.txt'
$BestFile     = Join-Path $ScriptDir 'proxies_best.txt'
$CacheFile    = Join-Path $ScriptDir 'proxies_ok.json'
$VpnScript    = Join-Path $ScriptDir 'KitoVPN.ps1'
$IpScript     = Join-Path $ScriptDir 'KitoIP.ps1'
$WgScript     = Join-Path $ScriptDir 'KitoWG.ps1'
$CoreScript   = Join-Path $ScriptDir 'KitoCore.ps1'

# Write-FixedLine (used for single-line screen drawing) is defined here
try { . $CoreScript } catch {}

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { (Get-Host).UI.RawUI.WindowTitle = 'KitoIP  -  Proxy + IP Toolkit' } catch {}

$script:poolCache = $null

# ==================================================================
#  Settings (country selection is remembered)
# ==================================================================
function Get-Settings {
    $d = [pscustomobject]@{ Country = 'Random'; SpeedTest = $false }
    if (Test-Path $SettingsFile) {
        try {
            $j = Get-Content $SettingsFile -Raw | ConvertFrom-Json
            if ($j.Country)   { $d.Country = [string]$j.Country }
            if ($j.PSObject.Properties.Name -contains 'SpeedTest') { $d.SpeedTest = [bool]$j.SpeedTest }
        } catch {}
    }
    return $d
}
function Save-Settings {
    param($S)
    try { $S | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 } catch {}
}

# ==================================================================
#  Animations
# ==================================================================
function Write-Type {
    param([string]$Text, [string]$Color = 'Gray', [int]$DelayMs = 12)
    foreach ($ch in $Text.ToCharArray()) {
        Write-Host $ch -NoNewline -ForegroundColor $Color
        Start-Sleep -Milliseconds $DelayMs
    }
    Write-Host ''
}

function Show-Splash {
    Clear-Host
    try { $w = [Math]::Max(60, [Console]::WindowWidth) } catch { $w = 78 }
    $barW = [Math]::Min(64, $w - 4)

    # ---- top frame (box-drawing characters) ----------------------------
    Write-Host ''
    Write-Host ('   +' + ('=' * $barW) + '+') -ForegroundColor DarkMagenta

    $logo = @(
        '#   #  ###  #####   ###   ###  ####  ',
        '#  #    #     #    #   #   #   #   # ',
        '###     #     #    #   #   #   ####  ',
        '#  #    #     #    #   #   #   #     ',
        '#   #  ###    #     ###   ###  #     '
    )
    $pad = [Math]::Max(0, [int](($barW - 38) / 2))
    foreach ($line in $logo) {
        $row = '   |' + (' ' * $pad) + $line.PadRight($barW - $pad) + '|'
        Write-Host $row -ForegroundColor Magenta
        Start-Sleep -Milliseconds 35
    }

    $sub1 = 'Proxy + IP Toolkit  -  v6'
    $sub2 = 'Hang-free scan engine: C# thread pool'
    Write-Host ('   |' + $sub1.PadLeft([int](($barW + $sub1.Length) / 2)).PadRight($barW) + '|') -ForegroundColor Cyan
    Write-Host ('   |' + $sub2.PadLeft([int](($barW + $sub2.Length) / 2)).PadRight($barW) + '|') -ForegroundColor DarkGray
    Write-Host ('   +' + ('=' * $barW) + '+') -ForegroundColor DarkMagenta
    Write-Host ''

    # ---- SINGLE-LINE preparation animation (never wraps) ---------------
    $spin = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
    $steps = @('detecting system', 'reading cache', 'preparing engine', 'opening menu')
    try {
        Write-Host ''
        $row = [Console]::CursorTop - 1
        $k = 0
        foreach ($st in $steps) {
            for ($j = 0; $j -lt 5; $j++) {
                $text = "   {0}  {1}..." -f $spin[$k % $spin.Count], $st
                Write-FixedLine -Row $row -Text $text -Color Yellow
                $k++
                Start-Sleep -Milliseconds 45
            }
        }
        Write-FixedLine -Row $row -Text '   [OK] Ready.' -Color Green
    } catch {
        Write-Host '   [OK] Ready.' -ForegroundColor Green
    }
    Start-Sleep -Milliseconds 200
}

function Wait-Key {
    param([string]$Msg = '  Press ENTER to continue...')
    if ($NoPause) { return }
    Write-Host ''
    Write-Host $Msg -ForegroundColor DarkGray -NoNewline
    [void][Console]::ReadLine()
}

# ==================================================================
#  Pool info (fast counting for 100,000+ lines)
# ==================================================================
function Get-PoolCount {
    if (-not (Test-Path $LocalFile)) { return 0 }
    try {
        $fi = Get-Item $LocalFile
        if ($script:poolCache -and $script:poolCache.Stamp -eq $fi.LastWriteTime.Ticks) {
            return $script:poolCache.Count
        }
        $n = 0
        $sr = New-Object System.IO.StreamReader($LocalFile)
        while ($null -ne $sr.ReadLine()) { $n++ }
        $sr.Close()
        $script:poolCache = [pscustomobject]@{ Stamp = $fi.LastWriteTime.Ticks; Count = $n }
        return $n
    } catch { return 0 }
}
function Get-LineCount {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        $n = 0
        $sr = New-Object System.IO.StreamReader($Path)
        while ($null -ne $sr.ReadLine()) { $n++ }
        $sr.Close()
        return $n
    } catch { return 0 }
}

# ==================================================================
#  Child script runner (SAME window)
# ==================================================================
function Invoke-KitoChild {
    param([string]$Script, [string[]]$ExtraArgs)
    if (-not (Test-Path $Script)) {
        Write-Host ("  ERROR: {0} not found." -f (Split-Path -Leaf $Script)) -ForegroundColor Red
        return
    }
    $all = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Script) + @($ExtraArgs)
    Write-Host ''
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
    & powershell.exe @all
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
}

# ==================================================================
#  Add proxies (from file, supports 100k)
# ==================================================================
function Read-EndpointsFrom {
    param([string]$Path)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path $Path)) { return $set }
    try {
        $sr = New-Object System.IO.StreamReader($Path)
        $re = [regex]'\b(\d{1,3}(?:\.\d{1,3}){3}:\d{2,5})\b'
        while ($null -ne ($line = $sr.ReadLine())) {
            $m = $re.Match($line)
            if ($m.Success) { [void]$set.Add($m.Groups[1].Value) }
        }
        $sr.Close()
    } catch {}
    return $set
}

function Add-ProxiesFromFile {
    Write-Host ''
    Write-Host '  Add proxy list' -ForegroundColor Cyan
    Write-Host '  Type the file path and press ENTER (or drag and drop it here).' -ForegroundColor DarkGray
    Write-Host '  Accepted formats: ip:port  |  ip:port:user:pass  |  http://ip:port' -ForegroundColor DarkGray
    Write-Host '  Example: C:\proxies\big_list.txt' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Path > ' -ForegroundColor Yellow -NoNewline
    $src = [Console]::ReadLine()
    if (-not $src) { return }
    $src = $src.Trim().Trim('"').Trim("'")
    if (-not (Test-Path $src)) {
        Write-Host ("  ERROR: file not found -> {0}" -f $src) -ForegroundColor Red
        return
    }

    $set = Read-EndpointsFrom $LocalFile
    $before = $set.Count
    $add = Read-EndpointsFrom $src
    foreach ($p in $add) { [void]$set.Add($p) }
    $newCount = $set.Count

    Write-Host ("  Found {0} proxies in the source, {1} new ones added." -f $add.Count, ($newCount - $before)) -ForegroundColor Green
    Write-Host ("  Total unique pool: {0} proxies" -f $newCount) -ForegroundColor Green

    Write-Host '  Also refresh the cache (delete previous test results)? [y/N] ' -ForegroundColor Yellow -NoNewline
    $ans = [Console]::ReadLine()
    if ($ans -and $ans.Trim().ToLower().StartsWith('y')) {
        Remove-Item $CacheFile -ErrorAction SilentlyContinue
        Remove-Item $BestFile -ErrorAction SilentlyContinue
        Write-Host '  Cache cleared.' -ForegroundColor DarkGray
    }

    # Write the big list to disk (StreamWriter -> very fast at 100k)
    try {
        $sw = New-Object System.IO.StreamWriter($LocalFile, $false, (New-Object System.Text.UTF8Encoding($false)))
        foreach ($p in $set) { $sw.WriteLine($p) }
        $sw.Flush(); $sw.Close()
        $script:poolCache = $null
        Write-Host ("  Saved: {0}" -f $LocalFile) -ForegroundColor Green
    } catch {
        Write-Host '  ERROR: could not write.' -ForegroundColor Red
    }
}

# ==================================================================
#  Country menu
# ==================================================================
function Show-CountryMenu {
    while ($true) {
        $s = Get-Settings
        Clear-Host
        Write-Host ''
        Write-Host '  ============================================================' -ForegroundColor Cyan
        Write-Host '      COUNTRY SELECTION' -ForegroundColor Cyan
        Write-Host '  ============================================================' -ForegroundColor Cyan
        Write-Host ("      Current selection: {0}" -f $s.Country) -ForegroundColor Green
        Write-Host ''
        Write-Host '    [1]  Random          (random, outside your own country)'
        Write-Host '    [2]  ALL             (any country)'
        Write-Host '    [3]  DE   Germany'
        Write-Host '    [4]  NL   Netherlands'
        Write-Host '    [5]  US   United States'
        Write-Host '    [6]  GB   United Kingdom'
        Write-Host '    [7]  FR   France'
        Write-Host '    [8]  RU   Russia'
        Write-Host '    [9]  SG   Singapore'
        Write-Host '    [10] DE,NL,US       (multiple)'
        Write-Host '    [0]  Back'
        Write-Host ''
        Write-Host '  PICK a number above, or type the country code(s) you want' -ForegroundColor DarkGray
        Write-Host '  DIRECTLY (e.g. IT  or  IT,ES,PT):' -ForegroundColor DarkGray
        Write-Host '  Selection > ' -ForegroundColor Yellow -NoNewline
        $c = [Console]::ReadLine()
        $t = "$c".Trim()
        switch ($t) {
            '1'  { $s.Country = 'Random'; Save-Settings $s; return }
            '2'  { $s.Country = 'ALL';    Save-Settings $s; return }
            '3'  { $s.Country = 'DE';     Save-Settings $s; return }
            '4'  { $s.Country = 'NL';     Save-Settings $s; return }
            '5'  { $s.Country = 'US';     Save-Settings $s; return }
            '6'  { $s.Country = 'GB';     Save-Settings $s; return }
            '7'  { $s.Country = 'FR';     Save-Settings $s; return }
            '8'  { $s.Country = 'RU';     Save-Settings $s; return }
            '9'  { $s.Country = 'SG';     Save-Settings $s; return }
            '10' { $s.Country = 'DE,NL,US'; Save-Settings $s; return }
            '0'  { return }
            ''   { return }
            default {
                # Not a number -> accept it as directly typed country code(s)
                $clean = ($t.ToUpper() -replace '[^A-Z,]', '')
                if ($clean) { $s.Country = $clean; Save-Settings $s }
                return
            }
        }
    }
}

# ==================================================================
#  LAN IP menu
# ==================================================================
function Show-LanMenu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ============================================================' -ForegroundColor Cyan
        Write-Host '      CHANGE LAN IP  (local adapter IP address)' -ForegroundColor Cyan
        Write-Host '  ============================================================' -ForegroundColor Cyan
        Write-Host '      NOTE: Changing the local IP does NOT change the PUBLIC IP.' -ForegroundColor DarkGray
        Write-Host '           For the public IP, use the proxy option [1]/[2].' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '    [1]  Auto     (smart: renew DHCP, else random static)'
        Write-Host '    [2]  Renew    (renew the DHCP lease only)'
        Write-Host '    [3]  Random   (random static IP from the subnet)'
        Write-Host '    [4]  Static   (provide an IP manually)'
        Write-Host '    [5]  Restore  (switch back to DHCP / automatic)'
        Write-Host '    [0]  Back'
        Write-Host ''
        Write-Host '  Selection > ' -ForegroundColor Yellow -NoNewline
        $c = [Console]::ReadLine()
        switch ("$c".Trim()) {
            '1' { Invoke-KitoChild $IpScript @('-Mode','Auto');    Wait-Key }
            '2' { Invoke-KitoChild $IpScript @('-Mode','Renew');   Wait-Key }
            '3' { Invoke-KitoChild $IpScript @('-Mode','Random');  Wait-Key }
            '4' {
                Write-Host ''
                Write-Host '  Static IP to assign (e.g. 192.168.1.50) > ' -ForegroundColor Yellow -NoNewline
                $ip = [Console]::ReadLine()
                if ($ip) { Invoke-KitoChild $IpScript @('-Mode','Static','-StaticIP',$ip.Trim()); Wait-Key }
            }
            '5' { Invoke-KitoChild $IpScript @('-Mode','Restore'); Wait-Key }
            '0' { return }
        }
    }
}

# ==================================================================
#  WireGuard / WARP menu
# ==================================================================
function Show-WgMenu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ============================================================' -ForegroundColor Cyan
        Write-Host '      WIREGUARD + CLOUDFLARE WARP  (free, no account)' -ForegroundColor Cyan
        Write-Host '  ============================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '    [1]  Connect (Up)        - open the tunnel, pick a country'
        Write-Host '    [2]  Disconnect (Down)   - close the tunnel'
        Write-Host '    [3]  Status              - active tunnel + exit IP'
        Write-Host '    [4]  Install             - install the WireGuard client'
        Write-Host '    [5]  Register            - create a free WARP account'
        Write-Host '    [6]  Endpoint Test (Scan)'
        Write-Host '    [7]  Reset               - delete the WARP account, start over'
        Write-Host '    [0]  Back'
        Write-Host ''
        Write-Host '  NOTE: Up/Install/Register require ADMINISTRATOR rights.' -ForegroundColor DarkGray
        Write-Host '  Selection > ' -ForegroundColor Yellow -NoNewline
        $c = [Console]::ReadLine()
        $s = Get-Settings
        switch ("$c".Trim()) {
            '1' { Invoke-KitoChild $WgScript @('-Action','Up','-Country',$s.Country); Wait-Key }
            '2' { Invoke-KitoChild $WgScript @('-Action','Down');    Wait-Key }
            '3' { Invoke-KitoChild $WgScript @('-Action','Status');  Wait-Key }
            '4' { Invoke-KitoChild $WgScript @('-Action','Install'); Wait-Key }
            '5' { Invoke-KitoChild $WgScript @('-Action','Register'); Wait-Key }
            '6' { Invoke-KitoChild $WgScript @('-Action','Scan');    Wait-Key }
            '7' { Invoke-KitoChild $WgScript @('-Action','Reset');   Wait-Key }
            '0' { return }
        }
    }
}

# ==================================================================
#  Main menu
# ==================================================================
function Show-MainMenu {
    while ($true) {
        $s = Get-Settings
        $pool = Get-PoolCount
        $best = Get-LineCount $BestFile
        $cache = Get-LineCount $CacheFile
        $stateTxt = 'none'
        $stFile = Join-Path $ScriptDir 'proxy_state.json'
        if (Test-Path $stFile) {
            try {
                $j = Get-Content $stFile -Raw | ConvertFrom-Json
                if ($j.Proxy) { $stateTxt = ("{0}  {1}/{2}  {3} ms" -f $j.Proxy, $j.CountryCode, $j.Country, $j.LatencyMs) }
            } catch {}
        }

        Clear-Host
        Write-Host ''
        Write-Host '  ============================================================' -ForegroundColor Magenta
        Write-Host '      K I T O I P     Proxy + IP Toolkit' -ForegroundColor Magenta
        Write-Host '  ============================================================' -ForegroundColor Magenta
        Write-Host ("      Country     : {0}" -f $s.Country) -ForegroundColor Cyan
        Write-Host ("      Pool        : {0} proxies (proxies.txt)" -f $pool) -ForegroundColor Cyan
        Write-Host ("      Best        : {0}   |   Cache: {1}" -f $best, $cache) -ForegroundColor DarkCyan
        Write-Host ("      Active proxy: {0}" -f $stateTxt) -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host '    [1]  Connect to a Foreign IP   (country filter + lowest ms)' -ForegroundColor White
        Write-Host '    [2]  Fast Connect              (from cache, in seconds)' -ForegroundColor Green
        Write-Host '    [3]  Proxy Hunt                (rebuild the best list)' -ForegroundColor White
        Write-Host '    [4]  Proxy List                (show the fastest candidates)' -ForegroundColor White
        Write-Host '    [5]  Select Country            (now: ' -NoNewline -ForegroundColor White
        Write-Host ($s.Country + ')') -NoNewline -ForegroundColor Yellow
        Write-Host ''
        Write-Host '    [6]  Proxy Off                 (back to the normal connection)' -ForegroundColor White
        Write-Host '    [7]  Status' -ForegroundColor White
        Write-Host ''
        Write-Host '    [8]  Change LAN IP' -ForegroundColor White
        Write-Host '    [9]  WireGuard WARP VPN' -ForegroundColor White
        Write-Host '    [P]  Manage Proxy List         (bulk import / clear cache)' -ForegroundColor White
        Write-Host '    [0]  Exit' -ForegroundColor White
        Write-Host ''
        Write-Host '  Selection > ' -ForegroundColor Yellow -NoNewline
        $c = [Console]::ReadLine()
        $sel = "$c".Trim().ToLower()

        $countryArgs = @('-Country', $s.Country)
        switch ($sel) {
            '1' { Invoke-KitoChild $VpnScript (@('-Mode','Foreign') + $countryArgs); Wait-Key }
            '2' { Invoke-KitoChild $VpnScript (@('-Mode','Fast') + $countryArgs);    Wait-Key }
            '3' { Invoke-KitoChild $VpnScript @('-Mode','Hunt');                     Wait-Key }
            '4' { Invoke-KitoChild $VpnScript (@('-Mode','List') + $countryArgs);    Wait-Key }
            '5' { Show-CountryMenu }
            '6' { Invoke-KitoChild $VpnScript @('-Mode','Clear');                    Wait-Key }
            '7' { Invoke-KitoChild $VpnScript @('-Mode','Status');                   Wait-Key }
            '8' { Show-LanMenu }
            '9' { Show-WgMenu }
            'p' { Add-ProxiesFromFile; Wait-Key }
            '0' { return }
            ''  { }
        }
    }
}

# ==================================================================
#  Start
# ==================================================================
if (-not $NoSplash) { Show-Splash }
Show-MainMenu

Clear-Host
Write-Host ''
Write-Host '  KitoIP closed.' -ForegroundColor Magenta
Write-Host ''
