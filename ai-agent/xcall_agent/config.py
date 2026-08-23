"""Configuration loading for the XCall AI agent.

Loads config.yaml (with sane defaults) and provides typed access to the
nested settings. Kept dependency-light: uses stdlib + PyYAML if available,
otherwise falls back to a simple built-in parser for YAML-subset used by the
example config.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Any, Optional

try:
    import yaml  # type: ignore

    HAVE_YAML = True
except ImportError:  # pragma: no cover
    HAVE_YAML = False


# --------------------------------------------------------------------------- #
# defaults
# --------------------------------------------------------------------------- #
DEFAULTS: dict = {
    "esl": {"host": "127.0.0.1", "port": 8021, "password": "ClueCon", "acl": "127.0.0.1"},
    "agent": {
        "context": "xcall_ai",
        "identify_var": "xcall_agent",
        "identify_value": "true",
        "mode": "script",           # script | assistant
    },
    "assistant": {
        # Local JSON file (testing / offline) OR portal API (production).
        "assistant_file": "",        # e.g. /opt/xcall/ai-agent/assistant.json
        "portal_url": "",            # e.g. https://portal.example.com/ai-assistant/assistant_api.php
        "portal_secret": "",         # shared secret stored in v_xcall_settings
    },
    "script": {"file": "scripts/helpdesk_triage.yaml"},
    "stt": {
        "engine": "stub",          # whisper | vosk | stub
        "model": "base",
        "device": "cpu",
        "compute_type": "int8",
        "language": "en",
    },
    "tts": {
        "engine": "stub",          # piper | espeak | stub
        "voice": "en_US-lessac-medium",
        "piper_path": "piper",
        "piper_model": "models/en_US-lessac-medium.onnx",
        "cache_dir": "tts_cache",
        "sample_rate": 16000,
    },
    "llm": {
        "engine": "none",          # ollama | none
        "base_url": "http://127.0.0.1:11434",
        "model": "llama3.1",
        "temperature": 0.1,
        "fallback_to_keywords": True,
    },
    "recording": {
        "enabled": True,
        "dir": "/var/spool/xcall/recordings",
        "stereo": False,
        "record_agent_audio": True,
    },
    "handoff": {
        "destination_ext": "7000",
        "context": "default",
        "hold_message": "Thank you for holding. I will now connect you to a specialist.",
        "ring_timeout": 25,
    },
    "timing": {
        "no_speech_retries": 2,
        "max_utterance_seconds": 15,
        "end_of_speech_silence": 1.2,
        "vad_threshold": 800,
        "max_call_seconds": 900,
    },
    "logging": {"level": "INFO", "file": "logs/xcall-agent.log"},
}


# --------------------------------------------------------------------------- #
# config object
# --------------------------------------------------------------------------- #
@dataclass
class Config:
    data: dict = field(default_factory=dict)

    @classmethod
    def load(cls, path: Optional[str] = None) -> "Config":
        """Load config from path (or a default). CLI flag takes precedence."""
        data = _deep_copy(DEFAULTS)
        if path and os.path.exists(path):
            if HAVE_YAML:
                with open(path, "r", encoding="utf-8") as fh:
                    user = yaml.safe_load(fh) or {}
            else:  # pragma: no cover
                user = _parse_simple_yaml(path)
            _deep_merge(data, user)
        _apply_env_overrides(data)
        return cls(data=data)

    # ------------------------------------------------------------------ #
    # accessors
    # ------------------------------------------------------------------ #
    def get(self, section: str, key: str, default: Any = None) -> Any:
        return self.data.get(section, {}).get(key, default)

    def section(self, name: str) -> dict:
        return self.data.get(name, {})

    @property
    def esl(self) -> dict:
        return self.data["esl"]

    @property
    def agent(self) -> dict:
        return self.data["agent"]

    @property
    def assistant(self) -> dict:
        return self.data.get("assistant", {})

    @property
    def script(self) -> dict:
        return self.data["script"]

    @property
    def stt(self) -> dict:
        return self.data["stt"]

    @property
    def tts(self) -> dict:
        return self.data["tts"]

    @property
    def llm(self) -> dict:
        return self.data["llm"]

    @property
    def recording(self) -> dict:
        return self.data["recording"]

    @property
    def handoff(self) -> dict:
        return self.data["handoff"]

    @property
    def timing(self) -> dict:
        return self.data["timing"]

    @property
    def logging_cfg(self) -> dict:
        return self.data["logging"]


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def _deep_copy(d: dict) -> dict:
    import copy

    return copy.deepcopy(d)


def _deep_merge(base: dict, override: dict) -> None:
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            _deep_merge(base[key], value)
        else:
            base[key] = value


# Environment variables that override config for containerized deploys.
# Format: XCALL__<SECTION>__<KEY>  (e.g. XCALL__ESL__HOST, XCALL__ASSISTANT__PORTAL_URL)
def _apply_env_overrides(data: dict) -> None:
    import os as _os

    prefix = "XCALL__"
    for key, value in _os.environ.items():
        if not key.startswith(prefix):
            continue
        parts = key[len(prefix):].lower().split("__")
        if len(parts) != 2:
            continue
        section, k = parts
        if section in data and k in data[section]:
            data[section][k] = _coerce(value)



def _parse_simple_yaml(path: str) -> dict:  # pragma: no cover
    """Very small YAML subset parser (2-space indented key: value maps)."""
    result: dict = {}
    stack: list[tuple[int, dict]] = [(-1, result)]
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line.strip() or line.strip().startswith("#"):
                continue
            indent = len(line) - len(line.lstrip(" "))
            if ":" not in line:
                continue
            key, _, value = line.partition(":")
            key = key.strip().strip("\"'")
            value = value.strip()
            while stack and indent <= stack[-1][0]:
                stack.pop()
            target = stack[-1][1]
            if value:
                target[key] = _coerce(value)
            else:
                node: dict = {}
                target[key] = node
                stack.append((indent, node))
    return result


def _coerce(value: str) -> Any:
    if value.lower() in ("true", "false"):
        return value.lower() == "true"
    try:
        return int(value)
    except ValueError:
        pass
    try:
        return float(value)
    except ValueError:
        pass
    if value.startswith(("[", "{", '"')):
        try:
            import json

            return json.loads(value)
        except ValueError:
            pass
    return value
