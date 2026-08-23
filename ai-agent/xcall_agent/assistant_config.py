"""Assistant configuration loader for the XCall AI agent.

The agent needs to know *which* assistant to run on a call. It resolves this
from, in order:

  1. a local JSON file (assistant.json) — convenient for testing/offline
  2. the XCall portal API (assistant_api.php?action=agent_config) — production

The returned config is a plain dict with ``assistant_*`` keys matching the
portal database schema, so both sources produce identical structures.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.parse
import urllib.request
from typing import Optional

log = logging.getLogger("xcall.assistant_config")


class AssistantConfigError(Exception):
    """Raised when no assistant config can be loaded."""


def load_assistant_config(cfg: dict) -> dict:
    """Load the active assistant config.

    ``cfg`` is the agent config section; expects:
      - assistant_file        : optional path to a local JSON assistant config
      - portal_url            : e.g. https://portal.xcall.local/ai-assistant/assistant_api.php
      - portal_secret         : shared secret for the agent_config endpoint
    """
    assistant_file = cfg.get("assistant_file") or ""
    if assistant_file and os.path.exists(assistant_file):
        return _load_local_file(assistant_file)

    portal_url = cfg.get("portal_url") or ""
    portal_secret = cfg.get("portal_secret") or ""
    if portal_url:
        return _load_from_portal(portal_url, portal_secret)

    raise AssistantConfigError(
        "no assistant config source configured (assistant_file or portal_url)"
    )


def _load_local_file(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    assistant = data.get("assistant", data)
    log.info("loaded assistant config from %s (%s)", path, assistant.get("assistant_name", "?"))
    return assistant


def _load_from_portal(portal_url: str, secret: str) -> dict:
    url = portal_url
    sep = "&" if "?" in url else "?"
    url += f"{sep}action=agent_config&key={urllib.parse.quote(secret)}"

    req = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError, OSError) as exc:
        raise AssistantConfigError(f"portal config fetch failed: {exc}") from exc

    assistant = data.get("assistant")
    if not assistant:
        raise AssistantConfigError("portal returned no assistant config")
    log.info("loaded assistant config from portal (%s)", assistant.get("assistant_name", "?"))
    return assistant


# ------------------------------------------------------------------ #
# helpers used by the orchestrator
# ------------------------------------------------------------------ #
def build_system_prompt(assistant: dict, context: Optional[dict] = None) -> str:
    """Compose the system prompt from the assistant instructions + call context.

    ``context`` may carry dynamic variables (caller number, time, etc.) that
    are templated into the instructions using {placeholders}.
    """
    instructions = assistant.get("assistant_instructions") or ""
    ctx = dict(context or {})
    ctx.setdefault("company_name", "your company")
    try:
        instructions = instructions.format(**ctx)
    except (KeyError, ValueError):
        pass  # leave any unknown placeholders in place for the LLM

    prompt = instructions.strip()
    return prompt


def build_greeting(assistant: dict, context: Optional[dict] = None) -> str:
    greeting = assistant.get("assistant_greeting") or ""
    ctx = dict(context or {})
    try:
        greeting = greeting.format(**ctx)
    except (KeyError, ValueError):
        pass
    return greeting.strip()
