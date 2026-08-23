"""Call session + orchestrator: runs a scripted conversation on a parked call.

Flow (driven by FreeSWITCH over ESL):

1. FreeSWITCH receives an inbound call and parks it into the ``xcall_ai``
   context (see freeswitch/conf/dialplan).
2. The agent sees CHANNEL_PARK with the identifying channel variable,
   answers the call and runs the script node by node:
     - speak the node's prompt (TTS -> wav -> uuid_broadcast playback)
     - record the caller's answer (uuid_record start/stop)
     - trim silence + transcribe (STT)
     - classify (LLM / keywords) and advance to the next node
3. When the script reaches a ``handoff`` action node, the agent plays a hold
   message and transfers the call to the human specialist's extension.
4. CHANNEL_HANGUP cleans up the session.

This module is framework-agnostic: it receives an ``EslClient`` and the config.
"""

from __future__ import annotations

import logging
import os
import threading
import time
import uuid as uuidlib

from .audio import has_speech, trim_silence
from .esl_client import EslClient, EslEvent
from .llm import LLMEngine
from .script_engine import Script, ScriptNode
from .stt import STTEngine
from .tts import TTSEngine

log = logging.getLogger("xcall.orchestrator")


class CallSession:
    """State for a single call being handled by the agent."""

    def __init__(self, uuid: str):
        self.uuid = uuid
        self.context: dict = {}
        self.node_id: str = ""
        self.started_at = time.time()
        self.recordings_dir = ""
        self.last_recording = ""
        self.silent_count = 0
        self.finished = threading.Event()

    @property
    def elapsed(self) -> float:
        return time.time() - self.started_at


