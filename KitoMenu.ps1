<#
    ============================================================
      KitoMenu  -  TEK TERMINAL, BIRLESIK MENU  (v6)
    ============================================================
      Tum isler BU pencereden yapilir; ayri ayri .bat dosyalari
      YOKTUR. KitoIP.bat sadece bu menuyu baslatir.

      Icerik:
        * Animasyonlu acilis ekrani (logo + yazma efekti + spinner)
        * Proxy ile Yabanci IP  (KitoVPN.ps1 -Mode Foreign)
        * En Hizli Baglan       (KitoVPN.ps1 -Mode Fast)
        * Proxy Avi             (KitoVPN.ps1 -Mode Hunt)
        * Proxy Listesi         (KitoVPN.ps1 -Mode List)
        * Ulke Secimi           (Random / ALL / DE,NL,US ...)
        * Proxy Kapat / Durum
        * 100.000+ proxy icin dosyadan toplu ekleme
        * LAN IP Degistir       (KitoIP.ps1)
        * WireGuard WARP VPN    (KitoWG.ps1)
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

# Write-FixedLine (tek satirlik ekran ciziminde kullanilir) burada tanimli
try { . $CoreScript } catch {}

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { (Get-Host).UI.RawUI.WindowTitle = 'KitoIP  -  Proxy + IP Araci' } catch {}

$script:poolCache = $null

# ==================================================================
#  Ayarlar (ulke secimi hatirlanir)
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
#  Animasyonlar
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

    # ---- ust cerceve (kutu cizim karakterleri) --------------------------
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

    $sub1 = 'Proxy + IP Araci  -  v6'
    $sub2 = 'Takilmayan tarama motoru: C# thread havuzu'
    Write-Host ('   |' + $sub1.PadLeft([int](($barW + $sub1.Length) / 2)).PadRight($barW) + '|') -ForegroundColor Cyan
    Write-Host ('   |' + $sub2.PadLeft([int](($barW + $sub2.Length) / 2)).PadRight($barW) + '|') -ForegroundColor DarkGray
    Write-Host ('   +' + ('=' * $barW) + '+') -ForegroundColor DarkMagenta
    Write-Host ''

    # ---- TEK SATIRLIK hazirlik animasyonu (asla alt satira tasmaz) ------
    $spin = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
    $steps = @('sistem taniniyor', 'onbellek okunuyor', 'motor hazirlaniyor', 'menu aciliyor')
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
        Write-FixedLine -Row $row -Text '   [OK] Hazir.' -Color Green
    } catch {
        Write-Host '   [OK] Hazir.' -ForegroundColor Green
    }
    Start-Sleep -Milliseconds 200
}

function Wait-Key {
    param([string]$Msg = '  Devam etmek icin ENTER tusuna bas...')
    if ($NoPause) { return }
    Write-Host ''
    Write-Host $Msg -ForegroundColor DarkGray -NoNewline
    [void][Console]::ReadLine()
}

# ==================================================================
#  Havuz bilgisi (100.000+ satir icin hizli sayim)
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
#  Alt script calistirici (AYNI pencerede)
# ==================================================================
function Invoke-KitoChild {
    param([string]$Script, [string[]]$ExtraArgs)
    if (-not (Test-Path $Script)) {
        Write-Host ("  HATA: {0} bulunamadi." -f (Split-Path -Leaf $Script)) -ForegroundColor Red
        return
    }
    $all = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Script) + @($ExtraArgs)
    Write-Host ''
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
    & powershell.exe @all
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
}

