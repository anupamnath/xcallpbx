"""LLM-driven (conversational) voice agent.

Unlike the scripted ``VoiceAgent`` (which follows a YAML state machine), this
agent lets the LLM run the conversation:

  greeting -> listen -> LLM decides -> speak or call a tool -> repeat

Tools the LLM can call:
  - transfer_to_specialist : play message + transfer to a human
  - hang_up                : end the call
  - skip_turn              : stay silent (caller asked us to hold)

The assistant configuration (instructions/context, model, provider, voice,
handoff destination) comes from the portal or a local JSON file.
"""

from __future__ import annotations

import logging
import threading
import time

from .esl_client import EslClient, EslEvent
from .llm_chat import LLMChatClient, LLMChatError
from .orchestrator import CallSession, VoiceAgent
from .script_engine import Script
from .stt import STTEngine
from .tts import TTSEngine

log = logging.getLogger("xcall.conversational")


# ------------------------------------------------------------------ #
# tool schemas (OpenAI format; mapped to Ollama format by llm_chat)
# ------------------------------------------------------------------ #
def agent_tools(handoff_extension: str = "7000") -> list[dict]:
    return [
        {
            "type": "function",
            "function": {
                "name": "transfer_to_specialist",
                "description": (
                    "Transfer the caller to a human specialist. Call this when you "
                    "cannot resolve the issue yourself, the caller asks for a human, "
                    "or you need to escalate. The caller will be placed on hold and "
                    "connected to a specialist."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "extension": {
                            "type": "string",
                            "description": "The extension to transfer to.",
                            "default": handoff_extension,
                        },
                        "message": {
                            "type": "string",
                            "description": "A short hold message to speak before transfer.",
                        },
                    },
                    "required": [],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "hang_up",
                "description": (
                    "End the call. Call this when the conversation is finished "
                    "(e.g. the issue is resolved and the caller has nothing else, "
                    "or the caller says goodbye)."
                ),
                "parameters": {"type": "object", "properties": {}, "required": []},
            },
        },
        {
            "type": "function",
            "function": {
                "name": "skip_turn",
                "description": (
                    "Say nothing this turn. Use this when the caller asks you to "
                    "wait or hold on (e.g. 'one moment', 'please wait', 'hold on')."
                ),
                "parameters": {"type": "object", "properties": {}, "required": []},
            },
        },
    ]

class ConversationalVoiceAgent(VoiceAgent):
    """Voice agent that drives a free-form LLM conversation on a parked call."""

    def __init__(
        self,
        esl: EslClient,
        assistant: dict,
        llm_chat: LLMChatClient,
        stt: STTEngine,
        tts: TTSEngine,
        cfg: dict,
    ):
        # build a minimal Script so the parent init works (unused in this mode)
        script = Script(meta={}, start="greeting", nodes={}, order=[])
        super().__init__(esl, script, stt, tts, None, cfg)
        self.assistant = assistant
        self.llm_chat = llm_chat
        self.handoff_ext = assistant.get("assistant_handoff_extension") or "7000"
        self.handoff_message = (
            assistant.get("assistant_handoff_message")
            or "Please hold the line, I will connect you to a specialist."
        )
        self.max_call_seconds = int(assistant.get("assistant_max_call_seconds", 900) or 900)
        self.silence_retries = int(assistant.get("assistant_silence_retries", 2) or 2)

        # tool schema with the caller-specific extension baked in
        self.tools = agent_tools(self.handoff_ext)

    # ------------------------------------------------------------------ #
    # event routing (reuses the parent's identify logic)
    # ------------------------------------------------------------------ #
    def handle_event(self, event: EslEvent) -> None:
        name = event.name
        if name == "CHANNEL_PARK":
            self._on_channel_park(event)
        elif name == "CHANNEL_ANSWER":
            pass
        elif name == "CHANNEL_HANGUP":
            self._on_channel_hangup(event)


    # ------------------------------------------------------------------ #
    # conversation loop
    # ------------------------------------------------------------------ #
    def _run_conversation(self, sess: CallSession) -> None:
        from .assistant_config import build_greeting, build_system_prompt

        # seed context with call metadata (templated into instructions)
        sess.context["company_name"] = self.assistant.get("assistant_name", "your company")
        sess.context["extension"] = self.assistant.get("assistant_handoff_extension", "")

        greeting = build_greeting(self.assistant, sess.context)
        system_prompt = build_system_prompt(self.assistant, sess.context)

        messages: list[dict] = [{"role": "system", "content": system_prompt}]

        try:
            if greeting:
                self._say(sess, greeting)

            while self._running and not sess.finished.is_set():
                if sess.elapsed > self.max_call_seconds:
                    self._say(sess, "I am sorry, but I need to end the call now. "
                                    "Please call back if you need further help.")
                    break

                # 1. listen
                text = self._listen(sess, None)
                if sess.finished.is_set():
                    break
                if not text:
                    sess.silent_count += 1
                    log.info("call %s: no speech (attempt %d/%d)",
                             sess.uuid[:8], sess.silent_count, self.silence_retries)
                    if sess.silent_count > self.silence_retries:
                        self._handoff_to_specialist(sess)
                        break
                    # re-ask politely without flooding the LLM
                    self._say(sess, "I'm sorry, I didn't catch that. Could you repeat that?")
                    continue

                sess.silent_count = 0
                self._log_transcript(sess, "caller", text)
                messages.append({"role": "user", "content": text})

                # 2. LLM turn
                try:
                    resp = self.llm_chat.chat(messages, tools=self.tools)
                except LLMChatError as exc:
                    log.error("LLM error on call %s: %s", sess.uuid[:8], exc)
                    self._say(sess, "I am sorry, I am having technical difficulties. "
                                    "Let me connect you to a specialist.")
                    self._handoff_to_specialist(sess)
                    break

                # 3. act on tool calls
                acted = False
                for call in resp.tool_calls:
                    acted = True
                    name = call["name"]
                    args = call["arguments"] or {}
                    if name == "transfer_to_specialist":
                        self._handoff_to_specialist(sess, args)
                        break
                    elif name == "hang_up":
                        self._say(sess, "Thank you for calling. Goodbye.")
                        time.sleep(0.8)
                        self.esl.hangup(sess.uuid, "NORMAL_CLEARING")
                        break
                    elif name == "skip_turn":
                        log.info("call %s: LLM skipped turn", sess.uuid[:8])
                        continue
                    else:
                        log.warning("call %s: unknown tool %r", sess.uuid[:8], name)
                        acted = False

                if acted or sess.finished.is_set():
                    break

                # 4. speak the reply
                if resp.text:
                    self._say(sess, resp.text)
                    messages.append({"role": "assistant", "content": resp.text})

        except Exception:
            log.exception("conversation error on call %s", sess.uuid[:8])
            try:
                self._handoff_to_specialist(sess)
            except Exception:  # pragma: no cover
                pass
        finally:
            self._cleanup_session(sess)


    # ------------------------------------------------------------------ #
    # helpers
    # ------------------------------------------------------------------ #
    def _handoff_to_specialist(self, sess: CallSession, args: dict | None = None) -> None:
        args = args or {}
        dest = args.get("extension") or self.handoff_ext
        message = args.get("message") or self.handoff_message
        self._say(sess, message)
        time.sleep(0.5)
        log.info("call %s -> handoff to %s", sess.uuid[:8], dest)
        self.esl.transfer(sess.uuid, dest, "default")
        sess.finished.set()

