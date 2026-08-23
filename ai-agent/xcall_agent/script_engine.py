"""Script engine: loads a conversation script (YAML) and drives the state machine.

The agent follows the script node by node. Each node:

- ``prompt`` : the text the agent speaks (templated with ``{var}`` placeholders)
- ``collect`` : optional; asks for a piece of info and stores the caller's
  utterance in the session context (e.g. ``{issue}``)
- ``on``     : optional; maps keywords/intents from the caller's answer to the
  next node id. When the caller's answer matches a branch, follow it; when no
  branch matches, the LLM (if enabled) classifies, else the default branch.
- ``next``   : the node id to go to after this one (default flow).
- ``action`` : optional; a special action to perform:
    - ``{"type": "handoff"}`` -> transfer the call to a human specialist
    - ``{"type": "hangup"}``  -> end the call
- ``wait``   : whether the agent should pause for caller input (default true)

The ``meta`` block holds global settings used for templating
(e.g. company name, agent name).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Optional

try:
    import yaml  # type: ignore

    HAVE_YAML = True
except ImportError:  # pragma: no cover
    HAVE_YAML = False
    from .config import _parse_simple_yaml

log = logging.getLogger("xcall.script")

DEFAULT_START = "greeting"


class ScriptError(Exception):
    """Raised when the script file is malformed."""


@dataclass
class ScriptNode:
    id: str
    prompt: str = ""
    collect: Optional[str] = None
    branches: dict = field(default_factory=dict)
    next: Optional[str] = None
    action: Optional[dict] = None
    wait: bool = True   # whether the agent should pause for caller input

    def matches(self, text: str) -> Optional[str]:
        """Return the next node id for a caller's utterance, via keyword match.

        Returns the branch node id if any keyword in the text is found in the
        caller's words, otherwise None (fall through to LLM / default).
        """
        if not text or not self.branches:
            return None
        words = text.lower().split()
        for branch, branch_def in self.branches.items():
            if isinstance(branch_def, str):
                continue  # handled elsewhere; this is a fallback target
            keywords = branch_def.get("keywords", [])
            if any(kw in words for kw in keywords):
                return branch_def.get("next")
        return None

    def fallback(self) -> Optional[str]:
        """The default branch target ('_fallback' key), if present."""
        if not self.branches:
            return None
        fb = self.branches.get("_fallback")
        if isinstance(fb, dict):
            return fb.get("next")
        if isinstance(fb, str):
            return fb
        return None


@dataclass
class Script:
    meta: dict = field(default_factory=dict)
    start: str = DEFAULT_START
    nodes: dict = field(default_factory=dict)   # id -> ScriptNode
    order: list = field(default_factory=list)   # node ids in file order

    @classmethod
    def load(cls, path: str) -> "Script":
        """Load and validate a script YAML file."""
        if HAVE_YAML:
            with open(path, "r", encoding="utf-8") as fh:
                data = yaml.safe_load(fh) or {}
        else:  # pragma: no cover
            data = _parse_simple_yaml(path)

        script = cls()
        script.meta = data.get("meta", {}) or {}
        script.start = data.get("start", DEFAULT_START)

        raw_nodes = data.get("nodes", {}) or {}
        if not raw_nodes:
            raise ScriptError(f"no 'nodes' section found in {path}")

        for node_id, raw in raw_nodes.items():
            raw = raw or {}
            if not isinstance(raw, dict):
                raise ScriptError(f"node {node_id!r} is not a mapping")
            script.nodes[node_id] = ScriptNode(
                id=node_id,
                prompt=raw.get("prompt", ""),
                collect=raw.get("collect"),
                branches=raw.get("branches", {}) or {},
                next=raw.get("next"),
                action=raw.get("action"),
                wait=raw.get("wait", True),
            )
            script.order.append(node_id)

        if script.start not in script.nodes:
            raise ScriptError(f"start node {script.start!r} not found in {path}")
        log.info("script loaded: %d nodes, start=%s", len(script.nodes), script.start)
        return script

    def get(self, node_id: str) -> ScriptNode:
        try:
            return self.nodes[node_id]
        except KeyError:
            raise ScriptError(f"node {node_id!r} does not exist")

    def template(self, text: str, context: dict) -> str:
        """Substitute {placeholders} using meta + runtime context."""
        merged = {}
        merged.update(self.meta)
        merged.update(context)
        try:
            return text.format(**merged)
        except (KeyError, IndexError, ValueError) as exc:  # pragma: no cover
            log.warning("template error: %s (text=%r)", exc, text)
            return text

    def next_id(self, node: ScriptNode, context: dict) -> str:
        """Decide the next node id for the current state.

        Resolution order:
        1. keyword branch match on the last caller utterance
        2. fallback branch ('_fallback')
        3. explicit 'next'
        4. next node in file order
        """
        last_text = (context.get("last_utterance") or "").lower()
        if node.branches:
            branch = node.matches(last_text)
            if branch:
                return branch
            fb = node.fallback()
            if fb:
                return fb
        if node.next:
            return node.next
        # fall back to next node in file order
        try:
            idx = self.order.index(node.id)
            if idx + 1 < len(self.order):
                return self.order[idx + 1]
        except ValueError:  # pragma: no cover
            pass
        return node.id  # stay put if nothing else


def build_context(**kwargs) -> dict:
    """Small helper to seed a conversation context dict."""
    ctx: dict = {}
    ctx.update(kwargs)
    return ctx
