# KitoIP

![Python](https://img.shields.io/badge/python-3.10%2B-blue)
![Version](https://img.shields.io/badge/version-0.1.0-green)
![Interface](https://img.shields.io/badge/interface-CLI%20%7C%20Web-orange)

**KitoIP** is an AI-powered penetration testing assistant. It drives a LLM-based agent through a *plan → execute → analyze* loop, orchestrates common offensive-security tools, and turns the results into structured, HackerOne-style findings reports.

> **Authorized testing only.** Use KitoIP exclusively against targets you own or have explicit written permission to assess.

## What it does

1. **Plan** — the agent breaks the declared target down into concrete assessment steps (with an LLM, or a deterministic rule-based planner when no API key is configured).
2. **Execute** — steps are carried out through normalized tool wrappers: `nmap`, `subfinder`, `httpx`, `nuclei`, `katana`, `ffuf`/`feroxbuster`, `sqlmap` and `nikto`. Install state is detected automatically, every call has a timeout, and alternate tools are used as fallback.
3. **Analyze** — tool output is converted into findings with severity, confidence and CVSS v3.1 scoring, deduplicated, stored per target, and exported as JSON or a Markdown HackerOne-style report.

## Features

- **Agentic orchestration** — LLM-driven loop that works with any OpenAI-compatible endpoint (OpenAI, OpenRouter, Ollama, LM Studio, vLLM). Without an API key everything still runs on the built-in rule-based planner.
- **Tool orchestration** — install-state detection, per-tool timeouts and alternate-tool fallback for all wrapped tools.
- **Bug bounty workflows** — program scope parsing (HackerOne / Bugcrowd style), CVSS v3.1 scoring and vectors.
- **Findings store** — severity ordering, deduplication, JSON and Markdown export.
- **Per-target sessions** — findings, notes, command history and evidence are persisted under `data/` and restored automatically on the next run.
- **Three interfaces** — interactive CLI REPL, headless auto-run, and a FastAPI web dashboard with an async task queue.
- **Safety controls** — scope enforcement, confirmation prompts before destructive steps, and active exploitation disabled by default.

## Requirements

- Python 3.10+
- Optional external tools (auto-detected at runtime): `nmap`, `subfinder`, `httpx`, `nuclei`, `katana`, `ffuf`, `sqlmap`, `nikto`
- Web dashboard only: `fastapi`, `uvicorn`

## Install

```bash
git clone https://github.com/Vorlixx/KitoIP.git
cd KitoIP
pip install -r requirements.txt    # web dashboard dependencies
bash install_tools.sh              # optional: install the security tools
```

`install_tools.sh` installs the external tools via `apt` (Kali/Debian/Ubuntu), `choco` + `go install` (Windows Git-Bash), and verifies each one at the end.

## Usage

```bash
python run.py                               # interactive CLI
python run.py --target example.com --auto   # headless full pipeline + report
python run.py --web                         # web dashboard on http://127.0.0.1:8666
python run.py --version
```

On Windows you can also use the one-click launcher: `kitoip.bat` (starts the dashboard and opens your browser).

### CLI commands

| Command | Description |
| --- | --- |
| `target <domain\|url>` | Declare the authorized assessment target |
| `scope` | Show current session/target info |
| `run` | Run the AI agent (plan → execute → analyze) |
| `findings` | List stored findings |
| `report` | Generate a HackerOne-style Markdown report |
| `tools` | List available tools and their install state |
| `probe <path>` | Quick HTTP probe of the current target |
| `notes` | List saved notes |
| `help` | Show help |
| `exit` | Quit |

### LLM backends

KitoIP talks to any OpenAI-compatible endpoint. Point `KITOIP_LLM_BASE` at OpenAI, OpenRouter, Ollama, LM Studio or vLLM and set `KITOIP_LLM_KEY`. With no key configured, the deterministic rule-based planner takes over — no feature is lost.

## Configuration

All settings are environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `KITOIP_LLM_BASE` | `https://api.openai.com/v1` | OpenAI-compatible base URL |
| `KITOIP_LLM_KEY` | *(empty)* | LLM API key (empty = offline rule-based planner) |
| `KITOIP_LLM_MODEL` | `gpt-4o-mini` | Model name |
| `KITOIP_LLM_TIMEOUT` | `90` | LLM request timeout (s) |
| `KITOIP_MAX_STEPS` | `25` | Maximum agent steps |
| `KITOIP_TOOL_TIMEOUT` | `300` | Per-tool timeout (s) |
| `KITOIP_CONFIRM_DESTRUCTIVE` | `1` | Ask for confirmation before destructive steps |
| `KITOIP_ALLOW_EXPLOIT` | `0` | Enable active exploitation (sqlmap) |
| `KITOIP_MAX_CONCURRENT` | `3` | Max concurrent tool runs |
| `KITOIP_WEB_HOST` | `127.0.0.1` | Dashboard bind host |
| `KITOIP_WEB_PORT` | `8666` | Dashboard bind port |
| `KITOIP_DATA_DIR` | `./data` | Runtime data directory (sessions, findings) |

## Project layout

```
kitoip/           core package
  agents.py       orchestrator: plan -> execute -> analyze
  tools.py        tool wrappers and registry
  bugbounty.py    scope parsing, CVSS, report generation
  findings.py     findings store (severity, dedupe, export)
  llm.py          OpenAI-compatible client (stdlib only)
  cli.py          command-line interface
  config.py       settings, sessions and persistence
  webapp.py       FastAPI dashboard backend
web/index.html    web dashboard UI
run.py            unified entry point
install_tools.sh  external security-tool installer
kitoip.bat        Windows one-click launcher
```

## Safety model

- Targets must be declared explicitly before anything runs.
- Destructive steps require confirmation (`KITOIP_CONFIRM_DESTRUCTIVE=1`).
- Active exploitation stays off until you set `KITOIP_ALLOW_EXPLOIT=1`.

## Disclaimer

KitoIP is intended for authorized security testing and educational use only. Running it against systems you do not own or have explicit written permission to test is illegal. The operator is responsible for declaring and respecting the authorized scope.
