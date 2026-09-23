# KitoAi

AI-powered penetration testing assistant — an original, open-source agentic security
tool that plans and executes security-testing steps with an LLM, orchestrates common
offensive tooling, and produces HackerOne-style findings reports.

> **Authorized testing only.** Use KitoAi exclusively against targets you own or have
> explicit written permission to assess.

## Features

- **Agentic orchestration** — LLM-driven *plan → execute → analyze* loop. Works with any
  OpenAI-compatible endpoint (OpenAI, OpenRouter, Ollama, LM Studio, vLLM). If no API key
  is configured, it transparently falls back to a deterministic rule-based planner so
  every feature still runs.
- **Tool orchestration** — normalized wrappers for `nmap`, `subfinder`, `httpx`, `nuclei`,
  `katana`, `ffuf`/`feroxbuster`, `sqlmap` and `nikto`, with install-state detection,
  timeouts and alternate-tool fallback.
- **Bug bounty workflows** — program scope parsing (HackerOne / Bugcrowd style),
  CVSS v3.1 scoring and vectors, and structured HackerOne-style Markdown reports.
- **Findings store** — severity ordering, deduplication, JSON and Markdown export.
- **Interfaces** — interactive CLI REPL, headless auto-run, and a FastAPI web dashboard
  with an async task queue.
- **Safety controls** — scope enforcement, confirmation prompts before destructive steps,
  and active exploitation disabled by default.

## Requirements

- Python 3.10+
- Optional external tools (auto-detected): `nmap`, `subfinder`, `httpx`, `nuclei`,
  `katana`, `ffuf`, `sqlmap`, `nikto`
- Web dashboard only: `fastapi`, `uvicorn`

## Install

```bash
pip install -r requirements.txt     # web dashboard dependencies
bash install_tools.sh               # optional: install the security tools
```

## Usage

```bash
python run.py                               # interactive CLI
python run.py --target example.com --auto   # headless full pipeline + report
python run.py --web                         # web dashboard on http://127.0.0.1:8666
```

On Windows you can also use the one-click launcher: `kitoai.bat`.

## Configuration

All settings are environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `KITOAI_LLM_BASE` | `https://api.openai.com/v1` | OpenAI-compatible base URL |
| `KITOAI_LLM_KEY` | *(empty)* | LLM API key (empty = offline rule-based planner) |
| `KITOAI_LLM_MODEL` | `gpt-4o-mini` | Model name |
| `KITOAI_LLM_TIMEOUT` | `90` | LLM request timeout (s) |
| `KITOAI_MAX_STEPS` | `25` | Maximum agent steps |
| `KITOAI_TOOL_TIMEOUT` | `300` | Per-tool timeout (s) |
| `KITOAI_CONFIRM_DESTRUCTIVE` | `1` | Ask for confirmation before destructive steps |
| `KITOAI_ALLOW_EXPLOIT` | `0` | Enable active exploitation |
| `KITOAI_MAX_CONCURRENT` | `3` | Max concurrent tool runs |
| `KITOAI_WEB_HOST` | `127.0.0.1` | Dashboard bind host |
| `KITOAI_WEB_PORT` | `8666` | Dashboard bind port |
| `KITOAI_DATA_DIR` | `./data` | Runtime data directory (sessions, findings) |

## Project layout

```
kitoai/           core package
  agents.py       orchestrator: plan -> execute -> analyze
  tools.py        tool wrappers and registry
  bugbounty.py    scope parsing, CVSS, report generation
  findings.py     findings store (severity, dedupe, export)
  llm.py          OpenAI-compatible client (stdlib only)
  cli.py          command-line interface
  webapp.py       FastAPI dashboard backend
web/index.html    web dashboard UI
run.py            unified entry point
install_tools.sh  external security-tool installer
kitoai.bat        Windows one-click launcher
```

## Disclaimer

KitoAi is intended for authorized security testing and educational use only. Running it
against systems you do not own or have explicit written permission to test is illegal.
The operator is responsible for declaring and respecting the authorized scope.
