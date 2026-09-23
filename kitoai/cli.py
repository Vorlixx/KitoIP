"""KitoAi command-line interface: interactive REPL + headless auto-run."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from . import __app_name__, __version__
from .agents import Orchestrator
from .bugbounty import generate_report
from .config import DATA_DIR, Session, settings
from .findings import FindingsStore
from .llm import ChatLLM
from .tools import available_tools, run_tool

_COLOR = not os.environ.get("NO_COLOR") and sys.stdout.isatty()


def _c(code: str, text: str) -> str:
    if not _COLOR:
        return text
    return f"\033[{code}m{text}\033[0m"


def _ok(text: str) -> str: return _c("32", text)
def _warn(text: str) -> str: return _c("33", text)
def _err(text: str) -> str: return _c("31", text)
def _info(text: str) -> str: return _c("36", text)
def _bold(text: str) -> str: return _c("1", text)


def _print_tools() -> None:
    print(_bold("\nAvailable tools:"))
    for t in available_tools():
        state = _ok("installed") if t["installed"] else _warn("missing")
        print(f"  {_info(t['name']):<16} [{state}] {t['desc']}")


def _show_findings(store: FindingsStore, target: str) -> None:
    findings = store.all()
    if not findings:
        print(_info("\nNo findings yet. Run the agent first."))
        return
    print(_bold(f"\nFindings for {target} ({len(findings)} total):"))
    for f in findings:
        sev = f["severity"]
        label = {
            "critical": _err(sev.upper()),
            "high": _err(sev.upper()),
            "medium": _warn(sev.upper()),
            "low": _warn(sev.upper()),
            "info": _info(sev.upper()),
        }.get(sev, sev.upper())
        cvss = f" cvss={f['cvss_score']}" if f.get("cvss_score") else ""
        print(f"  #{f['id']} [{label}] {f['title']}{cvss} ({f['confidence']})")
        if f.get("evidence"):
            print(f"      evidence: {f['evidence'][:160]}")


def _save_report(session: Session, store: FindingsStore, target: str, program: str = "KitoAi Program") -> Path:
    report = generate_report(program_name=program, target=target, findings=store.all())
    out = DATA_DIR / f"report_{session._slug(target)}.md"
    out.write_text(report, encoding="utf-8")
    return out


def _interactive(target_arg: str | None) -> None:
    print(_bold(f"{__app_name__} v{__version__} — AI penetration testing assistant"))
    print(_info("Authorized testing only. Type 'help' for commands, 'exit' to quit."))
    print(f"LLM: {_ok('online') if ChatLLM().available else _warn('offline (fallback planner)')} | "
          f"exploit: {'enabled' if settings.allow_active_exploit else 'disabled'}")

    target = target_arg
    session: Session | None = None
    store = FindingsStore(settings.findings_file)

    while True:
        prompt = f"kitoai[{target or '?'}]> " if target else "kitoai> "
        try:
            raw = input(_info(prompt)).strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not raw:
            continue
        cmd, _, arg = raw.partition(" ")
        arg = arg.strip()

        if cmd in ("exit", "quit"):
            break
        elif cmd == "help":
            print(_bold("\nCommands:"))
            for line in [
                "  target <domain|url>   declare the authorized assessment target",
                "  scope                 show current session/target info",
                "  run                   run the AI agent (plan->execute->analyze)",
                "  findings              list stored findings",
                "  report                generate HackerOne-style report (markdown)",
                "  tools                 list available tools and install state",
                "  probe <path>          quick HTTP probe of current target",
                "  notes                 list saved notes",
                "  help                  this help",
                "  exit                  quit",
            ]:
                print(line)
        elif cmd == "target":
            if not arg:
                print(_err("usage: target <domain|url>"))
                continue
            target = arg.rstrip("/")
            session = Session(target)
            store = FindingsStore(session._dir / "findings.json")
            print(_ok(f"[+] Target locked: {target}"))
            print(f"    session dir: {session._dir}")
            print(f"    findings: {len(store.all())} stored")
        elif cmd == "scope":
            if session:
                for k, v in session.summarize().items():
                    print(f"  {k}: {v}")
            else:
                print(_warn("no target set — use 'target <domain>'"))
        elif cmd == "run":
            if not target:
                print(_err("Set a target first: target <domain|url>"))
                continue
            print(_warn("\n[!] KitoAi will run automated checks against the declared target."))
            if settings.confirm_destructive:
                confirm = input("Proceed? [y/N] ").strip().lower()
                if confirm not in ("y", "yes"):
                    print(_info("cancelled."))
                    continue
            orch = Orchestrator(target, session=session, store=store, progress=lambda m: print("  " + m))
            orch.run()
        elif cmd == "findings":
            if not target:
                print(_err("Set a target first."))
                continue
            _show_findings(store, target)
        elif cmd == "report":
            if not target:
                print(_err("Set a target first."))
                continue
            path = _save_report(session or Session(target), store, target)
            print(_ok(f"[+] Report written: {path}"))
            print(path.read_text(encoding="utf-8")[:2500])
        elif cmd == "tools":
            _print_tools()
        elif cmd == "probe":
            if not target:
                print(_err("Set a target first."))
                continue
            path = arg or "/"
            res = run_tool("http_probe", target, {"path": path, "show_body": True})
            print(_ok("\n" + res.output) if res.ok else _err(res.error))
        elif cmd == "notes":
            if not session:
                print(_warn("no target set"))
                continue
            for n in session.notes[-20:]:
                print(f"  [{n['category']}] {n['title']}: {n['content'][:100]}")
        else:
            print(_err(f"unknown command: {cmd} (try 'help')"))


def _headless(target: str, program: str) -> None:
    session = Session(target)
    store = FindingsStore(session._dir / "findings.json")
    orch = Orchestrator(target, session=session, store=store, progress=lambda m: print(m))
    summary = orch.run()
    report_path = _save_report(session, store, target, program)
    print(f"\nREPORT: {report_path}")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(prog="kitoai", description=f"{__app_name__} - AI pentest assistant")
    parser.add_argument("--target", help="target domain/URL to assess")
    parser.add_argument("--auto", action="store_true", help="headless: run full pipeline and write report")
    parser.add_argument("--program", default="KitoAi Program", help="program name for the report")
    parser.add_argument("--version", action="store_true", help="print version")
    args = parser.parse_args()

    if args.version:
        print(f"{__app_name__} {__version__}")
        return
    if args.target and args.auto:
        _headless(args.target, args.program)
    else:
        _interactive(args.target)


if __name__ == "__main__":
    main()
