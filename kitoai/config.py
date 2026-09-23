"""KitoAi configuration: environment, LLM settings, session state."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

APP_NAME = "KitoAi"
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = Path(os.environ.get("KITOAI_DATA_DIR", PROJECT_ROOT / "data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)


@dataclass
class Settings:
    """Runtime settings, overridable through environment variables."""

    # LLM (any OpenAI-compatible endpoint works: OpenAI, OpenRouter, Ollama, ...)
    llm_base_url: str = field(
        default_factory=lambda: os.environ.get("KITOAI_LLM_BASE", "https://api.openai.com/v1")
    )
    llm_api_key: str = field(
        default_factory=lambda: os.environ.get("KITOAI_LLM_KEY", "")
    )
    llm_model: str = field(
        default_factory=lambda: os.environ.get("KITOAI_LLM_MODEL", "gpt-4o-mini")
    )
    llm_timeout: int = int(os.environ.get("KITOAI_LLM_TIMEOUT", "90"))

    # Execution safety
    max_steps: int = int(os.environ.get("KITOAI_MAX_STEPS", "25"))
    tool_timeout: int = int(os.environ.get("KITOAI_TOOL_TIMEOUT", "300"))
    confirm_destructive: bool = os.environ.get("KITOAI_CONFIRM_DESTRUCTIVE", "1") == "1"
    allow_active_exploit: bool = os.environ.get("KITOAI_ALLOW_EXPLOIT", "0") == "1"
    max_concurrent: int = int(os.environ.get("KITOAI_MAX_CONCURRENT", "3"))

    # Web dashboard
    web_host: str = os.environ.get("KITOAI_WEB_HOST", "127.0.0.1")
    web_port: int = int(os.environ.get("KITOAI_WEB_PORT", "8666"))

    # Persistence
    findings_file: Path = DATA_DIR / "findings.json"
    notes_file: Path = DATA_DIR / "notes.json"
    sessions_dir: Path = DATA_DIR / "sessions"

    def __post_init__(self) -> None:
        self.sessions_dir.mkdir(parents=True, exist_ok=True)


settings = Settings()


class Session:
    """Per-target working session: scope, findings, notes, history."""

    def __init__(self, target: str, scope_file: Path | None = None):
        self.target = target.rstrip("/")
        self.scope_file = scope_file
        self.created_at = None
        self.history: list[dict] = []
        self.findings: list[dict] = []
        self.notes: list[dict] = []
        self._dir = settings.sessions_dir / self._slug(self.target)
        self._dir.mkdir(parents=True, exist_ok=True)
        self._load()

    @staticmethod
    def _slug(target: str) -> str:
        clean = "".join(c if c.isalnum() or c in ".-_" else "_" for c in target)
        return clean[:64] or "target"

    def _paths(self) -> dict[str, Path]:
        return {
            "findings": self._dir / "findings.json",
            "notes": self._dir / "notes.json",
            "history": self._dir / "history.json",
            "evidence": self._dir / "evidence",
        }

    def _load(self) -> None:
        paths = self._paths()
        paths["evidence"].mkdir(exist_ok=True)
        for key, path in paths.items():
            if key == "evidence":
                continue
            if path.exists():
                try:
                    setattr(self, key, json.loads(path.read_text(encoding="utf-8")))
                except (json.JSONDecodeError, OSError):
                    setattr(self, key, [])
        try:
            self.created_at = os.path.getmtime(self._dir)
        except OSError:
            self.created_at = None

    def save(self) -> None:
        for key in ("findings", "notes", "history"):
            (self._dir / f"{key}.json").write_text(
                json.dumps(getattr(self, key), indent=2, ensure_ascii=False), encoding="utf-8"
            )

    def add_history(self, entry: dict) -> None:
        self.history.append(entry)
        self.save()

    def add_note(self, title: str, content: str, category: str = "general") -> dict:
        note = {"title": title, "content": content, "category": category, "id": len(self.notes) + 1}
        self.notes.append(note)
        self.save()
        return note

    def save_evidence(self, name: str, content: str) -> Path:
        path = self._paths()["evidence"] / f"{self._slug(name)}.txt"
        path.write_text(content, encoding="utf-8")
        return path

    def summarize(self) -> dict:
        return {
            "target": self.target,
            "history_len": len(self.history),
            "findings": len(self.findings),
            "notes": len(self.notes),
            "dir": str(self._dir),
        }
