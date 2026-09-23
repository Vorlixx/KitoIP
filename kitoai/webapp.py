"""KitoAi web dashboard: FastAPI backend with async task queue.

Run:  python -m kitoai.webapp   (or: python run.py --web)
"""

from __future__ import annotations

import re
import threading
import uuid
from pathlib import Path

from . import __app_name__, __version__
from .agents import Orchestrator
from .config import PROJECT_ROOT, Session, settings
from .findings import FindingsStore
from .llm import ChatLLM
from .tools import available_tools, run_tool

try:
    from fastapi import FastAPI, HTTPException
    from fastapi.responses import FileResponse, JSONResponse
    from fastapi.staticfiles import StaticFiles
    from pydantic import BaseModel
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "Web dashboard dependencies missing. Install them with: pip install -r requirements.txt"
    ) from exc

app = FastAPI(title=f"{__app_name__} Dashboard", version=__version__)
WEB_DIR = PROJECT_ROOT / "web"
app.mount("/static", StaticFiles(directory=str(WEB_DIR)), name="static")

# --------------------------------------------------------------------------
# Task manager
# --------------------------------------------------------------------------

_tasks: dict[str, dict] = {}
_tasks_lock = threading.Lock()


class _Buffer:
    def __init__(self) -> None:
        self.lines: list[str] = []
        self.lock = threading.Lock()

    def write(self, msg: str) -> None:
        with self.lock:
            self.lines.append(msg)

    def text(self) -> str:
        with self.lock:
            return "\n".join(self.lines)


def _start_task(action: str, target: str) -> str:
    task_id = uuid.uuid4().hex[:12]
    buf = _Buffer()

    def worker() -> None:
        try:
            session = Session(target)
            store = FindingsStore(session._dir / "findings.json")
            if action == "run":
                orch = Orchestrator(target, session=session, store=store, progress=buf.write)
                result = orch.run()
                buf.write("\n[task complete] " + str(result))
            elif action == "probe":
                res = run_tool("http_probe", target, {"show_body": True})
                buf.write(res.output if res.ok else f"error: {res.error}")
        except Exception as exc:  # noqa: BLE001
            buf.write(f"[task failed] {exc}")
        with _tasks_lock:
            _tasks[task_id]["done"] = True

    with _tasks_lock:
        _tasks[task_id] = {"id": task_id, "action": action, "target": target, "done": False, "output": buf}
    threading.Thread(target=worker, daemon=True).start()
    return task_id


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------

class ChatIn(BaseModel):
    message: str


class TargetIn(BaseModel):
    target: str


@app.get("/")
def index() -> FileResponse:
    return FileResponse(str(WEB_DIR / "index.html"))


@app.get("/api/status")
def status() -> dict:
    llm = ChatLLM()
    return {
        "app": __app_name__,
        "version": __version__,
        "llm": {"available": llm.available, "model": llm.model},
        "tools": available_tools(),
        "settings": {
            "exploit": settings.allow_active_exploit,
            "max_steps": settings.max_steps,
            "confirm_destructive": settings.confirm_destructive,
        },
    }


@app.post("/api/target")
def set_target(body: TargetIn) -> dict:
    target = body.target.strip().rstrip("/")
    if not target:
        raise HTTPException(status_code=400, detail="empty target")
    return {"target": target, "note": "Target accepted. Authorized testing only."}


_GREETINGS = (
    "merhaba", "hello", "hi", "selam", "hey", "slm", "good morning", "iyi günler",
    "nasılsın", "nasilsin", "how are you", "naber",
)
_SCAN_WORDS = ("tara", "scan", "run", "test et", "teste", "kontrol et", "kontrol", "check", "ara", "sız")


# noqa: E302
def _find_domain(text: str) -> str | None:
    """Extract a plausible domain/host from free text (best effort).

    Requires a URL scheme or at least one dot (e.g. example.com, 127.0.0.1:8899)
    so plain words like 'bu' or 'merhaba' are never treated as targets.
    """
    m = re.search(r"https?://([^\s/]+)", text, re.IGNORECASE)
    if m:
        return m.group(1).rstrip("/")
    m = re.search(r"\b(?:[a-z0-9-]+\.)+[a-z0-9-]+(?::\d{1,5})?\b", text, re.IGNORECASE)
    if m:
        cand = m.group(0)
        if cand.lower() not in ("help", "status", "target", "run", "findings", "report", "probe", "tools"):
            return cand
    return None


