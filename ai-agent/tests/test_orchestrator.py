import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tests"))

from mock_freeswitch import MockFreeSwitch  # noqa: E402
from xcall_agent.config import Config  # noqa: E402
from xcall_agent.esl_client import EslClient, EslEvent  # noqa: E402
from xcall_agent.llm import NoneLLM  # noqa: E402
from xcall_agent.orchestrator import VoiceAgent  # noqa: E402
from xcall_agent.script_engine import Script  # noqa: E402
from xcall_agent.stt import StubSTT  # noqa: E402
from xcall_agent.tts import StubTTS  # noqa: E402


def make_event(name, uuid, **extra):
    return EslEvent({"Event-Name": name, "Unique-ID": uuid, **extra})


class QueueVoiceAgent(VoiceAgent):
    """VoiceAgent whose 'listen' step pops caller replies from a queue.

    The mock FreeSWITCH doesn't produce real wav recordings, so we bypass the
    audio recording/VAD path (covered separately by test_audio.py) and focus on
    the conversation state machine + ESL command flow.
    """

    def __init__(self, *args, answers=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.answers = list(answers or [])

    def _listen(self, sess, node):
        if self.answers:
            return self.answers.pop(0)
        return ""


def build_agent(answers, mock, cfg_data=None):
    script_path = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "scripts", "helpdesk_triage.yaml",
    )
    script = Script.load(script_path)
    cfg = Config()
    cfg.data.update(cfg_data or {})
    esl = EslClient(host="127.0.0.1", port=mock.port, password="ClueCon")
    agent = QueueVoiceAgent(esl, script, StubSTT(), StubTTS(), NoneLLM(), cfg.data, answers=answers)
    esl.event_handler = agent.handle_event
    return agent, esl


def park(agent, esl, call_id):
    esl.start()
    assert esl.wait_connected(timeout=3)
    agent.start()
    agent.handle_event(
        make_event(
            "CHANNEL_PARK", call_id, **{"Caller-Context": "xcall_ai", agent.identify_var: agent.identify_value}
        )
    )


class TestVoiceAgent(unittest.TestCase):
    def setUp(self):
        self.mock = MockFreeSwitch(password="ClueCon")
        self.mock.start()

    def tearDown(self):
        self.mock.stop()

    def test_full_conversation_and_handoff(self):
        """A complete call: greeting -> triage -> verify -> hold -> handoff."""
        answers = [
            "my laptop is really slow",
            "yes",                     # confirm issue
            "computer",                # triage -> hardware_details
            "it is a dell laptop",     # hardware_details (collects device)
            "aiden@example.com",       # account_verify (collects email)
        ]
        agent, esl = build_agent(answers, self.mock)
        park(agent, esl, "call-001")

        self.assertTrue(self.mock.wait_for_command("uuid_transfer call-001", timeout=10))

        transfer_cmds = [c for c in self.mock.commands if c.startswith("uuid_transfer")]
        self.assertTrue(transfer_cmds, "expected a uuid_transfer command")
        self.assertIn("7000", transfer_cmds[0])
        self.assertIn("default", transfer_cmds[0])

        # session should have been removed after handoff (finished)
        time.sleep(0.5)
        self.assertNotIn("call-001", agent.sessions)
        agent.stop()
        esl.stop()

    def test_silence_routes_to_specialist(self):
        """If the caller never answers, the agent retries a few times then
        routes to a human specialist instead of looping forever."""
        answers = ["", "", "", "", "", ""]  # more silence than no_speech_retries
        agent, esl = build_agent(answers, self.mock)
        park(agent, esl, "call-002")
        self.assertTrue(self.mock.wait_for_command("uuid_transfer call-002", timeout=10))
        transfer_cmds = [c for c in self.mock.commands if c.startswith("uuid_transfer")]
        self.assertTrue(transfer_cmds, "expected silence-triggered handoff")
        self.assertIn("7000", transfer_cmds[0])
        agent.stop()
        esl.stop()

    def test_hangup_after_greeting_does_not_transfer(self):
        """If the caller hangs up immediately, no transfer should be issued."""
        answers = ["slow computer", "yes"]
        agent, esl = build_agent(answers, self.mock)
        esl.start()
        assert esl.wait_connected(timeout=3)
        agent.start()
        # park then immediately hang up (synchronously, before the worker runs)
        agent.handle_event(
            make_event(
                "CHANNEL_PARK", "call-005", **{"Caller-Context": "xcall_ai", agent.identify_var: agent.identify_value}
            )
        )
        agent.handle_event(make_event("CHANNEL_HANGUP", "call-005", context="xcall_ai"))
        time.sleep(1.0)
        agent.stop()
        esl.stop()
        transfer_cmds = [c for c in self.mock.commands if c.startswith("uuid_transfer")]
        self.assertFalse(transfer_cmds)

    def test_agent_lines_are_played(self):
        """Agent's lines are spoken (playback commands) even with empty answers."""
        answers = ["", ""]
        agent, esl = build_agent(answers, self.mock)
        park(agent, esl, "call-003")
        time.sleep(2.5)
        playbacks = [c for c in self.mock.commands if c.startswith("uuid_broadcast")]
        self.assertTrue(playbacks, "expected at least one playback command")
        agent.stop()
        esl.stop()

    def test_handoff_transfers_with_custom_destination(self):
        """The script's handoff destination is used (not just the config default)."""
        answers = ["phone issue", "no", "phone", "aiden@example.com"]
        agent, esl = build_agent(answers, self.mock)
        park(agent, esl, "call-004")
        self.assertTrue(self.mock.wait_for_command("uuid_transfer call-004", timeout=10))
        transfer_cmds = [c for c in self.mock.commands if c.startswith("uuid_transfer")]
        self.assertTrue(transfer_cmds)
        self.assertIn("7000", transfer_cmds[0])
        agent.stop()
        esl.stop()


if __name__ == "__main__":
    unittest.main()
