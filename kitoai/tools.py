"""Tool adapter layer for KitoAi.

Two kinds of tools:
- builtin: pure-Python probes (HTTP fetch, headers, robots.txt, DNS).
- external: wrappers around professional tools (nmap, subfinder, httpx,
  nuclei, katana, ffuf, sqlmap, nikto). Missing binaries raise ToolMissing
  with an install hint instead of failing silently.
"""

from __future__ import annotations

import html.parser
import re
import shutil
import socket
import ssl
import subprocess
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime
from typing import Callable

from .config import settings

HTTP_TIMEOUT = 20
MAX_FETCH_BYTES = 262144  # 256 KiB


class ToolError(RuntimeError):
    pass


class ToolMissing(ToolError):
    def __init__(self, tool: str, hint: str):
        self.tool = tool
        self.hint = hint
        super().__init__(f"Tool '{tool}' is not installed. {hint}")


class ScopeViolation(ToolError):
    pass


@dataclass
class ToolResult:
    tool: str
    target: str
    output: str
    ok: bool = True
    error: str = ""
    command: str = ""
    duration_s: float = 0.0
    started_at: str = field(default_factory=lambda: datetime.utcnow().isoformat() + "Z")

    def to_dict(self) -> dict:
        return {
            "tool": self.tool,
            "target": self.target,
            "output": self.output[:12000],
            "ok": self.ok,
            "error": self.error,
            "command": self.command,
            "duration_s": round(self.duration_s, 2),
            "started_at": self.started_at,
        }


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

class _TitleParser(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self._in_title = False
        self.title: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() == "title":
            self._in_title = True

    def handle_endtag(self, tag):
        if tag.lower() == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_title:
            self.title.append(data.strip())


def _extract_title(body: bytes) -> str:
    parser = _TitleParser()
    try:
        parser.feed(body.decode("utf-8", "replace"))
    except Exception:
        return ""
    return " ".join(t for t in parser.title if t)[:200]


def _http_fetch(url: str, timeout: int = HTTP_TIMEOUT) -> tuple[int, dict, bytes]:
    req = urllib.request.Request(url, headers={"User-Agent": "KitoAi/0.1 (security assessment)"})
    ctx = ssl.create_default_context()
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        body = resp.read(MAX_FETCH_BYTES)
        return resp.status, dict(resp.headers), body


def _normalize_url(target: str, path: str = "/") -> str:
    if "://" not in target:
        target = "https://" + target
    return target.rstrip("/") + path


def _safe_host(target: str) -> str:
    m = re.match(r"^(?:https?://)?([^/:]+)", target)
    return m.group(1) if m else target


def _in_scope(candidate: str, target: str) -> bool:
    """candidate host must equal or be a subdomain of the declared target host."""
    cand = _safe_host(candidate).lower()
    tgt = _safe_host(target).lower()
    return cand == tgt or cand.endswith("." + tgt)


def _guess_techs(headers: dict) -> list[str]:
    techs: list[str] = []
    server = headers.get("Server")
    if server:
        techs.append(f"server={server}")
    for h in ("X-Powered-By", "X-AspNet-Version", "X-Generator"):
        if headers.get(h):
            techs.append(f"{h}={headers[h]}")
    via = headers.get("Via") or headers.get("X-Cache")
    if via:
        techs.append(f"via={via}")
    if headers.get("Set-Cookie"):
        techs.append(f"cookies={headers['Set-Cookie'][:80]}")
    return techs


def _run_external(cmd: list[str], timeout: int, tool_label: str) -> tuple[str, str]:
    """Run an external binary. Returns (stdout, stderr). Raises ToolMissing."""
    exe = shutil.which(cmd[0])
    if not exe:
        raise ToolMissing(cmd[0], _INSTALL_HINTS.get(cmd[0], "Install it and add it to PATH."))
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            shell=False,
        )
    except subprocess.TimeoutExpired:
        return f"[{tool_label}] timed out after {timeout}s", ""
    out = (proc.stdout or "") + (("\n[stderr]\n" + proc.stderr) if proc.stderr else "")
    return out.strip()[:20000], (proc.stderr or "")


