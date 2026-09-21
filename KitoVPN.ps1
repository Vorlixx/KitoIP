<#
    ============================================================
      KitoVPN  -  Yabanci Ulke / Public IP  (v5 - HIZLI + TAKILMAZ)
    ============================================================
      v5 (bu surum):
        * Tarama artik C# thread havuzu ile yapilir -> ASLA TAKILMAZ,
          cok daha hizli, 100.000+ proxy'ye olceklenir. (KitoCore.ps1)
        * Yerel buyuk liste destegi: proxies.txt (istediginiz kadar satir)
        * Ulke secimi (DE, NL, US, ... / Random / ALL)
        * "Fast" modu: onbellek + en iyi liste uzerinden Saniyeler icinde
          en dusuk ms'li, HTTPS tuneli ACAN proxy'yi uygular.
        * En dusuk gecikme (ms) oncelikli secim.

      Modlar: Foreign (baglan) | Fast (en hizli baglan) | Hunt (avi)
              List | Status | Clear
      Ulke  : Random | ALL | DE | DE,NL,US
    ============================================================
#>

[CmdletBinding()]
param(
    [ValidateSet('Foreign','Fast','Hunt','List','Status','Clear')]
    [string]$Mode         = 'Foreign',

    [string]$Country      = 'Random',   # Random | ALL | DE | DE,NL,US
    [int]   $TcpTimeoutMs = 900,        # TCP on filtre zaman asimi
    [int]   $TcpWorkers   = 768,        # TCP es zamanli is parcacigi
    [int]   $MaxScanTcp   = 0,          # TCP taranacak maks aday (0 = HEPSI)
    [int]   $MaxTest      = 3000,       # HTTP test edilecek maks proxy (0 = hepsi)
    [int]   $TimeoutSec   = 4,          # HTTP zaman asimi (sn)
    [int]   $HttpWorkers  = 256,        # HTTP es zamanli is parcacigi
    [int]   $MaxLatencyMs = 900,        # Bu ms ustundeki proxy'ler elenir
    [int]   $TopN         = 60,         # Hunt: kaydedilecek en iyi proxy sayisi
    [switch]$SpeedTest,                 # Indirme hizi (KB/s) de olculsun
    [switch]$Fresh,                     # Onbellegi yok say, taze havuz tara
    [string]$ListFile,
    [string]$BestFile,
    [switch]$DryRun,
    [switch]$NoCache,
    [switch]$NoElevate
)

$ErrorActionPreference = 'SilentlyContinue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
. (Join-Path $ScriptDir 'KitoCore.ps1')

$LogFile    = Join-Path $ScriptDir 'kitoip.log'
$StateFile  = Join-Path $ScriptDir 'proxy_state.json'
$CacheFile  = Join-Path $ScriptDir 'proxies_ok.json'
$LocalFile  = Join-Path $ScriptDir 'proxies.txt'
if (-not $BestFile) { $BestFile = Join-Path $ScriptDir 'proxies_best.txt' }
$RegPath    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

