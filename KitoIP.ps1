<#
    ============================================================
      KitoIP  -  Otomatik IP Degistirici  (Windows)
    ============================================================
      Baslatildiginda aktif ag adaptorunun IP adresini otomatik
      degistirir. Uc yontem destekler:

        Auto     : Akilli mod. Once DHCP kirasini yeniler (release/
                   renew + adaptor reset). Public IP degismezse
                   subnet icinden RASTGELE statik IP atar.
        Renew    : Sadece DHCP kira yenileme (yeni IP almaya calisir).
        Random   : Subnet icinden rastgele bir statik IP atar.
        Static   : -StaticIP ile verilen IP'yi atar.
        Restore  : Adaptoru tekrar DHCP'ye (otomatik) dondurur.

      Kullanim ornekleri:
        KitoIP.ps1                       -> Auto mod
        KitoIP.ps1 -Mode Random
        KitoIP.ps1 -Mode Static -StaticIP 192.168.1.50
        KitoIP.ps1 -Mode Restore
        KitoIP.ps1 -Interface "Ethernet"

      NOT: Yerel (LAN) IP degistirmek, dis dunyaya cikan PUBLIC
      IP'yi degistirmez. Public IP icin VPN/proxy gerekir.
    ============================================================
#>

[CmdletBinding()]
param(
    [ValidateSet('Auto','Renew','Random','Static','Restore','Foreign')]
    [string]$Mode = 'Auto',

    [string]$Interface,                                  # Bos ise aktif adaptor secilir
    [string]$StaticIP,                                   # -Mode Static icin hedef IP
    [int]$PrefixLength = 24,                             # Alt ag maskesi (24 = 255.255.255.0)
    [string]$Gateway,                                    # Bos ise otomatik bulunur
    [string]$Dns = '1.1.1.1,8.8.8.8',                    # Statik modda atanacak DNS
    [string]$Country = 'Random',                         # -Mode Foreign icin ulke
    [switch]$NoElevate                                   # Yonetici yukseltmeyi kapat
)

