"""LLM chat client for the XCall AI agent.

Speaks OpenAI-compatible chat completions (works with OpenAI, Anthropic via
their OpenAI-compatible endpoints, Groq, Gemini's OpenAI-compat layer, any
self-hosted OpenAI-compatible server, and Ollama's /v1 endpoint) as well as
Ollama's native /api/chat.

Supports tool calls used by the voice agent:
  - transfer_to_specialist
  - hang_up
  - skip_turn

Only stdlib is used (urllib) so the agent runs anywhere.
"""

from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from typing import Any, Optional

log = logging.getLogger("xcall.llm_chat")


class LLMChatError(Exception):
    """Raised when the LLM call fails."""


# ------------------------------------------------------------------ #
# response model
# ------------------------------------------------------------------ #
class LLMResponse:
    def __init__(self, text: str, tool_calls: Optional[list[dict]] = None):
        self.text = text
        self.tool_calls = tool_calls or []

    @property
    def has_tools(self) -> bool:
        return bool(self.tool_calls)


class LLMChatClient:
    """OpenAI-compatible chat client."""

    def __init__(
        self,
        base_url: str = "https://api.openai.com/v1",
        api_key: str = "",
        model: str = "gpt-4o-mini",
        temperature: float = 0.7,
        max_tokens: int = 1024,
        timeout: float = 30.0,
        provider: str = "openai",
    ):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model = model
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.timeout = timeout
        self.provider = provider

    # ------------------------------------------------------------------ #
    # chat
    # ------------------------------------------------------------------ #
    def chat(
        self,
        messages: list[dict],
        tools: Optional[list[dict]] = None,
        tool_choice: str = "auto",
    ) -> LLMResponse:
        """Send a chat completion request. Returns text + any tool calls."""
        if self.provider == "ollama" and "11434" in self.base_url and not self.base_url.endswith("/v1"):
            return self._ollama_native(messages, tools)
        return self._openai_compatible(messages, tools, tool_choice)

    # ------------------------------------------------------------------ #
    # OpenAI-compatible
    # ------------------------------------------------------------------ #
    def _openai_compatible(
        self,
        messages: list[dict],
        tools: Optional[list[dict]],
        tool_choice: str,
    ) -> LLMResponse:
        url = self.base_url.rstrip("/") + "/chat/completions"
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "temperature": self.temperature,
            "max_tokens": self.max_tokens,
        }
        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = tool_choice

        data = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError, OSError) as exc:
            raise LLMChatError(f"LLM request failed: {exc}") from exc

        try:
            choice = raw["choices"][0]
            msg = choice.get("message", {})
        except (KeyError, IndexError) as exc:
            raise LLMChatError(f"unexpected LLM response shape: {raw}") from exc

        text = self._extract_text(msg.get("content"))
        tool_calls = self._extract_tool_calls(msg.get("tool_calls"))
        return LLMResponse(text, tool_calls)

    @staticmethod
    def _extract_text(content: Any) -> str:
        if not content:
            return ""
        if isinstance(content, str):
            return content.strip()
        # newer APIs return a list of content parts
        if isinstance(content, list):
            parts = []
            for part in content:
                if isinstance(part, dict):
                    if part.get("type") == "text":
                        parts.append(part.get("text", ""))
                elif isinstance(part, str):
                    parts.append(part)
            return " ".join(p for p in parts if p).strip()
        return str(content).strip()

    @staticmethod
    def _extract_tool_calls(raw: Any) -> list[dict]:
        if not isinstance(raw, list):
            return []
        calls = []
        for tc in raw:
            if not isinstance(tc, dict):
                continue
            fn = tc.get("function") or {}
            name = fn.get("name", "")
            arguments = fn.get("arguments", "")
            args = {}
            if isinstance(arguments, str) and arguments.strip():
                try:
                    args = json.loads(arguments)
                except json.JSONDecodeError:
                    args = {"_raw": arguments}
            elif isinstance(arguments, dict):
                args = arguments
            if name:
                calls.append({"name": name, "arguments": args})
        return calls

    # ------------------------------------------------------------------ #
    # Ollama native
    # ------------------------------------------------------------------ #
    def _ollama_native(self, messages: list[dict], tools: Optional[list[dict]]) -> LLMResponse:
        url = self.base_url.rstrip("/") + "/api/chat"
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "stream": False,
            "options": {
                "temperature": self.temperature,
                "num_predict": self.max_tokens,
            },
        }
        # ollama native tool format differs slightly; map if provided
        if tools:
            payload["tools"] = _map_ollama_tools(tools)

        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError, OSError) as exc:
            raise LLMChatError(f"Ollama request failed: {exc}") from exc

        message = raw.get("message", {}) or {}
        text = self._extract_text(message.get("content"))
        tool_calls = []
        for tc in message.get("tool_calls") or []:
            fn = tc.get("function", {})
            name = fn.get("name", "")
            args = fn.get("arguments", {})
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except json.JSONDecodeError:
                    args = {"_raw": args}
            if name:
                tool_calls.append({"name": name, "arguments": args})
        return LLMResponse(text, tool_calls)


def _map_ollama_tools(tools: list[dict]) -> list[dict]:
    """Convert OpenAI tool schema to Ollama's tool schema."""
    mapped = []
    for t in tools:
        fn = t.get("function", {})
        params = fn.get("parameters", {})
        mapped.append({
            "type": "function",
            "function": {
                "name": fn.get("name", ""),
                "description": fn.get("description", ""),
                "parameters": params,
            },
        })
    return mapped


# ------------------------------------------------------------------ #
# factory
# ------------------------------------------------------------------ #
def make_llm_chat(cfg: dict) -> LLMChatClient:
    """Build a chat client from an assistant config dict.

    Expected keys: assistant_provider, assistant_model,
    assistant_api_key_enc (already decrypted), assistant_api_base_url,
    assistant_temperature, assistant_max_tokens.
    """
    provider = cfg.get("assistant_provider") or "openai"
    base_url = (cfg.get("assistant_api_base_url") or "").strip() or _default_base_url(provider)
    model = cfg.get("assistant_model") or _default_model(provider)
    api_key = cfg.get("assistant_api_key_enc") or cfg.get("assistant_api_key") or ""

    # Ollama native: use http://host:11434 without the /v1 suffix.
    if provider == "ollama":
        if base_url.rstrip("/").endswith("/v1"):
            base_url = base_url.rstrip("/")[:-3]

    return LLMChatClient(
        base_url=base_url,
        api_key=api_key,
        model=model,
        temperature=float(cfg.get("assistant_temperature", 0.7) or 0.7),
        max_tokens=int(cfg.get("assistant_max_tokens", 1024) or 1024),
        provider=provider,
    )


def _default_base_url(provider: str) -> str:
    return {
        "openai": "https://api.openai.com/v1",
        "anthropic": "https://api.anthropic.com/v1",
        "gemini": "https://generativelanguage.googleapis.com/v1beta/openai",
        "groq": "https://api.groq.com/openai/v1",
        "openai_compatible": "http://127.0.0.1:8080/v1",
        "ollama": "http://127.0.0.1:11434",
    }.get(provider, "https://api.openai.com/v1")


def _default_model(provider: str) -> str:
    return {
        "openai": "gpt-4o-mini",
        "anthropic": "claude-3-5-sonnet-latest",
        "gemini": "gemini-1.5-pro",
        "groq": "llama-3.3-70b-versatile",
        "openai_compatible": "local-model",
        "ollama": "llama3.1",
    }.get(provider, "gpt-4o-mini")

