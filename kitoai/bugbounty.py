"""Bug bounty workflows: scope parsing, CVSS scoring, report generation.

Supports program scope text (HackerOne / Bugcrowd style) and generates
structured, HackerOne-style vulnerability reports.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timezone

# --------------------------------------------------------------------------
# Scope parsing
# --------------------------------------------------------------------------

OUT_SCOPE_MARKERS = re.compile(r"(?:out[- ]?of[- ]?scope|excluded|not eligible|exclusions)", re.IGNORECASE)
IN_SCOPE_MARKERS = re.compile(
    r"(?:in[- ]?scope|targets?\s*:|domains?\s*:|assets?\s*:|eligible|https?://[\w.*/-]+)",
    re.IGNORECASE | re.MULTILINE,
)
URL_RE = re.compile(r"(?:https?://)?(?:\*\.)?([a-z0-9](?:[a-z0-9.-]*[a-z0-9])?)", re.IGNORECASE)


@dataclass
class Scope:
    in_scope: list[str] = field(default_factory=list)
    out_of_scope: list[str] = field(default_factory=list)

    def allows(self, host: str) -> bool:
        """Check whether a host is inside scope and not excluded."""
        host = host.rstrip("/").lower()
        if "://" in host:
            host = host.split("://", 1)[1].split("/", 1)[0]
        for rule in self.out_of_scope:
            if _host_matches(rule, host):
                return False
        for rule in self.in_scope:
            if _host_matches(rule, host):
                return True
        return False

    def to_dict(self) -> dict:
        return {"in_scope": self.in_scope, "out_of_scope": self.out_of_scope}


def _host_matches(rule: str, host: str) -> bool:
    rule = rule.strip().lower().rstrip("/")
    if "://" in rule:
        rule = rule.split("://", 1)[1].split("/", 1)[0]
    rule = rule.removeprefix("*.")
    if not rule:
        return False
    return host == rule or host.endswith("." + rule)


def parse_scope(text: str) -> Scope:
    """Parse program scope text into a Scope object (best effort)."""
    scope = Scope()
    in_block = True
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if OUT_SCOPE_MARKERS.search(line) and len(line) < 60:
            in_block = False
            continue
        if re.search(r"(?:^\s*in[- ]?scope|^\s*targets?\s*:)", line, re.IGNORECASE):
            in_block = True
            continue
        # lines that look like asset entries
        if line.startswith(("-", "*", "•")):
            entry = line.lstrip("-*• ").strip()
            m = URL_RE.fullmatch(entry)
            if m:
                (scope.out_of_scope if not in_block else scope.in_scope).append(entry)
                continue
        if in_block and URL_RE.fullmatch(line):
            scope.in_scope.append(line)
    # dedupe
    scope.in_scope = list(dict.fromkeys(scope.in_scope))
    scope.out_of_scope = list(dict.fromkeys(scope.out_of_scope))
    return scope


# --------------------------------------------------------------------------
# CVSS v3.1 helper
# --------------------------------------------------------------------------

def cvss_vector(
    av: str = "N", ac: str = "H", pr: str = "N", ui: str = "N",
    s: str = "U", c: str = "N", i: str = "N", a: str = "N",
) -> str:
    """Build a CVSS v3.1 base vector string from metric letters."""
    return f"CVSS:3.1/AV:{av}/AC:{ac}/PR:{pr}/UI:{ui}/S:{s}/C:{c}/I:{i}/A:{a}"


def estimate_cvss(severity: str) -> tuple[float, str]:
    """Return a conservative (score, vector) pair for a severity label."""
    table = {
        "critical": (9.8, cvss_vector(av="N", ac="L", pr="N", ui="N", s="C", c="H", i="H", a="H")),
        "high": (8.1, cvss_vector(av="N", ac="L", pr="N", ui="N", s="U", c="H", i="H", a="H")),
        "medium": (5.3, cvss_vector(av="N", ac="L", pr="L", ui="N", s="U", c="L", i="L", a="L")),
        "low": (2.6, cvss_vector(av="N", ac="H", pr="N", ui="N", s="U", c="L", i="N", a="N")),
        "info": (0.0, cvss_vector()),
    }
    return table.get(severity, table["info"])


# --------------------------------------------------------------------------
# Report generation (HackerOne-style structured report)
# --------------------------------------------------------------------------

def generate_report(
    *,
    program_name: str,
    target: str,
    findings: list[dict],
    scope: Scope | None = None,
    researcher: str = "KitoAi Agent",
) -> str:
    """Generate a HackerOne-style structured vulnerability report in Markdown."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    blocks: list[str] = [
        f"# Vulnerability Report — {program_name}",
        "",
        f"**Researcher:** {researcher}",
        f"**Target:** `{target}`",
        f"**Date:** {now}",
        f"**Number of findings:** {len(findings)}",
        "",
    ]
    if scope:
        blocks.append("**Scope used:**")
        blocks.append(f"- in scope: `{', '.join(scope.in_scope) or '-'}`")
        blocks.append(f"- out of scope: `{', '.join(scope.out_of_scope) or '-'}`")
        blocks.append("")
    for i, f in enumerate(findings, 1):
        sev = f.get("severity", "info").upper()
        blocks.append(f"## {i}. [{sev}] {f.get('title', 'Untitled')}")
        blocks.append("")
        blocks.append(f"- **Asset:** `{f.get('asset', '')}`")
        blocks.append(f"- **Category:** {f.get('category', 'general')}")
        blocks.append(f"- **Severity:** {f.get('severity', 'info')} | Confidence: {f.get('confidence', 'needs-validation')}")
        if f.get("cvss_vector"):
            blocks.append(f"- **CVSS:** `{f['cvss_vector']}` (score {f.get('cvss_score')})")
        blocks.append("")
        blocks.append("### Summary")
        blocks.append("")
        blocks.append(f.get("description") or "*(description missing)*")
        blocks.append("")
        blocks.append("### Vulnerability Details")
        blocks.append("")
        blocks.append("_(Provide technical details: root cause, affected component, conditions.)_")
        blocks.append("")
        blocks.append("### Impact")
        blocks.append("")
        blocks.append("_(Describe the business and technical impact, worst-case scenario.)_")
        blocks.append("")
        blocks.append("### Reproduction Steps")
        blocks.append("")
        blocks.append("1. _(step 1)_")
        blocks.append("2. _(step 2)_")
        blocks.append("")
        if f.get("evidence"):
            blocks.append("### Evidence")
            blocks.append("")
            blocks.append("```")
            blocks.append(f.get("evidence", "")[:3000])
            blocks.append("```")
            blocks.append("")
        blocks.append("### Remediation")
        blocks.append("")
        blocks.append(f.get("remediation") or "_(remediation suggestion missing)_")
        blocks.append("")
        blocks.append("---")
        blocks.append("")
    blocks.append("_Generated by KitoAi — verify all findings manually before submission._")
    return "\n".join(blocks)