# ------------------------------------------------------------------
#  FOREIGN modu -> KitoVPN.ps1'e devret (public IP / yabanci ulke)
# ------------------------------------------------------------------
if ($Mode -eq 'Foreign') {
    $vpnScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'KitoVPN.ps1'
    if (-not (Test-Path $vpnScript)) {
        Write-Host 'HATA: KitoVPN.ps1 bulunamadi.' -ForegroundColor Red
        return
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $vpnScript -Mode Foreign -Country $Country
    return
}


$ErrorActionPreference = 'SilentlyContinue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$LogFile   = Join-Path $ScriptDir 'kitoip.log'

# ------------------------------------------------------------------
#  Yardimci fonksiyonlar
# ------------------------------------------------------------------
function Write-Log {
    param([string]$Msg, [string]$Color = 'Gray')
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host $Msg -ForegroundColor $Color
    Add-Content -Path $LogFile -Value "[$stamp] $Msg" -ErrorAction SilentlyContinue
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-Mask {
    param([int]$Prefix)
    $bin = ('1' * $Prefix).PadRight(32, '0')
    $bytes = for ($i = 0; $i -lt 32; $i += 8) {
        [Convert]::ToInt32($bin.Substring($i, 8), 2)
    }
    ($bytes -join '.')
}

function Get-ActiveAdapter {
    # Varsayilan ag gecidi olan, calisan adaptoru bul
    $cfg = Get-NetIPConfiguration |
        Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq 'Up' } |
        Select-Object -First 1
    if ($cfg) { return $cfg.InterfaceAlias }

    # Bulunamazsa sabit IP'li ilk IPv4 adaptoru kullan
    $alt = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
        Select-Object -First 1
    if ($alt) { return $alt.InterfaceAlias }
    return $null
}

function Get-AdapterIPv4 {
    param([string]$Iface)
    $ip = Get-NetIPAddress -InterfaceAlias $Iface -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1
    return $ip
}

function Get-PublicIP {
    try {
        (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 8).Trim()
    } catch { return 'bilinmiyor' }
}

function Save-State {
    param([string]$Iface)
    $state = [ordered]@{
        Interface   = $Iface
        Timestamp   = (Get-Date).ToString('s')
    }
    $ip = Get-AdapterIPv4 -Iface $Iface
    if ($ip) {
        $state.IP     = $ip.IPAddress
        $state.Prefix = $ip.PrefixLength
        $state.Origin = $ip.PrefixOrigin
    }
    $gw = (Get-NetIPConfiguration -InterfaceAlias $Iface).IPv4DefaultGateway.NextHop
    $state.Gateway = $gw
    $state | ConvertTo-Json | Set-Content -Path (Join-Path $ScriptDir 'last_state.json') -ErrorAction SilentlyContinue
}

function Show-State {
    param([string]$Label, [string]$Iface)
    Write-Host ''
    Write-Host "  [$Label]" -ForegroundColor Cyan
    $ip = Get-AdapterIPv4 -Iface $Iface
    $gw = (Get-NetIPConfiguration -InterfaceAlias $Iface).IPv4DefaultGateway.NextHop
    $origin = if ($ip) { $ip.PrefixOrigin } else { '-' }
    Write-Host ("    Adaptor  : {0}" -f $Iface)
    Write-Host ("    Yerel IP : {0}/{1}  ({2})" -f `
        ($(if ($ip) {$ip.IPAddress} else {'-'})), `
        ($(if ($ip) {$ip.PrefixLength} else {'-'})), $origin)
    Write-Host ("    Gecit    : {0}" -f ($(if ($gw) {$gw} else {'-'})))
    Write-Host ("    Public IP: {0}" -f (Get-PublicIP))
}

function Set-StaticIP {
    param([string]$Iface, [string]$IP, [int]$Prefix, [string]$Gw)
    $mask = ConvertTo-Mask -Prefix $Prefix
    Write-Log ("Statik IP ataniyor: {0}/{1} gecit={2}" -f $IP, $Prefix, $Gw) 'Yellow'

    if ($Gw) {
        netsh interface ip set address name="$Iface" static $IP $mask $Gw 1 | Out-Null
    } else {
        netsh interface ip set address name="$Iface" static $IP $mask | Out-Null
    }
    # DNS
    $dnsList = $Dns.Split(',')
    netsh interface ip set dns name="$Iface" static $dnsList[0].Trim() primary | Out-Null
    for ($i = 1; $i -lt $dnsList.Count; $i++) {
        netsh interface ip add dns name="$Iface" $dnsList[$i].Trim() index=($i + 1) | Out-Null
    }
    Start-Sleep -Seconds 3
}

function Renable-Adapter {
    param([string]$Iface)
    Write-Log ("Adaptor resetleniyor: {0}" -f $Iface) 'Yellow'
    try {
        Restart-NetAdapter -Name $Iface -Confirm:$false
        Start-Sleep -Seconds 4
    } catch {
        # Wi-Fi icin baglan/kes ile yeni kira zorla
        netsh interface set interface name="$Iface" admin=disabled | Out-Null
        Start-Sleep -Seconds 3
        netsh interface set interface name="$Iface" admin=enabled  | Out-Null
        Start-Sleep -Seconds 5
    }
    ipconfig /release | Out-Null
    Start-Sleep -Seconds 1
    ipconfig /renew   | Out-Null
    Start-Sleep -Seconds 4
}

# ------------------------------------------------------------------
#  Yonetici yetkisi (gerekirse UAC ile yeniden baslat)
# ------------------------------------------------------------------
if (-not (Test-Admin) -and -not $NoElevate) {
    Write-Host 'Yonetici yetkisi gerekli. UAC penceresi aciliyor...' -ForegroundColor Yellow
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$($MyInvocation.MyCommand.Path)`"")
    $argList += @('-Mode', $Mode)
    if ($Interface)  { $argList += @('-Interface',  "`"$Interface`"") }
    if ($StaticIP)   { $argList += @('-StaticIP',   $StaticIP) }
    if ($Gateway)    { $argList += @('-Gateway',    $Gateway) }
    $argList += @('-PrefixLength', $PrefixLength)
    $argList += '-NoElevate'
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Host 'Yukseltme iptal edildi. Yonetici olarak tekrar deneyin.' -ForegroundColor Red
    }
    return
}

# ------------------------------------------------------------------
#  Baslik
# ------------------------------------------------------------------
Clear-Host
Write-Host ''
Write-Host '  ============================================' -ForegroundColor Green
Write-Host '          K I T O I P   -   IP Degistirici' -ForegroundColor Green
Write-Host '  ============================================' -ForegroundColor Green
Write-Log ("Baslatildi. Mod={0}" -f $Mode) 'White'

# ------------------------------------------------------------------
#  Adaptor secimi
# ------------------------------------------------------------------
if (-not $Interface) {
    $Interface = Get-ActiveAdapter
}
if (-not $Interface) {
    Write-Log 'HATA: Aktif ag adaptoru bulunamadi.' 'Red'
    return
}
Write-Log ("Kullanilan adaptor: {0}" -f $Interface) 'Gray'

$beforeIP = (Get-AdapterIPv4 -Iface $Interface).IPAddress
$beforePub = Get-PublicIP
Save-State -Iface $Interface
Show-State -Label 'ONCE' -Iface $Interface

