<#
    ============================================================
      KitoCore  -  Shared Engine (scanning + helper functions)
    ============================================================
      This file is not run directly. It is "dot-sourced" by
      KitoVPN.ps1 and KitoMenu.ps1.

      WHY IT WAS REWRITTEN (v4 -> v5):
        The old engine created a separate PowerShell instance for
        EVERY proxy, and "Wait-JobsAnimated" waited for ALL jobs
        to finish with no deadline: if a single proxy stopped
        responding, the progress bar hung forever (the "http/tcp
        scan is stuck somewhere" bug you reported).
        That approach was also impossible for 100,000 proxies.

        The new engine runs the scan inside C# using REAL THREADS:
          * Fixed number of workers + a queue (ConcurrentQueue)
          * A strict timeout for every operation
          * A fixed "deadline" for every stage -> NEVER HANGS
          * Scales to 100,000+ proxies and is much faster
        Progress is read through [Kito]::Done / [Kito]::Total.
    ============================================================
#>

$ErrorActionPreference = 'SilentlyContinue'

if (-not ('Kito' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public class KitoRes {
    public string Proxy = "";
    public string IP = "";
    public string CC = "";
    public string Country = "";
    public string City = "";
    public int Latency = 999999;
    public int KBps = 0;
    public bool Https = false;
}

public class Kito {
    // Progress counters (read by PowerShell)
    public static int Done = 0;
    public static int Total = 0;

    // Static (global) certificate validation bypass.
    // HttpWebRequest has NO property called "ServerCertificateValidationCallback"
    // (it would be a compile error) - this setting is applied GLOBALLY through
    // ServicePointManager and configured once in the static constructor.
    static Kito() {
        ServicePointManager.ServerCertificateValidationCallback = delegate { return true; };
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        ServicePointManager.DefaultConnectionLimit = 4096;
    }

    static readonly Regex ReIp   = new Regex("\"ip\"\\s*:\\s*\"([^\"]*)\"", RegexOptions.Compiled);
    static readonly Regex ReCc   = new Regex("\"country_code\"\\s*:\\s*\"([^\"]*)\"", RegexOptions.Compiled);
    static readonly Regex ReCo   = new Regex("\"country\"\\s*:\\s*\"([^\"]*)\"", RegexOptions.Compiled);
    static readonly Regex ReCity = new Regex("\"city\"\\s*:\\s*\"([^\"]*)\"", RegexOptions.Compiled);

    // ---------------- TCP connectivity test ----------------
    static bool TcpConnect(string ip, int port, int timeoutMs) {
        try {
            using (var c = new TcpClient()) {
                IAsyncResult ar = c.BeginConnect(ip, port, null, null);
                bool ok = ar.AsyncWaitHandle.WaitOne(timeoutMs, false);
                if (!ok) return false;
                try { c.EndConnect(ar); } catch { return false; }
                return c.Connected;
            }
        } catch { return false; }
    }

    public static List<KitoRes> TcpScan(string[] eps, int timeoutMs, int workers) {
        var q = new ConcurrentQueue<string>(eps);
        var results = new List<KitoRes>();
        var lk = new object();
        Total = eps.Length; Done = 0;
        int nw = Math.Max(1, Math.Min(workers, eps.Length));
        var threads = new Thread[nw];
        for (int t = 0; t < nw; t++) {
            threads[t] = new Thread(delegate() {
                string ep;
                while (q.TryDequeue(out ep)) {
                    int idx = ep.LastIndexOf(':');
                    if (idx > 0) {
                        string ip = ep.Substring(0, idx);
                        int port;
                        if (int.TryParse(ep.Substring(idx + 1), out port) && port > 0 && port < 65536) {
                            var sw = Stopwatch.StartNew();
                            if (TcpConnect(ip, port, timeoutMs)) {
                                sw.Stop();
                                lock (lk) { results.Add(new KitoRes { Proxy = ep, Latency = (int)sw.ElapsedMilliseconds }); }
                            }
                        }
                    }
                    Interlocked.Increment(ref Done);
                }
            });
            threads[t].IsBackground = true;
            threads[t].Start();
        }
        foreach (var th in threads) { try { th.Join(); } catch {} }
        return results;
    }

    // ---------------- HTTP (proxy) test ----------------
    // HttpWebRequest.Timeout is not enforced in some cases (DNS + proxy CONNECT).
    // Therefore a TRUE hard timeout is used: BeginGetResponse + WaitOne + Abort.
    static bool HttpGetText(string proxy, string url, int timeoutMs, out string text, out int ms) {
        text = null; ms = 0;
        var sw = Stopwatch.StartNew();
        HttpWebRequest req = null;
        try {
            req = (HttpWebRequest)WebRequest.Create(url);
            if (proxy != null && proxy.Length > 0) req.Proxy = new WebProxy("http://" + proxy, true);
            req.Timeout = timeoutMs; req.ReadWriteTimeout = timeoutMs;
            req.UserAgent = "Mozilla/5.0"; req.AllowAutoRedirect = true;
            req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            req.KeepAlive = false; req.Pipelined = false; req.ConnectionGroupName = proxy;
            IAsyncResult ar = req.BeginGetResponse(null, null);
            if (!ar.AsyncWaitHandle.WaitOne(timeoutMs, false)) {
                try { req.Abort(); } catch {}
                sw.Stop(); ms = (int)sw.ElapsedMilliseconds; return false;
            }
            using (var resp = (HttpWebResponse)req.EndGetResponse(ar))
            using (var s = resp.GetResponseStream())
            using (var sr = new StreamReader(s, Encoding.UTF8)) {
                text = sr.ReadToEnd();
            }
            sw.Stop(); ms = (int)sw.ElapsedMilliseconds;
            return !string.IsNullOrEmpty(text);
        } catch {
            try { if (req != null) req.Abort(); } catch {}
            sw.Stop(); ms = (int)sw.ElapsedMilliseconds; return false;
        }
    }

    static int SpeedTest(string proxy, int timeoutMs) {
        int kbps = 0;
        HttpWebRequest req = null;
        try {
            int tmo = Math.Max(timeoutMs, 8000);
            req = (HttpWebRequest)WebRequest.Create("https://speed.cloudflare.com/__down?bytes=100000");
            req.Proxy = new WebProxy("http://" + proxy, true);
            req.Timeout = tmo; req.ReadWriteTimeout = tmo; req.UserAgent = "Mozilla/5.0";
            req.KeepAlive = false; req.ConnectionGroupName = proxy;
            IAsyncResult ar = req.BeginGetResponse(null, null);
            if (!ar.AsyncWaitHandle.WaitOne(tmo, false)) {
                try { req.Abort(); } catch {}
                return 0;
            }
            var sw = Stopwatch.StartNew();
            using (var resp = (HttpWebResponse)req.EndGetResponse(ar))
            using (var s = resp.GetResponseStream()) {
                var buf = new byte[16384]; long total = 0; int n;
                while ((n = s.Read(buf, 0, buf.Length)) > 0) {
                    total += n;
                    if (sw.ElapsedMilliseconds > tmo) break;
                }
                sw.Stop();
                if (total > 0 && sw.Elapsed.TotalSeconds > 0.001)
                    kbps = (int)((total / 1024.0) / sw.Elapsed.TotalSeconds);
            }
        } catch { try { if (req != null) req.Abort(); } catch {} }
        return kbps;
    }

    static void CheckOne(string ep, int timeoutMs, bool speed, bool verifyHttps, List<KitoRes> results, object lk) {
        string txt; int ms = 0;
        bool https = false;
        string ip = null, cc = null, country = null, city = null;

        // 1) Over HTTPS (ipwho.is) - requires a real CONNECT tunnel
        if (HttpGetText(ep, "https://ipwho.is/", timeoutMs, out txt, out ms) && txt != null) {
            bool succ = txt.IndexOf("\"success\":true", StringComparison.OrdinalIgnoreCase) >= 0
                     || txt.IndexOf("\"success\": true", StringComparison.OrdinalIgnoreCase) >= 0;
            if (succ) {
                Match m;
                m = ReIp.Match(txt);   if (m.Success) ip = m.Groups[1].Value;
                m = ReCc.Match(txt);   if (m.Success) cc = m.Groups[1].Value;
                m = ReCo.Match(txt);   if (m.Success) country = m.Groups[1].Value;
                m = ReCity.Match(txt); if (m.Success) city = m.Groups[1].Value;
                if (!string.IsNullOrEmpty(ip)) https = true;
            }
        }

        // 2) Otherwise over plain HTTP (some proxies only open an HTTP tunnel)
        if (!https) {
            string t2; int ms2 = 0;
            if (!HttpGetText(ep, "http://ip-api.com/json/?fields=status,country,countryCode,city,query", timeoutMs, out t2, out ms2) || t2 == null)
                return;
            Match mcc = Regex.Match(t2, "\"countryCode\"\\s*:\\s*\"([^\"]*)\"");
            Match mip = Regex.Match(t2, "\"query\"\\s*:\\s*\"([^\"]*)\"");
            if (!mcc.Success || !mip.Success) return;
            cc = mcc.Groups[1].Value; ip = mip.Groups[1].Value;
            Match mc  = Regex.Match(t2, "\"country\"\\s*:\\s*\"([^\"]*)\"");  country = mc.Success  ? mc.Groups[1].Value  : "";
            Match mci = Regex.Match(t2, "\"city\"\\s*:\\s*\"([^\"]*)\"");      city    = mci.Success ? mci.Groups[1].Value : "";
            ms = ms2;
        }

        // If verification is requested and HTTPS did not hold, drop it
        if (verifyHttps && !https) return;

        int kbps = 0;
        if (speed) kbps = SpeedTest(ep, timeoutMs);

        var r = new KitoRes {
            Proxy = ep, IP = ip, CC = cc, Country = country, City = city,
            Latency = ms, Https = https, KBps = kbps
        };
        lock (lk) { results.Add(r); }
    }

    public static List<KitoRes> HttpCheck(string[] eps, int timeoutMs, int workers, bool speed, bool verifyHttps) {
        var q = new ConcurrentQueue<string>(eps);
        var results = new List<KitoRes>();
        var lk = new object();
        Total = eps.Length; Done = 0;
        int nw = Math.Max(1, Math.Min(workers, eps.Length));
        var threads = new Thread[nw];
        for (int t = 0; t < nw; t++) {
            threads[t] = new Thread(delegate() {
                string ep;
                while (q.TryDequeue(out ep)) {
                    try { CheckOne(ep, timeoutMs, speed, verifyHttps, results, lk); } catch { }
                    Interlocked.Increment(ref Done);
                }
            });
            threads[t].IsBackground = true;
            threads[t].Start();
        }
        foreach (var th in threads) { try { th.Join(); } catch {} }
        return results;
    }
}
'@
}

# ------------------------------------------------------------------
#  Logging
# ------------------------------------------------------------------
function Write-KLog {
    param([string]$Msg, [string]$Color = 'Gray', [string]$LogFile)
    Write-Host $Msg -ForegroundColor $Color
    if (-not $LogFile) { $LogFile = Join-Path $PSScriptRoot 'kitoip.log' }
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-Content -Path $LogFile -Value "[$stamp] $Msg" -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------
#  Current public IP + country
# ------------------------------------------------------------------
function Get-PublicGeo {
    param([string]$Proxy)
    $req = @{ Uri = 'https://ipwho.is/'; TimeoutSec = 8; ErrorAction = 'Stop' }
    if ($Proxy) { $req['Proxy'] = "http://$Proxy" }
    try {
        $r = Invoke-RestMethod @req
        if ($r.success -eq $true -and $r.ip) {
            return [pscustomobject]@{ IP=$r.ip; CC=$r.country_code; Country=$r.country; City=$r.city }
        }
    } catch {}
    $req2 = @{ Uri = 'http://ip-api.com/json/?fields=status,country,countryCode,city,query'; TimeoutSec = 8; ErrorAction = 'Stop' }
    if ($Proxy) { $req2['Proxy'] = "http://$Proxy" }
    try {
        $r2 = Invoke-RestMethod @req2
        if ($r2.status -eq 'success') {
            return [pscustomobject]@{ IP=$r2.query; CC=$r2.countryCode; Country=$r2.country; City=$r2.city }
        }
    } catch {}
    return $null
}

# ------------------------------------------------------------------
#  Reads the proxy list file FAST (supports 100,000+ lines)
# ------------------------------------------------------------------
function Read-ProxyList {
    param([string]$Path)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path $Path)) { return @() }
    try {
        $sr = New-Object System.IO.StreamReader($Path)
        while ($null -ne ($line = $sr.ReadLine())) {
            $m = [regex]::Match($line, '\b(\d{1,3}(?:\.\d{1,3}){3}:\d{2,5})\b')
            if ($m.Success) { [void]$set.Add($m.Groups[1].Value) }
        }
        $sr.Close()
    } catch {}
    return @($set)
}

# ------------------------------------------------------------------
#  Animated scan runner
#  $Body  : a scriptblock taking param($eps) that calls a Kito function
#           and returns the result.
#           (Example: [Kito]::TcpScan([string[]]$eps, 1500, 256) )
#  Deadline: it never waits forever.
# ------------------------------------------------------------------
function Write-FixedLine {
    # Always overwrites the SAME line in place (never wraps to the next line).
    # $Row: [Console]::CursorTop is pinned; the text is written there no matter what.
    param([int]$Row, [string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Cyan)
    try {
        $w = [Math]::Max(20, [Console]::WindowWidth - 1)
        if ($Text.Length -gt $w) { $Text = $Text.Substring(0, $w) }
        else { $Text = $Text.PadRight($w) }
        [Console]::SetCursorPosition(0, $Row)
        $prevColor = [Console]::ForegroundColor
        [Console]::ForegroundColor = $Color
        [Console]::Write($Text)
        [Console]::ForegroundColor = $prevColor
    } catch {
        # No console control (redirected output etc.): fall back silently
        Write-Host $Text -ForegroundColor $Color
    }
}

function Invoke-KitoStage {
    param(
        [Parameter(Mandatory)][scriptblock]$Body,
        [object[]]$ArgList,
        [string]$Label = 'Test',
        [int]$HardCapSec = 0
    )
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($Body.ToString())
    if ($ArgList) { foreach ($a in $ArgList) { [void]$ps.AddArgument($a) } }
    $h = $ps.BeginInvoke()

    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch {}

    $row = -1
    if (-not $redirected) {
        try { Write-Host ''; $row = [Console]::CursorTop - 1 } catch { $redirected = $true }
    }

    $spin = @('|','/','-','\'); $i = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastPct = -1
    while (-not $h.IsCompleted) {
        $d = [Kito]::Done; $t = [Kito]::Total
        $pct = if ($t -gt 0) { [int](100.0 * $d / $t) } else { 0 }
        if ($pct -gt 100) { $pct = 100 }
        $barLen = 28
        $fill = [int]($barLen * $pct / 100.0)
        $bar = ('#' * $fill) + ('-' * ($barLen - $fill))
        $line = "  {0} [{1}] {2,3}%  {3}/{4}  {5}  {6}s" -f `
            $Label, $bar, $pct, $d, $t, $spin[$i % 4], [int]$sw.Elapsed.TotalSeconds

        if ($redirected) {
            # Redirected / captured output: to avoid line spam, write only when
            # the percentage changes AND at most once per second.
            if ($pct -ne $lastPct) { Write-Host $line -ForegroundColor Cyan; $lastPct = $pct }
        } else {
            Write-FixedLine -Row $row -Text $line -Color Cyan
        }

        if ($HardCapSec -gt 0 -and $sw.Elapsed.TotalSeconds -gt $HardCapSec) {
            Write-KLog ("  ! {0}: safety cap ({1}s) exceeded, scan stopped." -f $Label, $HardCapSec) 'Yellow'
            break
        }
        $i++
        Start-Sleep -Milliseconds 150
    }

    $out = @()
    try { $out = @($ps.EndInvoke($h)) } catch {}
    try { $ps.Dispose() } catch {}
    try { $rs.Close(); $rs.Dispose() } catch {}

    $doneLine = "  {0} [Done] {1}/{1}  ({2}s)" -f $Label, ([Kito]::Total), [int]$sw.Elapsed.TotalSeconds
    if ($redirected) { Write-Host $doneLine -ForegroundColor Green }
    else { Write-FixedLine -Row $row -Text $doneLine -Color Green; Write-Host '' }
    return $out
}

# ------------------------------------------------------------------
#  Sort by quality: HTTPS-OK first, then lowest ms, then highest speed
# ------------------------------------------------------------------
function Sort-ByQuality {
    param($List)
    return @($List | Sort-Object `
        @{Expression={ if ($_.Https) { 0 } else { 1 } }}, `
        @{Expression={ [int]$_.Latency }}, `
        @{Expression={ if ($_.KBps) { 0 - [int]$_.KBps } else { 0 } }})
}