_INSTALL_HINTS = {
    "nmap": "Kali: `sudo apt install nmap` | Windows: `choco install nmap` or https://nmap.org",
    "subfinder": "Kali: `go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest`",
    "httpx": "Kali: `go install github.com/projectdiscovery/httpx/cmd/httpx@latest`",
    "nuclei": "Kali: `go install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest`",
    "katana": "Kali: `go install github.com/projectdiscovery/katana/cmd/katana@latest`",
    "ffuf": "Kali: `sudo apt install ffuf` | Windows: `choco install ffuf`",
    "sqlmap": "Kali: `sudo apt install sqlmap` | `pip install sqlmap`",
    "nikto": "Kali: `sudo apt install nikto` | Windows: https://github.com/sullo/nikto",
}


# --------------------------------------------------------------------------
# Builtin probes
# --------------------------------------------------------------------------

def _http_probe(target: str, args: dict) -> ToolResult:
    url = _normalize_url(target, args.get("path", "/"))
    if not _in_scope(url, target):
        raise ScopeViolation(f"URL {url} is outside declared target {target}")
    try:
        status, headers, body = _http_fetch(url)
    except urllib.error.HTTPError as exc:
        status, headers = exc.code, dict(exc.headers)
        body = b""
    except (urllib.error.URLError, ssl.SSLError, OSError) as exc:
        return ToolResult("http_probe", target, "", ok=False, error=str(exc))
    title = _extract_title(body)
    lines = [
        f"[+] {url} -> HTTP {status}",
        f"    title: {title or '(none)'}",
        f"    server: {headers.get('Server', '(not disclosed)')}",
        f"    content-length: {len(body)} bytes",
        f"    technologies: {', '.join(_guess_techs(headers)) or '(none detected)'}",
    ]
    redir = headers.get("Location")
    if redir:
        lines.append(f"    redirect: {redir}")
    if args.get("show_body"):
        lines.append("    body preview: " + body.decode("utf-8", "replace")[:1500].replace("\n", " "))
    return ToolResult("http_probe", target, "\n".join(lines), command=url)


def _http_headers(target: str, args: dict) -> ToolResult:
    url = _normalize_url(target, args.get("path", "/"))
    try:
        status, headers, _ = _http_fetch(url)
    except urllib.error.HTTPError as exc:
        status, headers = exc.code, dict(exc.headers)
    except (urllib.error.URLError, ssl.SSLError, OSError) as exc:
        return ToolResult("http_headers", target, "", ok=False, error=str(exc))
    lines = [f"[+] {url} -> HTTP {status}", ""]
    for key, value in sorted(headers.items()):
        lines.append(f"    {key}: {value}")
    return ToolResult("http_headers", target, "\n".join(lines), command=url)


def _robots_scan(target: str, args: dict) -> ToolResult:
    url = _normalize_url(target, "/robots.txt")
    try:
        status, _, body = _http_fetch(url)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return ToolResult("robots_scan", target, f"[i] {url} -> 404 (no robots.txt)")
        status, body = exc.code, b""
    except (urllib.error.URLError, ssl.SSLError, OSError) as exc:
        return ToolResult("robots_scan", target, "", ok=False, error=str(exc))
    text = body.decode("utf-8", "replace")
    disallowed = re.findall(r"^Disallow:\s*(.+)$", text, re.MULTILINE)
    lines = [f"[+] {url} -> HTTP {status}", ""]
    lines.append(text[:4000])
    if disallowed:
        lines.append("")
        lines.append("[i] interesting Disallow entries:")
        for d in disallowed[:40]:
            if d.strip() and not d.strip().startswith(("/cdn", "/static", "/img", "/css", "/js", "/assets")):
                lines.append(f"    {d.strip()}")
    return ToolResult("robots_scan", target, "\n".join(lines), command=url)


