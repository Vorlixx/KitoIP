<#
    ============================================================
      KitoWG  -  WireGuard + Cloudflare WARP (TAMAMEN UCRETSIZ)
    ============================================================
      Cloudflare WARP, WireGuard tabanli ve tamamen ucretsiz,
      sinirsiz, HESAP GEREKTIRMEYEN bir VPN'dir. Bu modul:

        1) WireGuard istemcisini kurar (gerekirse).
        2) Senin icin otomatik bir WARP hesabi olusturur
           (yerel anahtar uretimi + WARP kayit API'si).
        3) WARP endpoint'leri arasindan RASTGELE bir ulke secer
           ve WireGuard tunelini acar.
        4) Cikis IP'sini ve ulkesini dogrular. Basarisiz olursa
           otomatik geri alir (internetin kesilmez).

      Eylemler (-Action):
        Install   : WireGuard'i kur / dogrula
        Register  : Ucretsiz WARP hesabi olustur
        Up        : Tuneli ac (varsayilan) - ulke secip baglan
        Scan      : Endpoint'leri test et, ulke eslesmesini ogren
        Down      : Tuneli kapat, normal baglantiya don
        Status    : Aktif tunel + cikis IP/ulke
        Reset     : WARP hesabini sil ve bastan basla

      Ulke:  -Country Random  (kendi ulken disinda rastgele)
             -Country ALL     (herhangi)
             -Country DE,NL   (belirli ulkeler)

      Ornek:
        KitoWG.ps1 -Action Up -Country Random
        KitoWG.ps1 -Action Up -Country DE,NL -Attempts 8
        KitoWG.ps1 -Action Scan -MaxScan 15
        KitoWG.ps1 -Action Down

      NOT: WARP cikis ulkesi, baglandigin endpoint'e ve bulundugun
      konuma gore belirlenir; ulke secimi "en iyi caba" esaslidir.
      Endpoint -> ulke eslesmesi kullandikca ogrenilir ve onbellege
      alinir. Kesin ulke garantisi icin kendi .conf dosyalarini
      (ProtonVPN Free / Windscribe Free) wgconf klasoruna koyabilirsin.
    ============================================================
#>

[CmdletBinding()]
param(
    [ValidateSet('Install','Register','Up','Scan','Down','Status','Reset')]
    [string]$Action = 'Up',

    [string]$Country    = 'Random',        # Random | ALL | DE,NL,US
    [int]   $Attempts   = 5,               # Ulke tutmazsa denenecek endpoint sayisi
    [int]   $MaxScan    = 12,              # Scan modunda test edilecek endpoint
    [string]$Interface  = 'KitoWG',        # Tunel (adaptor) adi
    [string]$Endpoint,                     # Belirli endpoint: ip:port
    [string]$Profile,                      # Kendi .conf dosyan
    [string]$ProfileDir,                   # Ulke-bazli .conf klasoru
    [switch]$FetchEndpoints,                # Calisan endpoint listesini indir
    [switch]$Strict,                       # Ulke tutmazsa bastan deneme yapma
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
#  Loglama
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
#  Cikis IP / ulke sorgusu (tunel uzerinden gider)
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
#  Onbellek (endpoint -> ulke) yonetimi
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
#  Aday endpoint listesi
# ------------------------------------------------------------------
function Get-EndpointCandidates {
    param([switch]$Fetch)

    $list = New-Object 'System.Collections.Generic.List[string]'

    # Bilinen WARP araliklarindan derlenmis, calistigi raporlanan endpoint'ler
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
            } catch { Write-Log ("Endpoint kaynagi alinamadi: {0}" -f $u) 'DarkGray' }
        }
    }

    return @($list | Select-Object -Unique)
}

# ------------------------------------------------------------------
#  WireGuard varligi / kurulumu
# ------------------------------------------------------------------
function Test-WireGuard {
    (Test-Path $WgExe) -and (Test-Path $WgTool)
}

function Install-WireGuard {
    Write-Log 'WireGuard istemcisi kuruluyor (winget)...' 'Yellow'
    $ok = $false
    try {
        & winget install --id WireGuard.WireGuard -e `
            --accept-package-agreements --accept-source-agreements --silent 2>&1 |
            ForEach-Object { Write-Host $_ }
        $ok = Test-WireGuard
    } catch { }

    if (-not $ok) {
        Write-Log 'winget basarisiz, resmi MSI indiriliyor...' 'Yellow'
        $msi = Join-Path $env:TEMP 'wireguard-installer.exe'
        try {
            Invoke-WebRequest -Uri 'https://download.wireguard.com/windows-client/wireguard-installer.exe' `
                -OutFile $msi -UseBasicParsing -TimeoutSec 180
            Start-Process -FilePath $msi -ArgumentList '/quiet' -Wait
            $ok = Test-WireGuard
        } catch { Write-Log ("Indirme/kurulum hatasi: {0}" -f $_.Exception.Message) 'Red' }
    }

    if ($ok) { Write-Log 'WireGuard kuruldu.' 'Green' }
    else     { Write-Log 'HATA: WireGuard kurulamadi. Elle kurun: https://www.wireguard.com/install/' 'Red' }
    return $ok
}