class VoiceAgent:
    """Top-level agent: owns the ESL connection and drives call sessions."""

    def __init__(
        self,
        esl: EslClient,
        script: Script,
        stt: STTEngine,
        tts: TTSEngine,
        llm: LLMEngine,
        cfg: dict,
    ):
        self.esl = esl
        self.script = script
        self.stt = stt
        self.tts = tts
        self.llm = llm
        self.cfg = cfg  # full config.data

        self.identify_var = cfg.get("agent", {}).get("identify_var", "xcall_agent")
        self.identify_value = cfg.get("agent", {}).get("identify_value", "true")
        self.timing = cfg.get("timing", {})
        self.rec_cfg = cfg.get("recording", {})
        self.handoff_cfg = cfg.get("handoff", {})

        self.sessions: dict[str, CallSession] = {}
        self._lock = threading.Lock()
        self._running = False
        self._esl_thread: threading.Thread | None = None

    # ------------------------------------------------------------------ #
    # lifecycle
    # ------------------------------------------------------------------ #
    def start(self) -> None:
        self._running = True
        self._esl_thread = threading.Thread(target=self._event_loop, daemon=True)
        self._esl_thread.start()
        log.info("agent started; identify var %s=%s", self.identify_var, self.identify_value)

    def stop(self) -> None:
        self._running = False
        with self._lock:
            sessions = list(self.sessions.values())
        for sess in sessions:
            self._cleanup_session(sess)
        log.info("agent stopped")

    # ------------------------------------------------------------------ #
    # event handling
    # ------------------------------------------------------------------ #
    def _event_loop(self) -> None:
        """Background: watch for call events and drive sessions."""
        while self._running:
            # New calls are detected by the external event handler set on the
            # EslClient (see run.py). Here we only reap finished sessions.
            self._reap_finished()
            time.sleep(0.5)

    def _reap_finished(self) -> None:
        now = time.time()
        with self._lock:
            dead = [u for u, s in self.sessions.items() if s.finished.is_set()]
            for u in dead:
                self.sessions.pop(u, None)

    def handle_event(self, event: EslEvent) -> None:
        """Dispatch an ESL event (wired as the client's event_handler)."""
        name = event.name
        if name == "CHANNEL_PARK":
            self._on_channel_park(event)
        elif name == "CHANNEL_ANSWER":
            self._on_channel_answer(event)
        elif name == "CHANNEL_HANGUP":
            self._on_channel_hangup(event)
        elif name == "DTMF":
            self._on_dtmf(event)
        elif name == "RECORD_STOP":
            self._on_record_stop(event)

    # ------------------------------------------------------------------ #
    # event handlers
    # ------------------------------------------------------------------ #
    def _on_channel_park(self, event: EslEvent) -> None:
        uuid = event.uuid
        ctx = event.get("Caller-Context", "")
        ident = event.get(self.identify_var, "")
        if ctx != self.cfg.get("agent", {}).get("context", "xcall_ai"):
            return
        if ident != self.identify_value:
            return
        log.info("handling parked call %s", uuid)
        sess = CallSession(uuid)
        with self._lock:
            self.sessions[uuid] = sess
        threading.Thread(
            target=self._run_conversation, args=(sess,), daemon=True, name=f"call-{uuid[:8]}"
        ).start()

    def _on_channel_answer(self, event: EslEvent) -> None:
        pass  # conversation is driven from park

    def _on_channel_hangup(self, event: EslEvent) -> None:
        uuid = event.uuid
        with self._lock:
            sess = self.sessions.get(uuid)
        if sess:
            log.info("call %s hung up", uuid)
            self._cleanup_session(sess)

    def _on_dtmf(self, event: EslEvent) -> None:
        pass

    def _on_record_stop(self, event: EslEvent) -> None:
        pass  # handled by recording loop timing


    # ------------------------------------------------------------------ #
    # conversation loop
    # ------------------------------------------------------------------ #
    def _run_conversation(self, sess: CallSession) -> None:
        """Execute the script against a parked call."""
        node_id = self.script.start
        sess.node_id = node_id
        try:
            while self._running and not sess.finished.is_set():
                if self._over_time(sess):
                    self._say(sess, "I am sorry, but I seem to be having trouble. "
                                    "Please call back, thank you.")
                    break
                node = self.script.get(node_id)
                log.info("call %s node=%s", sess.uuid[:8], node_id)
                next_id = self._run_node(sess, node)
                if next_id is None:
                    break  # action ended the call
                node_id = next_id
                sess.node_id = node_id
        except Exception:
            log.exception("conversation error on call %s", sess.uuid[:8])
        finally:
            self._cleanup_session(sess)

    def _over_time(self, sess: CallSession) -> bool:
        max_sec = self.timing.get("max_call_seconds", 900)
        return sess.elapsed > max_sec

    def _run_node(self, sess: CallSession, node: ScriptNode) -> str | None:
        """Run one script node. Returns next node id, or None to end the call."""
        # 1. speak the prompt
        if node.prompt:
            self._say(sess, node.prompt)

        # 2. action node? (handoff / hangup) — no caller input expected
        if node.action:
            return self._do_action(sess, node)

        # 3. wait for caller answer (or skip if node.wait is False)
        if not node.wait:
            return self.script.next_id(node, sess.context)

        # 4. record + transcribe the answer
        text = self._listen(sess, node)
        sess.context["last_utterance"] = text
        if text:
            sess.silent_count = 0
            if node.collect:
                sess.context[node.collect] = text
            self._log_transcript(sess, "caller", text)
        else:
            sess.silent_count += 1
            log.info(
                "call %s: no speech (attempt %d/%d)",
                sess.uuid[:8], sess.silent_count, self.timing.get("no_speech_retries", 2),
            )
            if sess.silent_count > self.timing.get("no_speech_retries", 2):
                # caller is not responding; route to a human rather than loop
                log.info("call %s: too much silence, routing to specialist", sess.uuid[:8])
                self._handoff(sess, self.handoff_cfg)
                return None
            return node.id  # re-prompt the same node

        # 5. classify with LLM when available
        if text and node.branches:
            labels = [k for k in node.branches.keys()]
            try:
                label = self.llm.classify(text, labels)
                if label in node.branches:
                    target = node.branches[label]
                    if isinstance(target, dict):
                        return target.get("next") or node.next
                    return target
            except Exception:
                log.debug("LLM unavailable; keyword matching only")

        return self.script.next_id(node, sess.context)

    def _do_action(self, sess: CallSession, node: ScriptNode) -> str | None:
        """Handle action nodes: handoff / hangup."""
        action = node.action
        atype = action.get("type")
        if atype == "handoff":
            self._handoff(sess, action)
            return None
        if atype == "hangup":
            self._say(sess, self.handoff_cfg.get("hold_message", "Thank you for calling. Goodbye."))
            time.sleep(1)
            self.esl.hangup(sess.uuid, "NORMAL_CLEARING")
            sess.finished.set()
            return None
        log.warning("unknown action type: %r", atype)
        return node.next

    def _handoff(self, sess: CallSession, action: dict) -> None:
        """Play hold message and transfer the call to a human specialist."""
        dest = action.get("destination") or self.handoff_cfg.get("destination_ext", "7000")
        context = action.get("context") or self.handoff_cfg.get("context", "default")
        message = action.get("message") or self.handoff_cfg.get(
            "hold_message",
            "Thank you for holding. I will now connect you to a specialist.",
        )
        self._say(sess, message)
        time.sleep(0.5)
        log.info("call %s -> handoff to extension %s (context %s)", sess.uuid[:8], dest, context)
        self.esl.transfer(sess.uuid, dest, context)
        sess.finished.set()


    # ------------------------------------------------------------------ #
    # speech I/O helpers
    # ------------------------------------------------------------------ #
    def _say(self, sess: CallSession, text: str) -> None:
        """Speak a line to the caller (TTS -> wav -> playback)."""
        text = self.script.template(text, sess.context)
        self._log_transcript(sess, "agent", text)
        try:
            wav = self.tts.speak(text)
        except Exception:
            log.exception("TTS failed for %r; skipping", text[:60])
            return
        try:
            self.esl.playback(sess.uuid, wav)
        except Exception:
            log.exception("playback failed on call %s", sess.uuid[:8])

    def _listen(self, sess: CallSession, node: ScriptNode) -> str:
        """Record the caller's answer, trim + transcribe it.

        Returns '' if nothing intelligible was heard (agent will re-prompt via
        the script's fallback branch).
        """
        rec_dir = self._ensure_recordings_dir(sess)
        rec_name = f"{sess.uuid[:8]}-{node.id}-{uuidlib.uuid4().hex[:6]}.wav"
        rec_path = os.path.join(rec_dir, rec_name)
        max_sec = int(self.timing.get("max_utterance_seconds", 15))

        try:
            self.esl.record_start(sess.uuid, rec_path, max_sec)
        except Exception:
            log.exception("record start failed on call %s", sess.uuid[:8])
            return ""
        # allow the caller up to max_sec to speak; end early on silence via VAD
        spoken = self._wait_for_speech(sess, rec_path, max_sec)
        try:
            self.esl.record_stop(sess.uuid)
        except Exception:
            log.exception("record stop failed on call %s", sess.uuid[:8])
        sess.last_recording = rec_path

        if not spoken:
            log.info("call %s: no speech detected in %s", sess.uuid[:8], rec_name)
            return ""

        try:
            trimmed = rec_path.replace(".wav", ".trim.wav")
            trim_silence(rec_path, trimmed, threshold=self.timing.get("vad_threshold", 800))
            text = self.stt.transcribe(trimmed)
        except Exception:
            log.exception("STT failed on call %s", sess.uuid[:8])
            return ""
        return text.strip()

    def _wait_for_speech(self, sess: CallSession, rec_path: str, max_sec: int) -> bool:
        """Poll the recording file until speech is present or time runs out."""
        deadline = time.time() + max_sec + 1.5
        while time.time() < deadline and self._running and not sess.finished.is_set():
            if os.path.exists(rec_path) and os.path.getsize(rec_path) > 0:
                if has_speech(rec_path, threshold=self.timing.get("vad_threshold", 800)):
                    # got speech; give a little extra room then stop recording
                    time.sleep(min(self.timing.get("end_of_speech_silence", 1.2), 1.2))
                    return True
            time.sleep(0.25)
        return False

    def _ensure_recordings_dir(self, sess: CallSession) -> str:
        if not sess.recordings_dir:
            base = self.rec_cfg.get("dir", "/var/spool/xcall/recordings")
            sess.recordings_dir = os.path.join(base, sess.uuid[:8])
            os.makedirs(sess.recordings_dir, exist_ok=True)
        return sess.recordings_dir

    def _log_transcript(self, sess: CallSession, who: str, text: str) -> None:
        line = f"[call {sess.uuid[:8]}] {who}: {text}"
        log.info(line)

    def _cleanup_session(self, sess: CallSession) -> None:
        """Stop the session and release resources."""
        sess.finished.set()
        with self._lock:
            self.sessions.pop(sess.uuid, None)
        log.info("session %s cleaned up", sess.uuid[:8])