def _dns_resolve(target: str, args: dict) -> ToolResult:
    host = _safe_host(target)
    try:
        infos = socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        return ToolResult("dns_resolve", target, "", ok=False, error=f"DNS resolution failed: {exc}")
    records: set[str] = set()
    for info in infos:
        records.add(f"{info[0].name} {info[4][0]}")
    out = [f"[+] DNS records for {host}:", ""]
    for rec in sorted(records):
        out.append(f"    {rec}")
    return ToolResult("dns_resolve", target, "\n".join(out))


def _quick_check(target: str, args: dict) -> ToolResult:
    """Meta probe: DNS + HTTP + headers + robots in one step."""
    parts: list[str] = []
    for subtool, subargs in (("dns_resolve", {}), ("http_probe", {}), ("http_headers", {}), ("robots_scan", {})):
        res = _DISPATCH[subtool](target, subargs)
        parts.append(f"=== {subtool} ===")
        if res.ok:
            parts.append(res.output)
        else:
            parts.append(f"(failed: {res.error})")
    return ToolResult("quick_check", target, "\n\n".join(parts))


# --------------------------------------------------------------------------
# External tool wrappers
# --------------------------------------------------------------------------

def _ports_scan(target: str, args: dict) -> ToolResult:
    host = _safe_host(target)
    ports = args.get("ports") or "-"
    timeout = int(args.get("timeout", settings.tool_timeout))
    if ports and ports != "-":
        cmd = ["nmap", "-Pn", "-sV", "-p", ports, host]
    else:
        cmd = ["nmap", "-Pn", "-sV", "--top-ports", "1000", host]
    out, _ = _run_external(cmd, timeout, "nmap")
    return ToolResult("ports_scan", target, out, command=" ".join(cmd))


def _subdomains(target: str, args: dict) -> ToolResult:
    host = _safe_host(target)
    timeout = int(args.get("timeout", settings.tool_timeout))
    cmd = ["subfinder", "-d", host, "-silent"]
    out, _ = _run_external(cmd, timeout, "subfinder")
    return ToolResult("subdomains", target, out, command=" ".join(cmd))


def _web_probe(target: str, args: dict) -> ToolResult:
    host = _safe_host(target)
    timeout = int(args.get("timeout", settings.tool_timeout))
    cmd = ["httpx", "-silent", "-title", "-tech-detect", "-status-code", "-no-color", host]
    out, _ = _run_external(cmd, timeout, "httpx")
    return ToolResult("web_probe", target, out, command=" ".join(cmd))


def _vuln_scan(target: str, args: dict) -> ToolResult:
    host = _safe_host(target)
    timeout = int(args.get("timeout", settings.tool_timeout))
    cmd = ["nuclei", "-u", f"https://{host}", "-silent", "-no-color", "-severity", "low,medium,high,critical"]
    if args.get("template"):
        cmd += ["-t", args["template"]]
    if args.get("tags"):
        cmd += ["-tags", args["tags"]]
    out, _ = _run_external(cmd, timeout, "nuclei")
    return ToolResult("vuln_scan", target, out, command=" ".join(cmd))


def _crawl(target: str, args: dict) -> ToolResult:
    host = _safe_host(target)
    timeout = int(args.get("timeout", settings.tool_timeout))
    depth = int(args.get("depth", 2))
    cmd = ["katana", "-u", f"https://{host}", "-silent", "-d", str(depth), "-jc"]
    out, _ = _run_external(cmd, timeout, "katana")
    return ToolResult("crawl", target, out, command=" ".join(cmd))


def _dir_bruteforce(target: str, args: dict) -> ToolResult:
    host = _safe_host(target)
    timeout = int(args.get("timeout", settings.tool_timeout))
    wordlist = args.get("wordlist") or "/usr/share/wordlists/dirb/common.txt"
    url = f"https://{host}/FUZZ"
    cmd = ["ffuf", "-u", url, "-w", wordlist, "-mc", "200,204,301,302,307,401,403,500", "-ac", "-t", "30"]
    out, _ = _run_external(cmd, timeout, "ffuf")
    return ToolResult("dir_bruteforce", target, out, command=" ".join(cmd))