# ------------------------------------------------------------------
#  WARP hesabi
# ------------------------------------------------------------------
function New-WarpAccount {
    if (-not (Test-WireGuard)) {
        if (-not (Install-WireGuard)) { return $null }
    }

    Write-Log 'Yerel WireGuard anahtar cifti uretiliyor...' 'Yellow'
    $priv = (& $WgTool genkey 2>$null) -join ''
    $priv = $priv.Trim()
    if (-not $priv) { Write-Log 'HATA: Anahtar uretilemedi.' 'Red'; return $null }
    $pub  = (($priv | & $WgTool pubkey 2>$null) -join '').Trim()
    if (-not $pub)  { Write-Log 'HATA: Public key uretilemedi.' 'Red'; return $null }

    Write-Log 'Cloudflare WARP API sine kayit oluyor (ucretsiz, hesapsiz)...' 'Yellow'
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
        Write-Log ("WARP kayit hatasi: {0}" -f $_.Exception.Message) 'Red'
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
    Write-Log ("WARP hesabi hazir. Tip: {0}, arayuz: {1}" -f $acc.account_type, $acc.address_v4) 'Green'
    return $acc
}

function Get-WarpAccount {
    if (Test-Path $AccountFile) {
        try { return Get-Content $AccountFile -Raw | ConvertFrom-Json } catch {}
    }
    return (New-WarpAccount)
}

# ------------------------------------------------------------------
#  .conf olustur
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
#  Tunel ac / kapat
# ------------------------------------------------------------------
function Stop-Tunnel {
    param([string]$Name = $TunnelName)
    $svc = "WireGuardTunnel`$$Name"
    $exists = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($exists) {
        Write-Log ("Tunel kapatiliyor: {0}" -f $Name) 'Yellow'
        & $WgExe /uninstalltunnelservice $Name 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    } else {
        # servis yoksa yine de cagir (kalinti olabilir)
        & $WgExe /uninstalltunnelservice $Name 2>&1 | Out-Null
    }
}

function Start-Tunnel {
    param([string]$ConfPath, [string]$Name = $TunnelName)
    Stop-Tunnel -Name $Name
    Write-Log ("Tunel aciliyor: {0}" -f $Name) 'Yellow'
    & $WgExe /installtunnelservice $ConfPath 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    $svc = Get-Service -Name "WireGuardTunnel`$$Name" -ErrorAction SilentlyContinue
    return ($svc -and $svc.Status -eq 'Running')
}

# ------------------------------------------------------------------
#  Yonetici yetkisi
# ------------------------------------------------------------------
if (-not (Test-Admin) -and -not $NoElevate -and $Action -ne 'Status') {
    Write-Host 'Yonetici yetkisi gerekli. UAC penceresi aciliyor...' -ForegroundColor Yellow
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
    catch { Write-Host 'Yukseltme iptal edildi.' -ForegroundColor Red }
    return
}

# ------------------------------------------------------------------
#  Baslik
# ------------------------------------------------------------------
Clear-Host
Write-Host ''
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host '     K I T O W G  -  WireGuard / WARP  (UCRETSIZ)' -ForegroundColor Cyan
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Log ("Eylem={0} Ulke={1}" -f $Action, $Country) 'White'

# ------------------------------------------------------------------
#  STATUS
# ------------------------------------------------------------------
if ($Action -eq 'Status') {
    $svc = Get-Service -Name "WireGuardTunnel`$$TunnelName" -ErrorAction SilentlyContinue
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$TunnelName*" }
    Write-Host ("    Tunel servisi : {0}" -f $(if ($svc) { $svc.Status } else { 'YOK' }))
    Write-Host ("    Adaptor       : {0}" -f $(if ($adapters) { ($adapters.Name -join ', ') } else { '-' }))
    $g = Get-PublicGeo
    if ($g) { Write-Host ("    Cikis IP      : {0}  ({1} / {2})" -f $g.IP, $g.Country, $g.CC) -ForegroundColor Green }
    else    { Write-Host '    Cikis IP      : alinamadi' -ForegroundColor Yellow }
    $acc = if (Test-Path $AccountFile) { Get-Content $AccountFile -Raw | ConvertFrom-Json } else { $null }
    if ($acc) { Write-Host ("    WARP hesabi   : {0} ({1})" -f $acc.account_type, $acc.device_id) }
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
    Write-Log 'Tunel kapatildi. Normal baglantiya donuldu.' 'Green'
    if ($g) { Write-Log ("Cikis IP: {0}  ({1})" -f $g.IP, $g.Country) 'Green' }
    Write-Host ''
    return
}