# ------------------------------------------------------------------
#  Mod islemleri
# ------------------------------------------------------------------
switch ($Mode) {

    'Restore' {
        Write-Log 'DHCP (otomatik) moduna donuluyor...' 'Yellow'
        netsh interface ip set address name="$Interface" source=dhcp | Out-Null
        netsh interface ip set dns     name="$Interface" source=dhcp | Out-Null
        ipconfig /release  | Out-Null
        Start-Sleep -Seconds 1
        ipconfig /renew    | Out-Null
        Start-Sleep -Seconds 3
    }

    'Renew' {
        Write-Log 'DHCP kirasini yeniliyorum (release/renew + reset)...' 'Yellow'
        netsh interface ip set address name="$Interface" source=dhcp | Out-Null
        netsh interface ip set dns     name="$Interface" source=dhcp | Out-Null
        Renable-Adapter -Iface $Interface
    }

    'Random' {
        $cur = Get-AdapterIPv4 -Iface $Interface
        if (-not $cur) { Write-Log 'HATA: Mevcut IP okunamadi, rastgele mod yapilamaz.' 'Red'; return }
        $prefix = if ($PrefixLength -ne 24) { $PrefixLength } else { $cur.PrefixLength }
        $octets = $cur.IPAddress.Split('.')
        $base   = "{0}.{1}.{2}" -f $octets[0], $octets[1], $octets[2]
        # Gecit ve mevcut IP'den farkli rastgele host sec (2-254)
        do { $host8 = Get-Random -Minimum 2 -Maximum 255 } while ("$base.$host8" -eq $cur.IPAddress)
        $newIP  = "$base.$host8"
        $gw     = if ($Gateway) { $Gateway } else { (Get-NetIPConfiguration -InterfaceAlias $Interface).IPv4DefaultGateway.NextHop }
        Set-StaticIP -Iface $Interface -IP $newIP -Prefix $prefix -Gw $gw
    }

    'Static' {
        if (-not $StaticIP) { Write-Log 'HATA: -Mode Static icin -StaticIP gerekli.' 'Red'; return }
        $gw = if ($Gateway) { $Gateway } else { (Get-NetIPConfiguration -InterfaceAlias $Interface).IPv4DefaultGateway.NextHop }
        Set-StaticIP -Iface $Interface -IP $StaticIP -Prefix $PrefixLength -Gw $gw
    }

    'Auto' {
        Write-Log 'AUTO mod: once DHCP kira yenilemesi deneniyor...' 'Yellow'
        netsh interface ip set address name="$Interface" source=dhcp | Out-Null
        netsh interface ip set dns     name="$Interface" source=dhcp | Out-Null
        Renable-Adapter -Iface $Interface

        $afterIP  = (Get-AdapterIPv4 -Iface $Interface).IPAddress
        $afterPub = Get-PublicIP

        if ($afterIP -eq $beforeIP -and $afterPub -eq $beforePub) {
            Write-Log 'DHCP ile IP degismedi -> subnet icinden rastgele statik IP ataniyorum.' 'Yellow'
            $cur    = Get-AdapterIPv4 -Iface $Interface
            $octets = $cur.IPAddress.Split('.')
            $base   = "{0}.{1}.{2}" -f $octets[0], $octets[1], $octets[2]
            do { $host8 = Get-Random -Minimum 2 -Maximum 255 } while ("$base.$host8" -eq $cur.IPAddress)
            $gw = if ($Gateway) { $Gateway } else { (Get-NetIPConfiguration -InterfaceAlias $Interface).IPv4DefaultGateway.NextHop }
            Set-StaticIP -Iface $Interface -IP "$base.$host8" -Prefix $cur.PrefixLength -Gw $gw
        } else {
            Write-Log 'DHCP kira yenilemesi sonrasi IP degisti/guncellendi.' 'Green'
        }
    }
}

# ------------------------------------------------------------------
#  Sonuc
# ------------------------------------------------------------------
Start-Sleep -Seconds 2
Show-State -Label 'SONRA' -Iface $Interface

$afterIP  = (Get-AdapterIPv4 -Iface $Interface).IPAddress
$afterPub = Get-PublicIP
Write-Host ''
Write-Host '  ---------------- OZET ----------------' -ForegroundColor Green
Write-Host ("    Yerel IP  : {0}  ->  {1}" -f $beforeIP, $afterIP) -ForegroundColor White
Write-Host ("    Public IP : {0}  ->  {1}" -f $beforePub, $afterPub) -ForegroundColor White
Write-Host '  --------------------------------------' -ForegroundColor Green
Write-Host ''
Write-Log ("Islem tamam. {0} -> {1}" -f $beforeIP, $afterIP) 'Green'
Write-Log ("Log dosyasi: {0}" -f $LogFile) 'DarkGray'

