"""LLM adapters.

The LLM classifies the caller's free-form answers into intents (mapped to
script branch keywords) so the script can route correctly when the caller
does not use the exact scripted words.

Engines:

- ``ollama`` : local Ollama HTTP API (https://ollama.com)
- ``none``   : no LLM; keyword matching only (fully offline)

The prompt asks the model to output a single intent label drawn from the
branch names defined in the current script node. When the LLM is unreachable
or disabled, the agent falls back to keyword matching.
"""

from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request

log = logging.getLogger("xcall.llm")


class LLMError(Exception):
    """Raised when the LLM cannot be used."""


class LLMEngine:
    def classify(self, text: str, labels: list[str]) -> str:
        """Return the best-matching label for the caller's text.

        Returns '' if the model can't decide (agent falls back to keywords).
        """
        raise NotImplementedError


class OllamaLLM(LLMEngine):
    def __init__(
        self,
        base_url: str = "http://127.0.0.1:11434",
        model: str = "llama3.1",
        temperature: float = 0.1,
        timeout: float = 20.0,
    ):
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.temperature = temperature
        self.timeout = timeout

    def classify(self, text: str, labels: list[str]) -> str:
        if not labels:
            return ""
        labels_json = json.dumps(labels)
        system = (
            "You are a call-routing classifier. Given a customer's spoken words "
            "and a list of possible intent labels, return the single best label "
            "as JSON: {\"label\": \"...\"}. If none match, return {\"label\": \"\"}. "
            "Labels: " + labels_json
        )
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": text},
            ],
            "stream": False,
            "options": {"temperature": self.temperature},
        }
        req = urllib.request.Request(
            f"{self.base_url}/api/chat",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as exc:
            raise LLMError(f"ollama request failed: {exc}") from exc

        content = (data.get("message") or {}).get("content", "")
        label = self._extract_label(content)
        log.debug("LLM classify %r -> %r (labels=%s)", text, label, labels)
        return label

    @staticmethod
    def _extract_label(content: str) -> str:
        """Best-effort extraction of a label from model JSON output."""
        text = content.strip()
        try:
            parsed = json.loads(text)
            label = parsed.get("label", "")
            return label if isinstance(label, str) else ""
        except json.JSONDecodeError:
            pass
        for line in text.splitlines():
            line = line.strip()
            if line.startswith('"label"'):
                label = line.split(":", 1)[-1].strip().strip('",')
                return label
        return ""


class NoneLLM(LLMEngine):
    """No LLM — keyword matching only."""

    def classify(self, text: str, labels: list[str]) -> str:
        return ""


def make_llm(cfg: dict) -> LLMEngine:
    """Factory based on config['llm']."""
    engine = (cfg.get("engine") or "none").lower()
    if engine == "ollama":
        return OllamaLLM(
            base_url=cfg.get("base_url", "http://127.0.0.1:11434"),
            model=cfg.get("model", "llama3.1"),
            temperature=float(cfg.get("temperature", 0.1)),
            timeout=float(cfg.get("timeout", 20.0)),
        )
    return NoneLLM()
