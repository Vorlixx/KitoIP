"""Agent orchestration: plan -> execute -> analyze loop.

Two planners are available:
- LLM planner: asks the configured model to pick the next tool (JSON).
- Fallback planner: deterministic phase-based decision engine.

Both feed the same executor/analyst pipeline, so KitoAi runs with or
without an API key.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Callable

from .bugbounty import estimate_cvss, parse_scope
from .config import Session, settings
from .findings import FindingsStore, make_finding
from .llm import ChatLLM, LLMError
from .tools import ToolMissing, ToolResult, available_tools, run_tool

# --------------------------------------------------------------------------
# Phase plan (fallback planner)
# --------------------------------------------------------------------------

_PHASES: list[tuple[str, list[str]]] = [
    ("recon", ["quick_check", "subdomains", "ports_scan"]),
    ("web", ["web_probe", "http_headers", "robots_scan", "crawl", "dir_bruteforce"]),
    ("vuln", ["vuln_scan", "nikto_scan"]),
    ("exploit", ["sql_inject"]),
]


# --------------------------------------------------------------------------
# Output parsers -> findings (fallback analyst)
# --------------------------------------------------------------------------

def _parse_nmap(out: str) -> list[dict]:
    findings = []
    for line in out.splitlines():
        m = re.search(r"(\d+)/(tcp|udp)\s+open\s+(\S+)?", line)
        if m:
            port, proto, service = m.group(1), m.group(2), m.group(3) or "unknown"
            findings.append(
                make_finding(
                    title=f"Open port {port}/{proto} ({service})",
                    asset="target",
                    severity="info",
                    description=f"Port {port}/{proto} is open, service identified as '{service}'. "
                    "Verify the service is intended, patched, and exposed only where required.",
                    evidence=line.strip(),
                    remediation="Restrict exposure via firewall/security groups; keep service patched.",
                    category="attack-surface",
                    confidence="confirmed",
                )
            )
    return findings


def _parse_nuclei(out: str) -> list[dict]:
    findings = []
    for line in out.splitlines():
        m = re.search(r"\[(.*?)\]\s*\[(.*?)\]\s*\[(.*?)\]\s*(.+)", line)
        if m:
            proto, sev, name = m.group(1).strip(), m.group(2).strip().lower(), m.group(3).strip()
            detail = m.group(4).strip()
            if sev not in ("info", "low", "medium", "high", "critical"):
                continue
            score, vector = estimate_cvss(sev)
            findings.append(
                make_finding(
                    title=f"{name} ({proto})",
                    asset="target",
                    severity=sev,
                    cvss_score=score,
                    cvss_vector=vector,
                    description=f"nuclei template '{name}' matched a {sev} severity issue.",
                    evidence=detail[:600],
                    remediation="Validate the match manually, then fix the underlying weakness "
                    "(patch, config, input validation).",
                    category="vulnerability",
                    confidence="needs-validation",
                )
            )
    return findings


def _parse_headers(out: str) -> list[dict]:
    findings = []
    missing = []
    for header in (
        "strict-transport-security",
        "content-security-policy",
        "x-frame-options",
        "x-content-type-options",
        "referrer-policy",
    ):
        if f"{header}:" not in out.lower():
            missing.append(header)
    if missing:
        findings.append(
            make_finding(
                title="Missing security headers",
                asset="target",
                severity="low",
                cvss_score=2.6,
                cvss_vector=estimate_cvss("low")[1],
                description="HTTP response is missing: " + ", ".join(missing) + ". "
                "Security headers reduce XSS, clickjacking and MIME-sniffing risk.",
                evidence="headers checked: " + ", ".join(missing),
                remediation="Set HSTS, CSP, X-Frame-Options, X-Content-Type-Options and "
                "Referrer-Policy on all responses.",
                category="misconfiguration",
                confidence="confirmed",
            )
        )
    m = re.search(r"server:\s*(\S+)", out, re.IGNORECASE)
    if m and re.search(r"[/\s]?\d+\.\d+", m.group(1)):
        findings.append(
            make_finding(
                title="Web server version disclosure",
                asset="target",
                severity="info",
                description=f"The Server header discloses version: '{m.group(1)}'. "
                "Version disclosure helps attackers pick exploits.",
                evidence=m.group(0),
                remediation="Hide or obscure the Server header version component.",
                category="information-disclosure",
                confidence="confirmed",
            )
        )
    return findings


def _parse_robots(out: str) -> list[dict]:
    findings = []
    for line in out.splitlines():
        m = re.match(r"\s+(/\S+)", line)
        if not m:
            continue
        path = m.group(1)
        if re.search(r"(admin|login|config|backup|\.git|api|internal|private|db|dump|\.env|secret)", path, re.IGNORECASE):
            findings.append(
                make_finding(
                    title=f"Sensitive path disclosed in robots.txt: {path}",
                    asset="target",
                    severity="info",
                    description=f"robots.txt references '{path}'. Sensitive paths listed there "
                    "invite attackers to probe them.",
                    evidence=path,
                    remediation="Remove sensitive paths from robots.txt; protect them with access control.",
                    category="information-disclosure",
                    confidence="needs-validation",
                )
            )
    return findings


def _parse_crawl(out: str) -> list[dict]:
    findings = []
    seen = set()
    for line in out.splitlines():
        line = line.strip()
        if not line or line in seen:
            continue
        seen.add(line)
        if "?" in line and "=" in line.split("?", 1)[1]:
            findings.append(
                make_finding(
                    title=f"Endpoint with parameters: {line[:120]}",
                    asset="target",
                    severity="info",
                    description="Crawled URL exposes query parameters — potential injection "
                    "and IDOR attack surface. Test manually or with sqlmap (opt-in).",
                    evidence=line[:600],
                    remediation="Apply input validation, parameterized queries and object-level "
                    "authorization checks.",
                    category="attack-surface",
                    confidence="needs-validation",
                )
            )
    return findings


def _parse_subdomains(out: str) -> list[dict]:
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    if not lines:
        return []
    return [
        make_finding(
            title=f"Discovered {len(lines)} subdomains",
            asset="target",
            severity="info",
            description="Passive subdomain enumeration found the following hosts. "
            "Expand the attack surface assessment to these hosts within scope.",
            evidence="\n".join(lines[:80]),
            remediation="Ensure every discovered host is inventoried, patched and covered by "
            "monitoring/allowlists.",
            category="attack-surface",
            confidence="confirmed",
        )
    ]


_PARSERS = {
    "ports_scan": _parse_nmap,
    "vuln_scan": _parse_nuclei,
    "http_headers": _parse_headers,
    "robots_scan": _parse_robots,
    "crawl": _parse_crawl,
    "subdomains": _parse_subdomains,
}


# --------------------------------------------------------------------------
# Fallback planner
# --------------------------------------------------------------------------

def _fallback_plan(history: list[dict], installed: set[str]) -> dict | None:
    tried = {h["tool"] for h in history if h.get("ok", True)}
    for _phase, tools in _PHASES:
        for tool in tools:
            if tool in tried:
                continue
            if tool in ("sql_inject",) and not settings.allow_active_exploit:
                continue
            if tool in installed or tool in ("quick_check", "http_headers", "robots_scan", "dns_resolve"):
                return {"tool": tool, "args": {}, "reason": f"fallback phase '{_phase}'"}
    return None


# --------------------------------------------------------------------------
# LLM planner
# --------------------------------------------------------------------------

_PLANNER_SYSTEM = """You are the planning module of KitoAi, an automated security testing \
agent. Choose the single most valuable next tool call for the target, based on the step \
history. Rules:
- Only tools from the provided list. No others.
- Prefer quick, scoped, low-noise checks. Avoid repeating tools already executed.
- Output strictly one JSON object: {"tool": "...", "args": {...}, "reason": "..."}
- If no useful step remains, output: {"tool": "done", "args": {}, "reason": "..."}"""


# --------------------------------------------------------------------------
# LLM analyst
# --------------------------------------------------------------------------

_ANALYST_SYSTEM = """You are the analysis module of KitoAi. Convert the tool output into \
candidate findings. Output strictly a JSON array of objects with keys: title (str), \
severity (info|low|medium|high|critical), description (str), evidence (str), \
remediation (str), category (str). Only include findings clearly supported by the \
output; otherwise output []. No prose outside the JSON."""


# --------------------------------------------------------------------------
# Orchestrator
# --------------------------------------------------------------------------

@dataclass
class Step:
    decision: dict
    result: ToolResult | None = None
    findings: list[dict] = field(default_factory=list)
    note: str = ""


class Orchestrator:
    def __init__(
        self,
        target: str,
        llm: ChatLLM | None = None,
        session: Session | None = None,
        store: FindingsStore | None = None,
        progress: Callable[[str], None] | None = None,
    ):
        self.target = target
        self.llm = llm or ChatLLM()
        self.session = session or Session(target)
        self.store = store or FindingsStore(settings.findings_file)
        self.progress = progress or (lambda msg: None)
        self.steps: list[Step] = []

    # -- planning ---------------------------------------------------------

    def _next_decision(self) -> dict | None:
        history = [s.result.to_dict() for s in self.steps if s.result]
        installed = {t["name"] for t in available_tools() if t["installed"]}

        if self.llm.available:
            try:
                tools_desc = "\n".join(
                    f"- {t['name']}: {t['desc']}"
                    for t in available_tools()
                    if t["installed"] or t["name"] in ("http_probe", "http_headers", "robots_scan", "dns_resolve", "quick_check")
                )
                summary = json.dumps(
                    [{"tool": h["tool"], "ok": h["ok"], "snippet": h["output"][:300]} for h in history[-12:]],
                    ensure_ascii=False,
                )
                decision = self.llm.chat_json(
                    [
                        {"role": "system", "content": _PLANNER_SYSTEM},
                        {"role": "user", "content": f"Target: {self.target}\nAvailable tools:\n{tools_desc}\nHistory:\n{summary}\nNext step?"},
                    ]
                )
                tool = str(decision.get("tool", ""))
                if tool == "done":
                    return None
                if tool in _DISPATCH_TOOLS:
                    return {"tool": tool, "args": decision.get("args") or {}, "reason": str(decision.get("reason", ""))}
            except LLMError as exc:
                self.progress(f"[i] LLM planner unavailable ({exc}); using fallback planner.")
        return _fallback_plan(history, installed)

    # -- analysis ---------------------------------------------------------

    def _analyze(self, result: ToolResult) -> list[dict]:
        findings: list[dict] = []
        parser = _PARSERS.get(result.tool)
        if parser and result.ok and result.output:
            try:
                for f in parser(result.output):
                    f["asset"] = result.target
                    findings.append(f)
            except Exception:
                pass

        if self.llm.available and result.ok and len(result.output) > 100:
            try:
                raw = self.llm.chat_json(
                    [
                        {"role": "system", "content": _ANALYST_SYSTEM},
                        {"role": "user", "content": f"Tool: {result.tool}\nTarget: {result.target}\nOutput:\n{result.output[:6000]}"},
                    ],
                    max_tokens=1000,
                )
                items = raw if isinstance(raw, list) else ([raw] if isinstance(raw, dict) else [])
                for item in items:
                    if isinstance(item, dict) and item.get("title"):
                        sev = str(item.get("severity", "info")).lower()
                        if sev not in ("info", "low", "medium", "high", "critical"):
                            sev = "info"
                        score, vector = estimate_cvss(sev)
                        findings.append(
                            make_finding(
                                title=str(item["title"])[:200],
                                asset=result.target,
                                severity=sev,
                                cvss_score=score,
                                cvss_vector=vector,
                                description=str(item.get("description", ""))[:2000],
                                evidence=str(item.get("evidence", result.output[:600])),
                                remediation=str(item.get("remediation", ""))[:1000],
                                category=str(item.get("category", "general"))[:60],
                                confidence="needs-validation",
                            )
                        )
            except (LLMError, ValueError):
                pass
        return findings

    # -- main loop --------------------------------------------------------

    def run(self, max_steps: int | None = None) -> dict:
        max_steps = max_steps or settings.max_steps
        self.progress(f"[*] KitoAi agent started on {self.target}")
        self.progress(f"[*] LLM: {'online (' + self.llm.model + ')' if self.llm.available else 'offline (fallback planner)'}")
        for i in range(max_steps):
            decision = self._next_decision()
            if decision is None:
                self.progress("[*] No further steps — agent finished.")
                break
            tool = decision["tool"]
            self.progress(f"[step {i + 1}/{max_steps}] {tool} — {decision.get('reason', '')}")
            try:
                result = run_tool(tool, self.target, decision.get("args") or {})
            except ToolMissing as exc:
                self.progress(f"[!] {exc}")
                self.session.add_history({"tool": tool, "ok": False, "error": exc.hint})
                continue
            except Exception as exc:  # noqa: BLE001
                self.progress(f"[!] {tool} failed: {exc}")
                self.session.add_history({"tool": tool, "ok": False, "error": str(exc)})
                continue

            self.progress(f"[+] {tool} done in {result.duration_s}s ({len(result.output)} chars)")
            self.session.add_history(result.to_dict())
            if result.error:
                self.progress(f"[!] {result.error[:300]}")
            if not result.ok:
                continue

            found = self._analyze(result)
            for f in found:
                saved = self.store.add(f)
                self.progress(f"    -> finding #{saved['id']} [{saved['severity']}] {saved['title'][:80]}")
            self.steps.append(Step(decision=decision, result=result, findings=found))

        self.session.findings = self.store.all()
        self.session.save()
        counts = self.store.count_by_severity()
        self.progress(f"[*] Done. Findings: {sum(counts.values())} "
                      f"(critical={counts.get('critical', 0)}, high={counts.get('high', 0)}, "
                      f"medium={counts.get('medium', 0)}, low={counts.get('low', 0)}, info={counts.get('info', 0)})")
        return {"steps": len(self.steps), "findings": counts, "target": self.target}


_DISPATCH_TOOLS = frozenset(
    {
        "http_probe", "http_headers", "robots_scan", "dns_resolve", "quick_check",
        "ports_scan", "subdomains", "web_probe", "vuln_scan", "crawl",
        "dir_bruteforce", "sql_inject", "nikto_scan",
    }
)