# ==================================================================
#  Proxy ekleme (dosyadan, 100k destekli)
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
    Write-Host '  Proxy listesi ekle' -ForegroundColor Cyan
    Write-Host '  Dosya yolunu yazip ENTER (veya pencereye surukleyip birak).' -ForegroundColor DarkGray
    Write-Host '  Kabul edilen bicimler: ip:port  |  ip:port:user:pass  |  http://ip:port' -ForegroundColor DarkGray
    Write-Host '  Ornek: C:\proxies\buyuk_liste.txt' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Yol > ' -ForegroundColor Yellow -NoNewline
    $src = [Console]::ReadLine()
    if (-not $src) { return }
    $src = $src.Trim().Trim('"').Trim("'")
    if (-not (Test-Path $src)) {
        Write-Host ("  HATA: dosya bulunamadi -> {0}" -f $src) -ForegroundColor Red
        return
    }

    $set = Read-EndpointsFrom $LocalFile
    $before = $set.Count
    $add = Read-EndpointsFrom $src
    foreach ($p in $add) { [void]$set.Add($p) }
    $newCount = $set.Count

    Write-Host ("  Kaynakta {0} proxy bulundu, {1} yeni eklendi." -f $add.Count, ($newCount - $before)) -ForegroundColor Green
    Write-Host ("  Toplam benzersiz havuz: {0} proxy" -f $newCount) -ForegroundColor Green

    Write-Host '  Onbellegi de tazeleyeyim mi (onceki test sonuclari silinsin)? [e/H] ' -ForegroundColor Yellow -NoNewline
    $ans = [Console]::ReadLine()
    if ($ans -and $ans.Trim().ToLower().StartsWith('e')) {
        Remove-Item $CacheFile -ErrorAction SilentlyContinue
        Remove-Item $BestFile -ErrorAction SilentlyContinue
        Write-Host '  Onbellek temizlendi.' -ForegroundColor DarkGray
    }

    # Buyuk listeyi diske yaz (StreamWriter ile yaz -> 100k'da cok hizli)
    try {
        $sw = New-Object System.IO.StreamWriter($LocalFile, $false, (New-Object System.Text.UTF8Encoding($false)))
        foreach ($p in $set) { $sw.WriteLine($p) }
        $sw.Flush(); $sw.Close()
        $script:poolCache = $null
        Write-Host ("  Kaydedildi: {0}" -f $LocalFile) -ForegroundColor Green
    } catch {
        Write-Host '  HATA: yazilamadi.' -ForegroundColor Red
    }
}