@app.post("/api/chat")
def chat(body: ChatIn) -> dict:
    msg = body.message.strip()
    if not msg:
        raise HTTPException(status_code=400, detail="empty message")
    lower = msg.lower()
    parts = msg.split(maxsplit=1)
    cmd = parts[0].lower()
    arg = parts[1].strip() if len(parts) > 1 else ""

    # --- natural language handling ---------------------------------------
    if any(g in lower for g in _GREETINGS):
        return {
            "message": (
                "Merhaba! Ben KitoAi, AI destekli güvenlik test asistanı.\n\n"
                "Komutlar:\n"
                "  target <alan-adı>    hedef belirle (ör. target example.com)\n"
                "  run <alan-adı>       otomatik tarama başlat (ör. run example.com)\n"
                "  findings <alan>      kayıtlı bulguları listele\n"
                "  report <alan>        HackerOne-tarzı rapor üret\n"
                "  status               sistem durumu\n"
                "  help                 yardım"
            )
        }
    domain = _find_domain(msg)
    if cmd not in ("run", "probe", "target", "findings", "report", "status", "help", "tools", "notes") and domain:
        if any(w in lower for w in _SCAN_WORDS):
            task_id = _start_task("run", domain)
            return {"task": task_id, "message": f"'{domain}' üzerinde tarama başlatıldı."}
        return {
            "message": (
                f"Hedef olarak '{domain}' algıladım. Ne yapmamı istersin?\n"
                f"  run {domain}          -> otomatik tarama\n"
                f"  probe {domain}        -> hızlı HTTP kontrolü\n"
                f"  findings {domain}     -> kayıtlı bulgular\n"
                f"  report {domain}       -> rapor"
            )
        }
    if cmd not in ("run", "probe", "target", "findings", "report", "status", "help", "tools", "notes"):
        return {
            "message": (
                "Bu komutu tanımadım ama sana yardımcı olabilirim. Şunları dene:\n"
                "  target example.com  — hedef belirle\n"
                "  run example.com     — otomatik tarama başlat\n"
                "  findings example.com— bulguları listele\n"
                "  report example.com  — rapor üret\n"
                "  status | help       — durum / yardım"
            )
        }

    if cmd == "run" and arg:
        task_id = _start_task("run", arg)
        return {"task": task_id, "message": f"Agent started on {arg}"}
    if cmd == "probe" and arg:
        task_id = _start_task("probe", arg)
        return {"task": task_id, "message": f"Probing {arg}"}
    if cmd == "target":
        if not arg:
            raise HTTPException(status_code=400, detail="usage: target <domain|url>")
        return {"message": f"Target locked: {arg.rstrip('/')}"}
    if cmd in ("help",):
        return {"message": "Commands: target <domain>, run <domain>, probe <url>, findings <domain>, report <domain>, status"}
    if cmd == "findings" and arg:
        session = Session(arg)
        store = FindingsStore(session._dir / "findings.json")
        findings = store.all()
        if not findings:
            return {"message": f"No findings stored for {arg}."}
        lines = [f"{f['id']} [{f['severity'].upper()}] {f['title']} ({f['confidence']})" for f in findings]
        return {"message": "\n".join(lines)}
    if cmd == "report" and arg:
        from .bugbounty import generate_report

        session = Session(arg)
        store = FindingsStore(session._dir / "findings.json")
        report = generate_report(program_name="KitoAi Program", target=arg, findings=store.all())
        return {"message": report[:6000]}
    if cmd == "status":
        return {"message": f"LLM: {'online' if ChatLLM().available else 'offline (fallback)'} | exploit: {'enabled' if settings.allow_active_exploit else 'disabled'}"}
    raise HTTPException(status_code=400, detail="unknown command. Try: target <domain>, run <domain>, findings <domain>, report <domain>, status, help")


@app.get("/api/task/{task_id}")
def task_status(task_id: str) -> JSONResponse:
    with _tasks_lock:
        task = _tasks.get(task_id)
        if not task:
            raise HTTPException(status_code=404, detail="task not found")
        snapshot = {
            "id": task["id"],
            "action": task["action"],
            "target": task["target"],
            "done": task["done"],
            "output": task["output"].text()[-40000:],
        }
    return JSONResponse(snapshot)


def main() -> None:
    import uvicorn

    print(f"{__app_name__} dashboard: http://{settings.web_host}:{settings.web_port}")
    uvicorn.run(app, host=settings.web_host, port=settings.web_port, log_level="warning")


if __name__ == "__main__":
    main()