# ==================================================================
#  Yardimcilar
# ==================================================================
function Update-WinINet {
    if (-not ('WinINetNative' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WinINetNative {
    [DllImport("wininet.dll", SetLastError=true)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
"@ -ErrorAction SilentlyContinue
    }
    [WinINetNative]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
    [WinINetNative]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
}

function Get-CachedProxies {
    if ($NoCache -or $Fresh) { return @() }
    if (-not (Test-Path $CacheFile)) { return @() }
    try { $j = Get-Content $CacheFile -Raw | ConvertFrom-Json } catch { return @() }
    if (-not $j) { return @() }
    return @($j |
        Sort-Object { if ($_.Latency) { [int]$_.Latency } else { 9999 } } |
        ForEach-Object { $_.Proxy } | Where-Object { $_ })
}

function Save-CachedProxy {
    param($Entry)
    $list = @()
    if (Test-Path $CacheFile) {
        try { $parsed = Get-Content $CacheFile -Raw | ConvertFrom-Json } catch { $parsed = $null }
        if ($parsed) { $list = @($parsed) }
    }
    $list = @($list | Where-Object { $_.Proxy -ne $Entry.Proxy })
    $list = @([pscustomobject]@{
        Proxy=$Entry.Proxy; IP=$Entry.IP; CC=$Entry.CC; Country=$Entry.Country; City=$Entry.City
        Latency=[int]$Entry.Latency; KBps=[int]$Entry.KBps; Https=[bool]$Entry.Https
        LastUsed=(Get-Date).ToString('s')
    }) + $list
    if ($list.Count -gt 400) { $list = $list[0..399] }
    $list | ConvertTo-Json -Depth 4 | Set-Content -Path $CacheFile -ErrorAction SilentlyContinue
}

function Get-ProxySnapshot { Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue }
function Restore-ProxySnapshot {
    param($Snap)
    if ($Snap) {
        Set-ItemProperty -Path $RegPath -Name ProxyEnable -Value $Snap.ProxyEnable -Type DWord
        if ($Snap.ProxyServer) { Set-ItemProperty -Path $RegPath -Name ProxyServer -Value $Snap.ProxyServer -Type String }
        else { Remove-ItemProperty -Path $RegPath -Name ProxyServer -ErrorAction SilentlyContinue }
        if ($Snap.PSObject.Properties.Name -contains 'ProxyOverride') {
            Set-ItemProperty -Path $RegPath -Name ProxyOverride -Value $Snap.ProxyOverride -Type String
        }
    } else {
        Set-ItemProperty -Path $RegPath -Name ProxyEnable -Value 0 -Type DWord
        Remove-ItemProperty -Path $RegPath -Name ProxyServer -ErrorAction SilentlyContinue
    }
    Update-WinINet
    netsh winhttp reset proxy | Out-Null
}

function Test-AppliedProxy {
    param([string]$Proxy)
    foreach ($h in @('https://www.gstatic.com/generate_204','https://ipwho.is/')) {
        try {
            $req = [System.Net.HttpWebRequest]([System.Net.WebRequest]::Create($h))
            $req.Proxy = New-Object System.Net.WebProxy("http://$Proxy", $true)
            $req.Timeout = 6000; $req.ReadWriteTimeout = 6000; $req.UserAgent = 'Mozilla/5.0'
            $resp = $req.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close()
            if ($code -ge 200 -and $code -lt 400) { return $true }
        } catch {}
    }
    return $false
}

# ------------------------------------------------------------------
#  Uzak kaynaklardan aday topla
# ------------------------------------------------------------------
function Get-RemoteCandidates {
    param([string]$CountryFilter)

    $found = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $textSources = @(
        'https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt',
        'https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt',
        'https://raw.githubusercontent.com/clarketm/proxy-list/master/proxy-list-raw.txt',
        'https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/protocols/http/data.txt',
        'https://raw.githubusercontent.com/mmpx12/proxy-list/master/http.txt',
        'https://raw.githubusercontent.com/zloi-user/hideip.me/main/http.txt',
        'https://raw.githubusercontent.com/zloi-user/hideip.me/main/https.txt',
        'https://raw.githubusercontent.com/roosterkid/openproxylist/main/HTTPS_RAW.txt',
        'https://raw.githubusercontent.com/ALIILAPRO/Proxy/main/http.txt',
        'https://api.openproxylist.xyz/http.txt',
        'https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&protocol=http&proxy_format=ipport&format=text&timeout=5000'
    )
    if ($CountryFilter -and $CountryFilter -ne 'Random' -and $CountryFilter -ne 'ALL') {
        $cc = $CountryFilter.Split(',')[0].Trim().ToLower()
        $textSources += "https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&protocol=http&country=$cc&proxy_format=ipport&format=text&timeout=5000"
    }

    $fetched = New-Object 'System.Collections.Concurrent.ConcurrentBag[object]'
    $pool = [runspacefactory]::CreateRunspacePool(1, 10); $pool.Open()
    $fbody = {
        param($url, $bag)
        try {
            $req = [System.Net.HttpWebRequest]([System.Net.WebRequest]::Create($url))
            $req.Timeout = 12000; $req.ReadWriteTimeout = 12000; $req.UserAgent = 'Mozilla/5.0'
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $cc = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
            $bag.Add([pscustomobject]@{ Url = $url; Content = $cc })
        } catch { $bag.Add([pscustomobject]@{ Url = $url; Content = $null }) }
    }
    $fjobs = @()
    foreach ($url in $textSources) {
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript($fbody.ToString()).AddArgument($url).AddArgument($fetched)
        $fjobs += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    }
    foreach ($j in $fjobs) { try { [void]$j.PS.EndInvoke($j.Handle) } catch {}; $j.PS.Dispose() }
    $pool.Close(); $pool.Dispose()
    foreach ($r in $fetched) {
        if (-not $r.Content) { continue }
        $mm = [regex]::Matches($r.Content, '\b\d{1,3}(?:\.\d{1,3}){3}:\d{2,5}\b')
        foreach ($m in $mm) { [void]$found.Add($m.Value) }
    }

    # geonode API (sayfali)
    foreach ($pg in 1..3) {
        $g = "https://proxylist.geonode.com/api/proxy-list?limit=500&page=$pg&sort_by=lastChecked&sort_type=desc&protocols=http%2Chttps"
        try {
            $j = Invoke-RestMethod -Uri $g -TimeoutSec 20 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
            foreach ($d in $j.data) { if ($d.ip -and $d.port) { [void]$found.Add("$($d.ip):$($d.port)") } }
        } catch {}
    }
    if ($CountryFilter -and $CountryFilter -ne 'Random' -and $CountryFilter -ne 'ALL') {
        foreach ($cc in $CountryFilter.Split(',')) {
            $code = $cc.Trim().ToUpper(); if (-not $code) { continue }
            $g = "https://proxylist.geonode.com/api/proxy-list?limit=300&page=1&sort_by=lastChecked&sort_type=desc&country=$code&protocols=http%2Chttps"
            try {
                $j = Invoke-RestMethod -Uri $g -TimeoutSec 20 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
                foreach ($d in $j.data) { if ($d.ip -and $d.port) { [void]$found.Add("$($d.ip):$($d.port)") } }
            } catch {}
        }
    }
    return @($found)
}

# ------------------------------------------------------------------
#  Tum aday havuzu (yerel liste + onbellek + en iyi + uzak)
# ------------------------------------------------------------------
function Get-AllCandidates {
    param([string]$CountryFilter, [switch]$IncludeRemote)

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $localCount = 0; $cacheCount = 0

    # 1) Kullanici listesi: proxies.txt (buyuk liste, 100k+)
    foreach ($p in (Read-ProxyList $LocalFile)) { [void]$set.Add($p); $localCount++ }
    if ($ListFile -and (Test-Path $ListFile)) {
        foreach ($p in (Read-ProxyList $ListFile)) { [void]$set.Add($p); $localCount++ }
    }

    # 2) Onbellek + en iyi liste (hizli baslangic icin)
    foreach ($p in (Get-CachedProxies)) { [void]$set.Add($p); $cacheCount++ }
    if (Test-Path $BestFile) {
        foreach ($p in (Read-ProxyList $BestFile)) { [void]$set.Add($p) }
    }

    # 3) Uzak kaynaklar
    if ($IncludeRemote) {
        $rem = Get-RemoteCandidates -CountryFilter $CountryFilter
        foreach ($p in $rem) { [void]$set.Add($p) }
        Write-KLog ("  Uzak kaynaklardan {0} aday." -f @($rem).Count) 'DarkGray' $LogFile
    }

    Write-KLog ("  Havuz: yerel {0} + onbellek {1} -> toplam {2} benzersiz aday." -f $localCount, $cacheCount, $set.Count) 'DarkGray' $LogFile
    return @($set)
}

# ------------------------------------------------------------------
#  Secilen proxy'yi sisteme uygula (dogrulamali + retry'li)
# ------------------------------------------------------------------
function Apply-Proxy {
    param($Cand, [string]$BeforeIP)
    $snap = Get-ProxySnapshot
    $proxyValue = "http=$($Cand.Proxy);https=$($Cand.Proxy)"
    Set-ItemProperty -Path $RegPath -Name ProxyEnable  -Value 1 -Type DWord
    Set-ItemProperty -Path $RegPath -Name ProxyServer  -Value $proxyValue -Type String
    Set-ItemProperty -Path $RegPath -Name ProxyOverride -Value '<local>' -Type String
    Update-WinINet
    netsh winhttp set proxy "proxy-server=$($Cand.Proxy)" "<local>" | Out-Null
    Start-Sleep -Milliseconds 800

    $after = $null
    for ($i = 0; $i -lt 3 -and -not $after; $i++) {
        $after = Get-PublicGeo
        if (-not $after) { Start-Sleep -Milliseconds 1200 }
    }
    $httpsOk = Test-AppliedProxy -Proxy $Cand.Proxy
    $changed = $false
    if ($after) {
        if ($after.IP -eq $Cand.IP) { $changed = $true }
        elseif ($BeforeIP -and $after.IP -ne $BeforeIP) { $changed = $true }
    }
    if ($changed -and $httpsOk) {
        return [pscustomobject]@{ Ok = $true; Geo = $after; Snap = $snap }
    }
    Restore-ProxySnapshot $snap
    return [pscustomobject]@{ Ok = $false; Geo = $after; Snap = $snap }
}

# ==================================================================
#  Yonetici yetkisi GEREKMEZ (proxy HKCU'ya yazilir). Yine de -NoElevate
#  verilmediyse ve yoneticiysek sorun yok; yonetici degilsek de calisir.
# ==================================================================

Clear-Host
Write-Host ''
Write-Host '  ============================================' -ForegroundColor Magenta
Write-Host '       K I T O V P N   -   Public IP / Ulke'  -ForegroundColor Magenta
Write-Host '  ============================================' -ForegroundColor Magenta
Write-KLog ("Mod={0} Ulke={1} MaxLatencyMs={2} TcpWorkers={3}" -f $Mode, $Country, $MaxLatencyMs, $TcpWorkers) 'White' $LogFile

# ------------------------------------------------------------------
#  STATUS / CLEAR
# ------------------------------------------------------------------
if ($Mode -eq 'Status') {
    $cur = Get-ItemProperty -Path $RegPath
    $pub = Get-PublicGeo
    Write-Host ("    Sistem proxy : {0}" -f $(if ($cur.ProxyEnable -eq 1) { $cur.ProxyServer } else { 'KAPALI' }))
    if ($pub) { Write-Host ("    Public IP    : {0}  ({1} / {2})" -f $pub.IP, $pub.Country, $pub.CC) -ForegroundColor Green }
    Write-Host ''
    return
}

if ($Mode -eq 'Clear') {
    Write-KLog 'Sistem proxy ayari kaldiriliyor...' 'Yellow' $LogFile
    Set-ItemProperty -Path $RegPath -Name ProxyEnable -Value 0 -Type DWord
    Remove-ItemProperty -Path $RegPath -Name ProxyServer -ErrorAction SilentlyContinue
    netsh winhttp reset proxy | Out-Null
    Update-WinINet
    Remove-Item $StateFile -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $pub = Get-PublicGeo
    Write-KLog 'Proxy kaldirildi. Normal baglantiya donuldu.' 'Green' $LogFile
    if ($pub) { Write-KLog ("Public IP: {0}  ({1})" -f $pub.IP, $pub.Country) 'Green' $LogFile }
    Write-Host ''
    return
}

# ------------------------------------------------------------------
#  ONCE (mevcut durum)
# ------------------------------------------------------------------
$before = Get-PublicGeo
$beforeStr = if ($before) { "$($before.IP) ($($before.Country))" } else { 'bilinmiyor' }
$ownCC = if ($before) { $before.CC } else { $null }
$beforeIP = if ($before) { $before.IP } else { $null }
Write-KLog ("Mevcut public IP: {0}" -f $beforeStr) 'Gray' $LogFile

# ------------------------------------------------------------------
#  Aday havuzu
# ------------------------------------------------------------------
Write-KLog 'Aday havuzu hazirlaniyor...' 'Yellow' $LogFile

$includeRemote = ($Mode -ne 'Fast')
$pool = @(Get-AllCandidates -CountryFilter $Country -IncludeRemote:$includeRemote)

if ($pool.Count -eq 0) {
    Write-KLog 'HATA: Hic proxy adayi bulunamadi. proxies.txt dosyasina ip:port ekleyin.' 'Red' $LogFile
    return
}

# Oncelik: onbellek + en iyi -> once test edilir. Taze olanlar karisik.
$priority = @(Get-CachedProxies)
if (Test-Path $BestFile) { $priority += @(Read-ProxyList $BestFile) }
$priority = @($priority | Select-Object -Unique)
$freshPool = @($pool | Where-Object { $priority -notcontains $_ })

$scanLimit = $MaxScanTcp
if ($Mode -eq 'Fast') {
    # HIZLI mod: uzak kaynak YOK. Onbellek + en iyi once, sonra yerel havuzdan
    # TUM dosyaya yayilmis (stride'li) bir ornek. Amac: saniyeler icinde baglanmak.
    $ordered = @($priority + $pool | Select-Object -Unique)
    $cap = 400
    if ($ordered.Count -gt $cap) {
        $stride = [Math]::Max(1, [int]($ordered.Count / $cap))
        $sample = for ($i = 0; $i -lt $ordered.Count; $i += $stride) { $ordered[$i] }
        $testList = @($sample | Select-Object -First $cap)
    } else {
        $testList = @($ordered)
    }
} elseif ($scanLimit -gt 0) {
    $testList = @($priority + $freshPool | Select-Object -Unique | Select-Object -First $scanLimit)
} else {
    $testList = @($priority + $freshPool | Select-Object -Unique)
}
Write-KLog ("{0} aday TCP on filtresinden gecirilecek (oncelik {1}, taze {2})." -f $testList.Count, $priority.Count, [Math]::Max(0, $testList.Count - $priority.Count)) 'Yellow' $LogFile

# ------------------------------------------------------------------
#  ASAMA 1: TCP on filtre
# ------------------------------------------------------------------
# $global degerleri runspace'e tasinmaz; guvenli yol: parametre ile gonder
[Kito]::Total = $testList.Count
[Kito]::Done  = 0
$tcpAlive = Invoke-KitoStage -Body {
    param($p)
    [Kito]::TcpScan([string[]]$p.eps, [int]$p.tmo, [int]$p.wk)
} -ArgList @([pscustomobject]@{ eps=$testList; tmo=$TcpTimeoutMs; wk=$TcpWorkers }) -Label 'TCP  ' -HardCapSec 300

$tcpAlive = @($tcpAlive | ForEach-Object { $_ })
$tcpEps = @($tcpAlive | Sort-Object Latency | ForEach-Object { $_.Proxy })
if ($tcpEps.Count -eq 0) { $tcpEps = $testList }
Write-KLog ("TCP filtresi: {0}/{1} port acik." -f $tcpEps.Count, $testList.Count) 'DarkGray' $LogFile

# ------------------------------------------------------------------
#  ASAMA 2: HTTP + HTTPS dogrulama (en fazla MaxTest)
# ------------------------------------------------------------------
if ($MaxTest -gt 0) { $httpList = @($tcpEps | Select-Object -First $MaxTest) } else { $httpList = @($tcpEps) }
$verify = ($Mode -ne 'List')   # List'te HTTPS zorunlu degil
Write-KLog ("{0} proxy HTTP/HTTPS testinden gecirilecek (es zamanli {1})..." -f $httpList.Count, $HttpWorkers) 'Yellow' $LogFile

[Kito]::Total = $httpList.Count
[Kito]::Done  = 0
$alive = Invoke-KitoStage -Body {
    param($p)
    [Kito]::HttpCheck([string[]]$p.eps, [int]$p.tmo, [int]$p.wk, [bool]$sp, [bool]$vh)
} -ArgList @([pscustomobject]@{ eps=$httpList; tmo=($TimeoutSec*1000); wk=$HttpWorkers; sp=[bool]$SpeedTest; vh=[bool]$verify }) -Label 'HTTP ' -HardCapSec 300
$alive = @($alive)

$httpsAlive = @($alive | Where-Object { $_.Https })
Write-KLog ("{0} calisan proxy ({1} tanesi HTTPS tuneli acti)." -f $alive.Count, $httpsAlive.Count) 'Gray' $LogFile

if ($alive.Count -eq 0) {
    Write-KLog 'HATA: Test edilen proxy lerden hicbiri calismadi. Tekrar deneyin.' 'Red' $LogFile
    return
}

# ------------------------------------------------------------------
#  ULKE FILTRESI
# ------------------------------------------------------------------
$base = if ($verify -and $httpsAlive.Count -gt 0) { $httpsAlive } else { $alive }
switch ($Country.ToUpper()) {
    'ALL'    { $filtered = @($base) }
    'RANDOM' { $filtered = @($base | Where-Object { $_.CC -and $_.CC -ne $ownCC -and $_.CC -ne 'TR' }) }
    default  {
        $codes = @($Country.Split(',') | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
        $filtered = @($base | Where-Object { $codes -contains $_.CC })
    }
}
if ($filtered.Count -eq 0) {
    Write-KLog ("Istenen ulke filtresine uyan proxy yok; tum uygun proxy'ler degerlendirilecek.") 'Yellow' $LogFile
    $filtered = $base
}

# Kademeli: once HTTPS+hizli, sonra HTTPS, sonra hizli
$t1 = @($filtered | Where-Object { $_.Https -and [int]$_.Latency -le $MaxLatencyMs })
$t2 = @($filtered | Where-Object { $_.Https })
$t3 = @($filtered | Where-Object { [int]$_.Latency -le $MaxLatencyMs })
if ($t1.Count -gt 0)      { $ranked = Sort-ByQuality $t1; Write-KLog ("{0} proxy HTTPS-OK ve hizli (<={1}ms)." -f $t1.Count, $MaxLatencyMs) 'Green' $LogFile }
elseif ($t2.Count -gt 0)  { $ranked = Sort-ByQuality $t2; Write-KLog ("HTTPS-OK {0} proxy (esik ustu de olabilir)." -f $t2.Count) 'Yellow' $LogFile }
elseif ($t3.Count -gt 0)  { $ranked = Sort-ByQuality $t3; Write-KLog ("HTTPS-OK yok; hizli {0} proxy denenecek." -f $t3.Count) 'Yellow' $LogFile }
else                      { $ranked = Sort-ByQuality $filtered; Write-KLog ("{0} aday denenecek." -f $filtered.Count) 'Yellow' $LogFile }

# ------------------------------------------------------------------
#  LIST modu: listele ve cik
# ------------------------------------------------------------------
if ($Mode -eq 'List') {
    Write-Host ''
    Write-Host '  En iyi proxy ler (ms''e gore sirali):' -ForegroundColor Green
    $ranked | Select-Object Proxy, Latency, KBps, Https, CC, Country, City -First 40 |
        Format-Table -AutoSize | Out-String | Write-Host
    return
}

# ------------------------------------------------------------------
#  HUNT modu: en iyi TopN'u kaydet
# ------------------------------------------------------------------
if ($Mode -eq 'Hunt') {
    $best = @($ranked | Select-Object -First $TopN)
    Write-Host ''
    Write-KLog ("EN IYI {0} proxy (HTTPS dogrulanmis, en dusuk ms):" -f $best.Count) 'Green' $LogFile
    $best | Select-Object Proxy, Latency, KBps, Https, CC, Country, City | Format-Table -AutoSize | Out-String | Write-Host
    $best | ForEach-Object { $_.Proxy } | Set-Content -Path $BestFile -ErrorAction SilentlyContinue
    foreach ($b in $best) { Save-CachedProxy $b }
    Write-KLog ("Kaydedildi: {0}" -f $BestFile) 'Green' $LogFile
    Write-Host ''
    return
}

# ------------------------------------------------------------------
#  FOREIGN / FAST modu: uygula
# ------------------------------------------------------------------
if ($DryRun) {
    Write-KLog ("DryRun: secilecek en iyi aday -> {0} [{1} ms] ({2})" -f $ranked[0].Proxy, $ranked[0].Latency, $ranked[0].Country) 'Yellow' $LogFile
    return
}

$attempts = @($ranked | Select-Object -First 8)
$chosen = $null
foreach ($cand in $attempts) {
    Write-Host ''
    $msTxt = if ($cand.KBps) { "{0} ms / {1} KB/s" -f $cand.Latency, $cand.KBps } else { "{0} ms" -f $cand.Latency }
    $tag = if ($cand.Https) { 'HTTPS-OK' } else { 'HTTPS?' }
    Write-KLog ("Denenen: {0}  [{1} {2}]  ({3}/{4} - {5})" -f $cand.Proxy, $msTxt, $tag, $cand.Country, $cand.CC, $cand.City) 'White' $LogFile
    $res = Apply-Proxy -Cand $cand -BeforeIP $beforeIP
    if ($res.Ok) { $chosen = $cand; break }
    Write-KLog ("  Uygulanamadi/dogrulanamadi, siradaki deneniyor..." -f $cand.Proxy) 'Yellow' $LogFile
}

Write-Host ''
Write-Host '  ---------------- SONUC ----------------' -ForegroundColor Magenta
Write-Host ("    ONCE : {0}" -f $beforeStr) -ForegroundColor White
if (-not $chosen) {
    Write-Host '    SONRA: degismedi (uygun proxy uygulanamadi)' -ForegroundColor Yellow
    Write-KLog 'Hicbir proxy dogrulanamadi: sistem eski haline donduruldu.' 'Red' $LogFile
    Write-Host '  --------------------------------------' -ForegroundColor Magenta
    Write-Host ''
    return
}

Write-Host ("    SONRA: {0}  ({1} / {2})" -f $chosen.IP, $chosen.Country, $chosen.CC) -ForegroundColor Green
Write-Host ("    Proxy: {0}   [{1} ms]" -f $chosen.Proxy, $chosen.Latency) -ForegroundColor Green
Write-Host '  --------------------------------------' -ForegroundColor Magenta
Save-CachedProxy $chosen
$state = [ordered]@{
    Timestamp=(Get-Date).ToString('s'); Proxy=$chosen.Proxy; ExitIP=$chosen.IP
    Country=$chosen.Country; CountryCode=$chosen.CC; City=$chosen.City
    LatencyMs=$chosen.Latency; KBps=$chosen.KBps; HttpsOk=$chosen.Https
}
$state | ConvertTo-Json | Set-Content -Path $StateFile -ErrorAction SilentlyContinue
Write-Host ''
Write-KLog 'Bitti. Kapatmak icin menu [6] Proxy Kapat.' 'DarkGray' $LogFile
Write-Host ''
