> Bu belge Turkce surumdur. English documentation: [README.md](README.md)

# KitoIP v6 - TEK TERMINAL, BIRLESIK ARAC

Windows icin IP / Public IP degistirme araci. **Artik tek bir baslatici ve tek bir
menü var.** Ayri ayri `.bat` dosyalari kaldirildi.

```
KitoIP.bat  ->  KitoMenu.ps1  ->  (tek terminal, animasyonlu menu)
```

## Nasil baslatilir

`KitoIP.bat` dosyasina **cift tiklayin**. Animasyonlu bir acilis ekrani gelir,
ardindan birlesik menu acilir. Butun isler bu pencereden yapilir.

> Isterseniz PowerShell'den dogrudan da acabilirsiniz:
> ```
> powershell -NoProfile -ExecutionPolicy Bypass -File KitoMenu.ps1
> ```

## Dosyalar

| Dosya                  | Gorevi                                                       |
|------------------------|--------------------------------------------------------------|
| `KitoIP.bat`           | **TEK baslatici.** Sadece menuyu acar.                        |
| `KitoMenu.ps1`         | Animasyonlu acilis + birlesik menu (proxy / ulke / LAN / WARP) |
| `KitoCore.ps1`         | Ortak motor: C# thread havuzlu tarayici + yardimci fonksiyonlar |
| `KitoVPN.ps1`          | Proxy ile yabanci public IP motoru (ulke secimli, 100k destekli) |
| `KitoIP.ps1`           | Yerel (LAN) IP motoru                                        |
| `KitoWG.ps1`           | WireGuard + Cloudflare WARP motoru                           |
| `proxies.txt`          | Sizin proxy havuzunuz: her satir `ip:port` (**100.000+ satir olabilir**) |
| `proxies_best.txt`     | Hunt sonucu en iyi proxy listesi                             |
| `proxies_ok.json`      | Onbellek (calisan proxy'ler + ms + ulke)                      |
| `proxy_state.json`     | Su an aktif olan proxy                                        |
| `kito_settings.json`   | Hatirlanan ayarlar (ulke secimi)                              |
| `kitoip.log`           | Islem gunlugu                                                 |
| `warp-account.json`    | WARP hesabi, `wgconf\` tunel dosyalari                        |
| `backup\`              | Eski surumlerin yedegi                                        |

## Menu

```
============================================================
    K I T O I P     Proxy + IP Araci
============================================================
      Ulke secimi : DE
      Havuz       : 102345 proxy (proxies.txt)
      En iyi      : 60   |   Onbellek: 246
      Aktif proxy : 185.200.188.234:10001  RU/Russian Federation  533 ms

    [1]  Yabanci IP ye Baglan   (ulke filtresi + en dusuk ms)
    [2]  EN HIZLI Baglan        (onbellekten, saniyeler icinde)
    [3]  Proxy Avi              (en iyi listeyi bastan olustur)
    [4]  Proxy Listesi          (en hizli adaylari listele)
    [5]  Ulke Sec

    [6]  Proxy Kapat            (normal baglantiya don)
    [7]  Durum

    [8]  LAN IP Degistir
    [9]  WireGuard WARP VPN
    [P]  Proxy Listesi Yonet    (dosyadan toplu ekle / onbellek sil)
    [0]  Cikis
```

### [1] Yabanci IP ye Baglan
Ulke filtresine uyan proxy'leri bulur, **en dusuk ms**'liyi uygular.
Uygulamadan once calistigini dogrular; tutmazsa siradaki adayi dener.

### [2] EN HIZLI Baglan  (onerilen gunluk kullanim)
Uzak kaynak indirmez. Onbellek + `proxies_best.txt` + kendi listenizden
**tum dosyaya yayilmis 400 aday** secer; en fazla ~10 saniyede baglanir.

### [3] Proxy Avi (Hunt)
Butun havuzu tarar, en iyi `TopN` proxy'yi `proxies_best.txt`'ye ve onbellege
yazar. **100.000 proxy icin tasarlandi.** Bu islem birkac dakika surebilir.

### [4] Proxy Listesi (List)
Hicbir sistem ayarini **degistirmez**; sadece en hizli adaylari tablo halinde
listeler. Guvenli test icin bunu kullanin.

### [5] Ulke Sec
`Random` / `ALL` / `DE` / `NL` / `US` / `GB` / `FR` / `RU` / `SG` /
`DE,NL,US` gibi virgullu coklu secim veya kendiniz yazarak.
Secim `kito_settings.json`'a kaydedilir ve bir sonraki acilista hatirlanir.

### [P] Proxy Listesi Yonet
Buyuk listeyi **dosyadan toplu ekler**. Ornek: elinizde 100.000 satirlik
`buyuk_liste.txt` var:

```
[P] -> dosya yolunu yaz: C:\proxies\buyuk_liste.txt
```

Kabul edilen bicimler: `ip:port`, `ip:port:user:pass`, `http://ip:port`,
`https://user:pass@ip:port`, veya icinde `ip:port` gecen herhangi bir metin
log/kopyala-yapistir ciktisi. Tum bulunanlar tekrarsiz olarak `proxies.txt`'e
yazilir ve toplam sayi gosterilir. Isterseniz eski test sonuclarinin
onbellegini de temizleyebilirsiniz.

## Neden artik takilmiyor?

Eski surumde her proxy icin ayri bir PowerShell runspace yaratiliyordu ve
"tum isler bitene kadar bekle" dongusunun **son tarihi (deadline) yoktu**:
tek bir proxy yanit vermezse animasyon sonsuza kadar donuyordu
(sikayet ettiginiz "http veya tcp taramasi bir yerde duruyor" hatasi).

Yeni motor (`KitoCore.ps1`) taramayi **C# icinde gercek is parcaciklari
(thread)** ile yapar:

* Sabit worker sayisi + `ConcurrentQueue` -> 100.000 proxy'ye olceklenir.
* TCP: `BeginConnect` + `WaitOne(timeout)` -> her hedef icin kesin zaman asimi.
* HTTP: `BeginGetResponse` + `WaitOne(timeout)` + `Abort()` ->
  `.NET`'in uygulamadigi durumlarda bile **sert** zaman asimi.
* Her asamanin ayrica bir "guvenlik siniri" (hard cap) vardir.
* Ilerleme `[Kito]::Done` / `[Kito]::Total` uzerinden canli bar olarak cizilir.

### Olculen sonuclar (bu makinede)

| Test                                       | Sonuc                          |
|--------------------------------------------|--------------------------------|
| 300 kara delik hedef, 800 ms timeout       | **3,0 s** (takilma yok)        |
| 20 gercek proxy, TCP on filtre             | **2,7 s** (9 canli)            |
| 11 canli proxy, HTTP/HTTPS dogrulama       | **8,2 s**                      |
| 10.256 aday: TCP + HTTP tam tarama          | 1378 canli -> 55 hizli HTTPS-OK, en hizli **427 ms** |
| Hizli baglan (Fast)                         | **~7 s** tarama (acilis dahil 12 s) |

> Not: ayni HTTP asamasinin duzeltme **oncesi** hali tek bir proxy yuzunden
> 91 saniye takili kaliyordu. Artik en kotu durumda bile zaman asimi devreye
> girip devam ediyor.

## Komut satiri kullanimi

Menuye gerek kalmadan dogrudan da cagirabilirsiniz:

```powershell
# En iyi listeyi yenile (100k havuzu tarar)
.\KitoVPN.ps1 -Mode Hunt -Country ALL -TopN 100

# Sadece listele, sistem ayarini degistirme
.\KitoVPN.ps1 -Mode List -Country DE

# En hizli baglan
.\KitoVPN.ps1 -Mode Fast -Country Random

# Uygulanacak adayi goster ama UYGULAMA (guvenli test)
.\KitoVPN.ps1 -Mode Foreign -Country NL -DryRun

# Farkli bir listeyi kullan
.\KitoVPN.ps1 -Mode Hunt -ListFile C:\proxies\buyuk_liste.txt
```

Onemli parametreler:

| Parametre       | Varsayilan | Aciklama                                   |
|-----------------|------------|--------------------------------------------|
| `-Mode`         | Foreign    | Foreign / Fast / Hunt / List / Status / Clear |
| `-Country`      | Random     | Random / ALL / DE / DE,NL,US               |
| `-TcpTimeoutMs` | 900        | TCP on filtre zaman asimi (ms)             |
| `-TcpWorkers`   | 768        | TCP es zamanli is parcacigi                |
| `-MaxScanTcp`   | 0          | TCP taranacak aday (0 = HEPSI)             |
| `-MaxTest`      | 3000       | HTTP test edilecek aday (0 = hepsi)        |
| `-TimeoutSec`   | 4          | HTTP zaman asimi (sn)                      |
| `-HttpWorkers`  | 256        | HTTP es zamanli is parcacigi               |
| `-MaxLatencyMs` | 900        | Bu ms ustundeki adaylar elenir             |
| `-SpeedTest`    | kapali     | Indirme hizi (KB/s) de olculsun            |
| `-DryRun`       | kapali     | Sadece sec, uygulamadan cik                |

`KitoIP.ps1` (LAN) ve `KitoWG.ps1` (WARP) parametreleri aynen korundu;
detaylar icin ilgili dosyalarin basindaki aciklamalara bakin.

## ms degerini dusurmek icin ipuclari

1. `[P]` ile elinizdeki buyuk listeyi bir kere ekleyin.
2. `[3] Proxy Avi` ile bir kere tarayip `proxies_best.txt`'yi olusturun.
3. Gunluk kullanimda `[2] EN HIZLI Baglan` kullanin (onbellekten, hizli).
4. `-MaxLatencyMs` degerini dusurun (orn. 500) -> sadece cok hizli adaylar kalir.
5. `-SpeedTest` ile KB/s da olcun; kalite siralamasi once HTTPS-OK, sonra ms,
   sonra hiz olacak sekilde yapilir.

## Onemli notlar

* Proxy uygulama **yonetici izni gerektirmez** (HKCU'ya yazilir).
  LAN IP ve WARP islemleri yonetici izni ister (UAC penceresi cikar).
* `[4] List` hicbir sey degistirmez; denemek icin en guvenli secenek budur.
* Herhangi bir islem basarisiz olursa eski proxy ayari otomatik geri yuklenir.
* Ucretsiz proxy'ler kararsizdir: birkac saat sonra oleblirler. Yeni av
  (`[3]`) yapmak normaldir.

## Geri alma

* Proxy'yi kaldir: menu `[6] Proxy Kapat`.
* WARP tunelini kapat: menu `[9]` -> `[2] Kapat`.
* LAN IP'yi DHCP'ye don: menu `[8]` -> `[5] Restore`.
* Eski surumlere donmek isterseniz: `backup\pre_unify_20260921_113646\`
  klasorundeki dosyalari ana klasore kopyalayin.
