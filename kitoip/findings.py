"""Findings store: severity scoring, deduplication, JSON/Markdown export."""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SEVERITY_ORDER = {"critical": 4, "high": 3, "medium": 2, "low": 1, "info": 0}


def severity_label(score: float | None) -> str:
    """Map a CVSS base score to a severity label (CVSS v3.1 bands)."""
    if score is None:
        return "unrated"
    if score >= 9.0:
        return "critical"
    if score >= 7.0:
        return "high"
    if score >= 4.0:
        return "medium"
    if score > 0.0:
        return "low"
    return "info"


def make_finding(
    *,
    title: str,
    asset: str,
    severity: str = "info",
    cvss_score: float | None = None,
    cvss_vector: str = "",
    description: str = "",
    evidence: str = "",
    remediation: str = "",
    references: list[str] | None = None,
    category: str = "general",
    confidence: str = "needs-validation",
) -> dict[str, Any]:
    """Create a finding dict with normalized fields."""
    if cvss_score is not None and severity == "unrated":
        severity = severity_label(cvss_score)
    severity = severity.lower()
    if severity not in SEVERITY_ORDER:
        severity = "info"
    return {
        "id": None,  # assigned by store
        "title": title,
        "asset": asset,
        "severity": severity,
        "cvss_score": cvss_score,
        "cvss_vector": cvss_vector,
        "category": category,
        "description": description,
        "evidence": evidence[:6000],
        "remediation": remediation,
        "references": references or [],
        "confidence": confidence,
        "status": "open",
        "created_at": datetime.now(timezone.utc).isoformat(),
    }


class FindingsStore:
    def __init__(self, path: Path | None = None):
        self.path = path or Path("findings.json")
        self._findings: list[dict] = []
        if self.path.exists():
            try:
                self._findings = json.loads(self.path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                self._findings = []

    def add(self, finding: dict, dedupe_key: str | None = None) -> dict:
        """Add a finding; deduplicates on title+asset by default."""
        key = dedupe_key or f"{finding['title'].lower()}|{finding['asset'].lower()}"
        for existing in self._findings:
            if existing.get("_dedupe") == key and existing.get("status") == "open":
                existing["evidence"] += "\n---\n" + finding.get("evidence", "")
                return existing
        finding["id"] = len(self._findings) + 1
        finding["_dedupe"] = key
        self._findings.append(finding)
        self.save()
        return finding

    def all(self) -> list[dict]:
        return sorted(self._findings, key=lambda f: SEVERITY_ORDER.get(f["severity"], -1), reverse=True)

    def count_by_severity(self) -> dict[str, int]:
        counts = {k: 0 for k in SEVERITY_ORDER}
        for f in self._findings:
            counts[f["severity"]] = counts.get(f["severity"], 0) + 1
        return counts

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self._findings, indent=2, ensure_ascii=False), encoding="utf-8")

    def to_markdown(self) -> str:
        lines = ["# Findings", ""]
        counts = self.count_by_severity()
        lines.append(
            "| severity | count |\n|---|---|\n"
            + "\n".join(f"| {k} | {v} |" for k, v in counts.items() if v)
        )
        lines.append("")
        for f in self.all():
            lines.append(f"## [{f['severity'].upper()}] {f['title']}  ")
            lines.append(f"- asset: `{f['asset']}`")
            lines.append(f"- category: {f['category']} | confidence: {f['confidence']}")
            if f.get("cvss_vector"):
                lines.append(f"- cvss: {f['cvss_vector']} ({f['cvss_score']})")
            if f.get("description"):
                lines.append(f"- description: {f['description']}")
            if f.get("evidence"):
                lines.append(f"- evidence: ```{f['evidence'][:1200]}```")
            if f.get("remediation"):
                lines.append(f"- remediation: {f['remediation']}")
            lines.append("")
        return "\n".join(lines)