# ------------------------------------------------------------------
#  RESET
# ------------------------------------------------------------------
if ($Action -eq 'Reset') {
    Stop-Tunnel
    Remove-Item $AccountFile -ErrorAction SilentlyContinue
    Write-Log 'WARP hesabi silindi. Bir sonraki Up ile yeni hesap olusturulacak.' 'Green'
    Write-Host ''
    return
}

# ------------------------------------------------------------------
#  INSTALL
# ------------------------------------------------------------------
if ($Action -eq 'Install') {
    if (Test-WireGuard) { Write-Log 'WireGuard zaten kurulu.' 'Green' }
    else { [void](Install-WireGuard) }
    Write-Host ''
    return
}

# ------------------------------------------------------------------
#  Mevcut durum (ulke filtresi icin referans)
# ------------------------------------------------------------------
$own = Get-PublicGeo
$ownCC = if ($own) { $own.CC } else { $null }
if ($own) { Write-Log ("Mevcut cikis IP: {0} ({1})" -f $own.IP, $own.Country) 'Gray' }

# ------------------------------------------------------------------
#  REGISTER
# ------------------------------------------------------------------
if ($Action -eq 'Register') {
    $acc = New-WarpAccount
    if ($acc) { Write-Log 'WARP hesabi olusturuldu.' 'Green' } else { Write-Log 'Kayit basarisiz.' 'Red' }
    Write-Host ''
    return
}