def _sql_inject(target: str, args: dict) -> ToolResult:
    if not settings.allow_active_exploit:
        return ToolResult(
            "sql_inject",
            target,
            "",
            ok=False,
            error="Active exploitation is disabled. Set KITOAI_ALLOW_EXPLOIT=1 to enable sqlmap (authorized targets only).",
        )
    url = _normalize_url(target, args.get("path", "/"))
    if not _in_scope(url, target):
        raise ScopeViolation(f"URL {url} is outside declared target {target}")
    timeout = int(args.get("timeout", 600))
    cmd = ["sqlmap", "-u", url, "--batch", "--smart", "--level", "1", "--risk", "1"]
    if args.get("dbs"):
        cmd.append("--dbs")
    out, _ = _run_external(cmd, timeout, "sqlmap")
    return ToolResult("sql_inject", target, out, command=" ".join(cmd))


def _nikto_scan(target: str, args: dict) -> ToolResult:
    host = _safe_host(target)
    timeout = int(args.get("timeout", settings.tool_timeout))
    cmd = ["nikto", "-h", host]
    out, _ = _run_external(cmd, timeout, "nikto")
    return ToolResult("nikto_scan", target, out, command=" ".join(cmd))


# --------------------------------------------------------------------------
# Registry
# --------------------------------------------------------------------------

_DISPATCH: dict[str, Callable[[str, dict], ToolResult]] = {
    "http_probe": _http_probe,
    "http_headers": _http_headers,
    "robots_scan": _robots_scan,
    "dns_resolve": _dns_resolve,
    "quick_check": _quick_check,
    "ports_scan": _ports_scan,
    "subdomains": _subdomains,
    "web_probe": _web_probe,
    "vuln_scan": _vuln_scan,
    "crawl": _crawl,
    "dir_bruteforce": _dir_bruteforce,
    "sql_inject": _sql_inject,
    "nikto_scan": _nikto_scan,
}

_TOOL_DOCS: dict[str, dict] = {
    "http_probe": {"desc": "Fetch a URL: status, title, server, headers, tech guess.", "category": "recon"},
    "http_headers": {"desc": "Dump full HTTP response headers for a URL.", "category": "recon"},
    "robots_scan": {"desc": "Fetch robots.txt and list interesting Disallow paths.", "category": "recon"},
    "dns_resolve": {"desc": "Resolve A/AAAA records of a host.", "category": "recon"},
    "quick_check": {"desc": "Meta probe: DNS + HTTP + headers + robots in one step.", "category": "recon"},
    "ports_scan": {"desc": "nmap service/version scan (-Pn -sV, top 1000 ports).", "category": "scan"},
    "subdomains": {"desc": "subfinder passive subdomain enumeration.", "category": "recon"},
    "web_probe": {"desc": "httpx: status/title/tech detection on hosts.", "category": "web"},
    "vuln_scan": {"desc": "nuclei template-based vulnerability scan.", "category": "scan"},
    "crawl": {"desc": "katana crawler, JS-enabled, bounded depth.", "category": "web"},
    "dir_bruteforce": {"desc": "ffuf directory/content brute force (needs wordlist).", "category": "web"},
    "sql_inject": {"desc": "sqlmap automated SQLi test (active; opt-in).", "category": "exploit"},
    "nikto_scan": {"desc": "nikto web server scanner.", "category": "web"},
}


def available_tools() -> list[dict]:
    out = []
    for name, meta in _TOOL_DOCS.items():
        entry = {"name": name, **meta}
        if name in _DISPATCH and name not in ("http_probe", "http_headers", "robots_scan", "dns_resolve", "quick_check"):
            entry["installed"] = shutil.which(name) is not None
        else:
            entry["installed"] = True
        out.append(entry)
    return out


def run_tool(name: str, target: str, args: dict | None = None) -> ToolResult:
    if name not in _DISPATCH:
        raise ToolError(f"Unknown tool '{name}'. Known: {', '.join(sorted(_DISPATCH))}")
    import time

    start = time.monotonic()
    result = _DISPATCH[name](target, args or {})
    result.duration_s = round(time.monotonic() - start, 2)
    return result
