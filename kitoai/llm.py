"""LLM client: OpenAI-compatible chat completions via stdlib only.

Works with any OpenAI-compatible endpoint (OpenAI, OpenRouter, Ollama,
LM Studio, vLLM, ...). If no API key is configured, the system transparently
falls back to a deterministic rule-based planner so every feature still runs.
"""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request

from .config import settings

SYSTEM_PROMPT = """You are KitoAi, an AI penetration testing assistant inside an automated \
security agent. You plan and analyze security testing steps for AUTHORIZED targets only.

You have tools: http_probe, http_headers, robots_scan, dns_resolve, ports_scan (nmap), \
subdomains (subfinder), web_probe (httpx), vuln_scan (nuclei), crawl (katana), \
dir_bruteforce (ffuf/feroxbuster), sql_inject (sqlmap), nikto_scan, quick_check.

Rules:
- Only act on the declared target. Never pivot to third-party hosts.
- Prefer passive/lightweight checks first, escalate only when evidence justifies it.
- Active exploitation (sql_inject with --dbs, payloads that modify state) is only \
allowed when explicitly enabled by the operator.
- Every step must produce a tool call. Output strictly JSON in this schema:
{"tool": "<tool_name>", "args": {...}, "reason": "<short justification>"}
- If a tool is missing or returns nothing useful, try an alternative tool.
- Do not invent findings; report only what tool output supports."""


class LLMError(RuntimeError):
    pass


class ChatLLM:
    """Minimal OpenAI-compatible chat client built on urllib."""

    def __init__(
        self,
        base_url: str | None = None,
        api_key: str | None = None,
        model: str | None = None,
        timeout: int | None = None,
    ):
        self.base_url = (base_url or settings.llm_base_url).rstrip("/")
        self.api_key = api_key if api_key is not None else settings.llm_api_key
        self.model = model or settings.llm_model
        self.timeout = timeout or settings.llm_timeout

    @property
    def available(self) -> bool:
        return bool(self.api_key)

    def chat(self, messages: list[dict], temperature: float = 0.2, max_tokens: int = 1600) -> str:
        if not self.available:
            raise LLMError("No API key configured (set KITOAI_LLM_KEY).")
        body = json.dumps(
            {
                "model": self.model,
                "messages": messages,
                "temperature": temperature,
                "max_tokens": max_tokens,
            }
        ).encode("utf-8")
        req = urllib.request.Request(
            f"{self.base_url}/chat/completions",
            data=body,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self.api_key}",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:500]
            raise LLMError(f"LLM HTTP {exc.code}: {detail}") from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise LLMError(f"LLM unreachable: {exc}") from exc
        try:
            return payload["choices"][0]["message"]["content"].strip()
        except (KeyError, IndexError, TypeError) as exc:
            raise LLMError(f"Unexpected LLM response: {str(payload)[:300]}") from exc

    def chat_json(self, messages: list[dict], temperature: float = 0.1, max_tokens: int = 1200) -> dict:
        """Ask for a JSON object, retry until valid JSON is returned."""
        last_err = ""
        for _ in range(3):
            raw = self.chat(messages, temperature=temperature, max_tokens=max_tokens)
            obj = extract_json(raw)
            if obj is not None:
                return obj
            last_err = f"could not parse JSON from: {raw[:200]}"
            messages = messages + [{"role": "user", "content": f"Return ONLY valid JSON. {last_err}"}]
        raise LLMError(last_err)


def extract_json(text: str) -> dict | list | None:
    """Extract the first JSON object/array from a (possibly noisy) model reply."""
    text = text.strip()
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL)
    if fence:
        text = fence.group(1).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    start = min([i for i in (text.find("{"), text.find("[")) if i != -1] or [-1])
    if start == -1:
        return None
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[start : i + 1])
                except json.JSONDecodeError:
                    return None
    return None