# ------------------------------------------------------------------
#  Kendi profil klasoru (opsiyonel, kesin ulke secimi)
# ------------------------------------------------------------------
function Get-ProfilesByCountry {
    param([string]$Dir, [string]$Filter)
    if (-not $Dir -or -not (Test-Path $Dir)) { return @() }
    $files = Get-ChildItem -Path $Dir -Filter *.conf -File
    $out = @()
    foreach ($f in $files) {
        # Dosya adi ilk 2 harften ulke kodu cikarilir: DE_frankfurt.conf
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
    Write-Log ("Profil kullaniliyor: {0}" -f $Path) 'Yellow'
    # Kendi config'ini oldugu gibi kullan; tunel adini degistirmek icin kopyala
    $target = Join-Path $ConfDir "$TunnelName.conf"
    New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null
    Copy-Item $Path $target -Force
    if (-not (Start-Tunnel -ConfPath $target)) {
        Write-Log 'Tunel baslatilamadi.' 'Red'
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

# 1) Kullanici profili verilmisse
if ($Profile) {
    $g = Connect-Profile -Path $Profile -Label 'profil'
    if ($g) { Write-Log ("Baglandi: {0} ({1})" -f $g.IP, $g.Country) 'Green' } else { Write-Log 'Baglanti kurulamadi.' 'Red' }
    Write-Host ''
    return
}
if ($ProfileDir) {
    $p = Get-ProfilesByCountry -Dir $ProfileDir -Filter $Country | Get-Random
    if ($p) {
        $g = Connect-Profile -Path $p.File
        if ($g) { Write-Log ("Baglandi: {0} ({1}) - {2}" -f $g.IP, $g.Country, $p.CC) 'Green' }
    } else {
        Write-Log 'Profil klasorunde uygun .conf bulunamadi.' 'Red'
    }
    Write-Host ''
    return
}

# 2) WARP hesabi
$acc = Get-WarpAccount
if (-not $acc) { Write-Log 'WARP hesabi alinamadi, islem durduruldu.' 'Red'; Write-Host ''; return }

# 3) Endpoint secimi
$candidates = @()
if ($Endpoint) { $candidates = @($Endpoint) }
else {
    $all = Get-EndpointCandidates -Fetch:$FetchEndpoints
    $cache = Get-Cache

    # Ulke filtresine uyan onbellek kayitlari
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
        Write-Log ("Onbellekten {0} uygun endpoint bulundu." -f $candidates.Count) 'Gray'
    }
    # Onbellek bos/uygun degilse tum adaylardan rastgele
    if ($candidates.Count -eq 0) {
        $candidates = @($all | Sort-Object { Get-Random })
    }
}

$maxTry = if ($Action -eq 'Scan') { $MaxScan } else { $Attempts }
$maxTry = [Math]::Max(1, $maxTry)

Write-Log ("{0} endpoint denenecek (filtre: {1})..." -f $maxTry, $Country) 'Yellow'

$chosen = $null
$chosenGeo = $null
$tried = 0
$lastWorking = $null
$lastWorkingGeo = $null

foreach ($ep in $candidates) {
    if ($tried -ge $maxTry) { break }
    $tried++
    Write-Log ("[{0}/{1}] Deneniyor: {2}" -f $tried, $maxTry, $ep) 'Gray'

    if ($DryRun) {
        Write-Log 'DryRun: tunel acilmadi.' 'Yellow'
        continue
    }

    New-WarpConf -Account $acc -EndpointAddr $ep -Path $confPath
    $up = Start-Tunnel -ConfPath $confPath
    if (-not $up) { Write-Log '  tunel servisi baslamadi.' 'DarkGray'; continue }

    $geo = Test-Internet -Retries 2 -Sleep 3
    if (-not $geo) {
        Write-Log '  baglanti dogrulanamadi, geri aliniyor.' 'DarkGray'
        Stop-Tunnel
        continue
    }

    Write-Log ("  cikis: {0} ({1}) - {2}" -f $geo.IP, $geo.Country, $geo.CC) 'Gray'
    Add-Cache -Ep $ep -Ip $geo.IP -CC $geo.CC -CountryName $geo.Country -City $geo.City

    if (-not $lastWorking) { $lastWorking = $ep; $lastWorkingGeo = $geo }

    # Filtre kontrolu
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
        Write-Log ("  ULKE TUTTU: {0}" -f $geo.Country) 'Green'
        break
    } else {
        Write-Log ("  ulke uygun degil ({0}), sonraki endpoint..." -f $geo.CC) 'DarkGray'
        if (-not $Strict) { Stop-Tunnel }
    }
    if ($Action -eq 'Scan') { Stop-Tunnel }
}

# ------------------------------------------------------------------
#  Sonuc
# ------------------------------------------------------------------
Write-Host ''
if ($chosen) {
    Write-Host '  ---------------- SONUC ----------------' -ForegroundColor Cyan
    Write-Host ("    ONCE  : {0}" -f $(if ($own) { "$($own.IP) ($($own.Country))" } else { '-' })) -ForegroundColor White
    Write-Host ("    SONRA : {0}  ({1} / {2})" -f $chosenGeo.IP, $chosenGeo.Country, $chosenGeo.CC) -ForegroundColor Green
    Write-Host ("    Endpoint: {0}" -f $chosen) -ForegroundColor White
    Write-Host '  --------------------------------------' -ForegroundColor Cyan
    Write-Log 'Tunel aktif (KitoWG). Kapatmak icin: KitoWG.ps1 -Action Down' 'Green'
}
elseif ($lastWorking) {
    if ($Strict) {
        Write-Log ("Ulke filtresi tutmadi. Son calisan endpoint: {0} (Strict: tunel kapatildi)." -f $lastWorking) 'Yellow'
    } else {
        Write-Log ("Ulke tam tutmadi; son calisan endpoint tekrar aciliyor: {0}" -f $lastWorking) 'Yellow'
        New-WarpConf -Account $acc -EndpointAddr $lastWorking -Path $confPath
        $reUp = Start-Tunnel -ConfPath $confPath
        $reGeo = $null
        if ($reUp) { $reGeo = Test-Internet -Retries 3 -Sleep 3 }
        if ($reGeo) {
            Write-Host '  ---------------- SONUC ----------------' -ForegroundColor Cyan
            Write-Host ("    ONCE  : {0}" -f $(if ($own) { "$($own.IP) ($($own.Country))" } else { '-' })) -ForegroundColor White
            Write-Host ("    SONRA : {0}  ({1} / {2})" -f $reGeo.IP, $reGeo.Country, $reGeo.CC) -ForegroundColor Yellow
            Write-Host ("    Endpoint: {0}" -f $lastWorking) -ForegroundColor White
            Write-Host '  --------------------------------------' -ForegroundColor Cyan
            Write-Log 'Tunel aktif (ulke filtresi tam tutmadi). Kapatmak icin: KitoWG.ps1 -Action Down' 'Yellow'
        } else {
            Stop-Tunnel
            Write-Log 'Son calisan endpoint tekrar acilamadi; tunel kapatildi.' 'Red'
        }
    }
}
else {
    Write-Log 'Hicbir endpoint ile baglanti kurulamadi.' 'Red'
    Stop-Tunnel
}
Write-Host ''
Write-Log ("Log: {0}" -f $LogFile) 'DarkGray'
Write-Host ''
