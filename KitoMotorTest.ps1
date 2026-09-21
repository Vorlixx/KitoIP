# KitoCore motor testi - HICBIR sistem ayarini degistirmez (salt-okuma tarama)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'KitoCore.ps1')

Write-Host "=== 1) TIP: Derleme testi ===" -ForegroundColor Yellow
Write-Host ("Kito tipi yuklendi mi: {0}" -f [bool]('Kito' -as [type]))

Write-Host ""
Write-Host "=== 2) TAKILMA TESTI: 300 sahte (kara delik) hedef, 800ms timeout ===" -ForegroundColor Yellow
$fake = @()
for ($i = 1; $i -le 300; $i++) { $fake += ("192.0.2.{0}:8080" -f ($i % 254 + 1)) }
[Kito]::Total = $fake.Count; [Kito]::Done = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-KitoStage -Body {
    param($p)
    [Kito]::TcpScan([string[]]$p.eps, [int]$p.tmo, [int]$p.wk)
} -ArgList @([pscustomobject]@{ eps=$fake; tmo=800; wk=128 }) -Label 'TCP  ' -HardCapSec 60
$sw.Stop()
Write-Host ("SONUC: {0} canli, gecen sure {1:N1}s (beklenen: takilmadan ~3-5s)" -f @($r).Count, $sw.Elapsed.TotalSeconds) -ForegroundColor Green

Write-Host ""
Write-Host "=== 3) GERCEK TEST: bilinen proxy listesi uzerinde TCP ===" -ForegroundColor Yellow
$best = Join-Path $PSScriptRoot 'proxies_best.txt'
if (Test-Path $best) {
    $eps = @(Read-ProxyList $best)
    Write-Host ("Dosyadan {0} proxy okundu." -f $eps.Count)
    [Kito]::Total = $eps.Count; [Kito]::Done = 0
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    $alive = Invoke-KitoStage -Body {
        param($p)
        [Kito]::TcpScan([string[]]$p.eps, [int]$p.tmo, [int]$p.wk)
    } -ArgList @([pscustomobject]@{ eps=$eps; tmo=2500; wk=64 }) -Label 'TCP  ' -HardCapSec 60
    $sw2.Stop()
    Write-Host ("TCP canli: {0}/{1}  ({2:N1}s)" -f @($alive).Count, $eps.Count, $sw2.Elapsed.TotalSeconds) -ForegroundColor Green

    if (@($alive).Count -gt 0) {
        $top = @($alive | Sort-Object Latency | Select-Object -First 12)
        Write-Host "En hizli 12 (TCP ms):"
        $top | ForEach-Object { Write-Host ("   {0,-24} {1} ms" -f $_.Proxy, $_.Latency) }
    }

    Write-Host ""
    Write-Host "=== 4) HTTP/HTTPS testi (ilk 20 canli aday) ===" -ForegroundColor Yellow
    $eps20 = @($alive | Sort-Object Latency | ForEach-Object { $_.Proxy } | Select-Object -First 20)
    if ($eps20.Count -gt 0) {
        [Kito]::Total = $eps20.Count; [Kito]::Done = 0
        $sw3 = [System.Diagnostics.Stopwatch]::StartNew()
        $h = Invoke-KitoStage -Body {
            param($p)
            [Kito]::HttpCheck([string[]]$p.eps, [int]$p.tmo, [int]$p.wk, $false, $false)
        } -ArgList @([pscustomobject]@{ eps=$eps20; tmo=4000; wk=20 }) -Label 'HTTP ' -HardCapSec 90
        $sw3.Stop()
        Write-Host ("HTTP canli: {0}/{1}  ({2:N1}s)" -f @($h).Count, $eps20.Count, $sw3.Elapsed.TotalSeconds) -ForegroundColor Green
        @($h) | Sort-Object Latency | Select-Object -First 10 |
            ForEach-Object { Write-Host ("   {0,-24} {1,5} ms  HTTPS={2,-5} {3}/{4}" -f $_.Proxy, $_.Latency, $_.Https, $_.CC, $_.Country) }
    }
} else {
    Write-Host "proxies_best.txt yok, atlandi."
}
Write-Host ""
Write-Host "TEST TAMAM." -ForegroundColor Green