# ==================================================================
#  Ulke menu
# ==================================================================
function Show-CountryMenu {
    while ($true) {
        $s = Get-Settings
        Clear-Host
        Write-Host ''
        Write-Host '  ============================================================' -ForegroundColor Cyan
        Write-Host '      ULKE SECIMI' -ForegroundColor Cyan
        Write-Host '  ============================================================' -ForegroundColor Cyan
        Write-Host ("      Simdiki secim: {0}" -f $s.Country) -ForegroundColor Green
        Write-Host ''
        Write-Host '    [1]  Random          (kendi ulken disinda rastgele)'
        Write-Host '    [2]  ALL             (herhangi bir ulke)'
        Write-Host '    [3]  DE   Almanya'
        Write-Host '    [4]  NL   Hollanda'
        Write-Host '    [5]  US   ABD'
        Write-Host '    [6]  GB   Ingiltere'
        Write-Host '    [7]  FR   Fransa'
        Write-Host '    [8]  RU   Rusya'
        Write-Host '    [9]  SG   Singapur'
        Write-Host '    [10] DE,NL,US       (birden fazla)'
        Write-Host '    [0]  Geri'
        Write-Host ''
        Write-Host '  Yukaridan bir numara SEC, veya istedigin ulke kodunu' -ForegroundColor DarkGray
        Write-Host '  DOGRUDAN yaz (orn: IT  veya  IT,ES,PT):' -ForegroundColor DarkGray
        Write-Host '  Secim > ' -ForegroundColor Yellow -NoNewline
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
                # Sayi degil -> dogrudan yazilan ulke kodu/kodlari olarak kabul et
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
        Write-Host '      LAN IP DEGISTIR  (yerel adaptor IP adresi)' -ForegroundColor Cyan
        Write-Host '  ============================================================' -ForegroundColor Cyan
        Write-Host '      NOT: Yerel IP degistirmek PUBLIC IP yi degistirmez.' -ForegroundColor DarkGray
        Write-Host '           Public IP icin [1]/[2] proxy secenegini kullan.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '    [1]  Auto     (akilli: DHCP yenile, olmazsa rastgele statik)'
        Write-Host '    [2]  Renew    (sadece DHCP kirasini yenile)'
        Write-Host '    [3]  Random   (subnet icinden rastgele statik IP)'
        Write-Host '    [4]  Static   (elle IP ver)'
        Write-Host '    [5]  Restore  (tekrar DHCP / otomatige don)'
        Write-Host '    [0]  Geri'
        Write-Host ''
        Write-Host '  Secim > ' -ForegroundColor Yellow -NoNewline
        $c = [Console]::ReadLine()
        switch ("$c".Trim()) {
            '1' { Invoke-KitoChild $IpScript @('-Mode','Auto');    Wait-Key }
            '2' { Invoke-KitoChild $IpScript @('-Mode','Renew');   Wait-Key }
            '3' { Invoke-KitoChild $IpScript @('-Mode','Random');  Wait-Key }
            '4' {
                Write-Host ''
                Write-Host '  Verilecek statik IP (orn 192.168.1.50) > ' -ForegroundColor Yellow -NoNewline
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
        Write-Host '      WIREGUARD + CLOUDFLARE WARP  (ucretsiz, hesapsiz)' -ForegroundColor Cyan
        Write-Host '  ============================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '    [1]  Baglan (Up)         - tunel ac, ulke sec'
        Write-Host '    [2]  Kapat (Down)        - tuneli kapat'
        Write-Host '    [3]  Durum (Status)      - aktif tunel + cikis IP'
        Write-Host '    [4]  Kur (Install)       - WireGuard istemcisini kur'
        Write-Host '    [5]  Hesap (Register)    - ucretsiz WARP hesabi olustur'
        Write-Host '    [6]  Endpoint Test (Scan)'
        Write-Host '    [7]  Sifirla (Reset)     - WARP hesabini sil, bastan basla'
        Write-Host '    [0]  Geri'
        Write-Host ''
        Write-Host '  NOT: Up/Install/Register islemleri YONETICI izni ister.' -ForegroundColor DarkGray
        Write-Host '  Secim > ' -ForegroundColor Yellow -NoNewline
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
#  Ana menu
# ==================================================================
function Show-MainMenu {
    while ($true) {
        $s = Get-Settings
        $pool = Get-PoolCount
        $best = Get-LineCount $BestFile
        $cache = Get-LineCount $CacheFile
        $stateTxt = 'yok'
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
        Write-Host '      K I T O I P     Proxy + IP Araci' -ForegroundColor Magenta
        Write-Host '  ============================================================' -ForegroundColor Magenta
        Write-Host ("      Ulke secimi : {0}" -f $s.Country) -ForegroundColor Cyan
        Write-Host ("      Havuz       : {0} proxy (proxies.txt)" -f $pool) -ForegroundColor Cyan
        Write-Host ("      En iyi      : {0}   |   Onbellek: {1}" -f $best, $cache) -ForegroundColor DarkCyan
        Write-Host ("      Aktif proxy : {0}" -f $stateTxt) -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host '    [1]  Yabanci IP ye Baglan   (ulke filtresi + en dusuk ms)' -ForegroundColor White
        Write-Host '    [2]  EN HIZLI Baglan        (onbellekten, saniyeler icinde)' -ForegroundColor Green
        Write-Host '    [3]  Proxy Avi              (en iyi listeyi bastan olustur)' -ForegroundColor White
        Write-Host '    [4]  Proxy Listesi          (en hizli adaylari listele)' -ForegroundColor White
        Write-Host '    [5]  Ulke Sec               (simdi: ' -NoNewline -ForegroundColor White
        Write-Host ($s.Country + ')') -NoNewline -ForegroundColor Yellow
        Write-Host ''
        Write-Host '    [6]  Proxy Kapat            (normal baglantiya don)' -ForegroundColor White
        Write-Host '    [7]  Durum' -ForegroundColor White
        Write-Host ''
        Write-Host '    [8]  LAN IP Degistir' -ForegroundColor White
        Write-Host '    [9]  WireGuard WARP VPN' -ForegroundColor White
        Write-Host '    [P]  Proxy Listesi Yonet    (dosyadan toplu ekle / onbellek sil)' -ForegroundColor White
        Write-Host '    [0]  Cikis' -ForegroundColor White
        Write-Host ''
        Write-Host '  Secim > ' -ForegroundColor Yellow -NoNewline
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
#  Baslat
# ==================================================================
if (-not $NoSplash) { Show-Splash }
Show-MainMenu

Clear-Host
Write-Host ''
Write-Host '  KitoIP kapatildi.' -ForegroundColor Magenta
Write-Host ''
