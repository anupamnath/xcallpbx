import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tests"))

from mock_freeswitch import MockFreeSwitch  # noqa: E402
from xcall_agent.config import Config  # noqa: E402
from xcall_agent.conversational import ConversationalVoiceAgent  # noqa: E402
from xcall_agent.esl_client import EslClient, EslEvent  # noqa: E402
from xcall_agent.llm_chat import LLMResponse  # noqa: E402
from xcall_agent.stt import StubSTT  # noqa: E402
from xcall_agent.tts import StubTTS  # noqa: E402


def make_event(name, uuid, **extra):
    return EslEvent({"Event-Name": name, "Unique-ID": uuid, **extra})


class FakeLLMChat:
    """Responds from a scripted queue: (text, tool_calls) tuples."""

    def __init__(self, turns):
        self.turns = list(turns)
        self.calls = 0

    def chat(self, messages, tools=None, tool_choice="auto"):
        self.calls += 1
        if self.turns:
            return self.turns.pop(0)
        return LLMResponse("Goodbye.")


class QueueConversationalAgent(ConversationalVoiceAgent):
    def __init__(self, *args, answers=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.answers = list(answers or [])

    def _listen(self, sess, node):
        if self.answers:
            return self.answers.pop(0)
        return ""


ASSISTANT = {
    "assistant_name": "Test Assistant",
    "assistant_greeting": "Hello, this is the test assistant.",
    "assistant_instructions": "You are a support agent.",
    "assistant_provider": "openai",
    "assistant_model": "gpt-4o-mini",
    "assistant_handoff_extension": "7000",
    "assistant_handoff_message": "Holding for a specialist.",
    "assistant_max_call_seconds": 900,
    "assistant_silence_retries": 2,
}


def build_agent(mock, turns, answers):
    esl = EslClient(host="127.0.0.1", port=mock.port, password="ClueCon")
    agent = QueueConversationalAgent(
        esl, dict(ASSISTANT), FakeLLMChat(turns), StubSTT(), StubTTS(), Config().data,
        answers=answers,
    )
    esl.event_handler = agent.handle_event
    return agent, esl


def park(agent, esl, call_id):
    esl.start()
    assert esl.wait_connected(timeout=3)
    agent.start()
    agent.handle_event(
        make_event("CHANNEL_PARK", call_id, **{"Caller-Context": "xcall_ai", agent.identify_var: agent.identify_value})
    )


class TestConversationalAgent(unittest.TestCase):
    def setUp(self):
        self.mock = MockFreeSwitch(password="ClueCon")
        self.mock.start()

    def tearDown(self):
        self.mock.stop()

    def test_greeting_then_llm_reply(self):
        """The greeting plays, the LLM answers, and no tool is called."""
        turns = [LLMResponse("I can help with that.")]
        agent, esl = build_agent(self.mock, turns, ["my internet is down"])
        park(agent, esl, "call-c1")
        time.sleep(1.5)

        broadcasts = [c for c in self.mock.commands if c.startswith("uuid_broadcast")]
        # greeting + LLM reply = at least 2 playbacks
        self.assertGreaterEqual(len(broadcasts), 2)
        self.assertEqual(agent.llm_chat.calls, 1)

        agent.handle_event(make_event("CHANNEL_HANGUP", "call-c1", context="xcall_ai"))
        time.sleep(0.5)
        agent.stop()
        esl.stop()

    def test_tool_transfer(self):
        """When the LLM calls transfer_to_specialist, the agent transfers."""
        turns = [LLMResponse("", [{"name": "transfer_to_specialist", "arguments": {"extension": "7000"}}])]
        agent, esl = build_agent(self.mock, turns, ["I need a human please"])
        park(agent, esl, "call-c2")
        self.assertTrue(self.mock.wait_for_command("uuid_transfer call-c2", timeout=8))

        transfer_cmds = [c for c in self.mock.commands if c.startswith("uuid_transfer")]
        self.assertTrue(transfer_cmds)
        self.assertIn("7000", transfer_cmds[0])
        agent.stop()
        esl.stop()

    def test_tool_hangup(self):
        """When the LLM calls hang_up, the agent hangs up (no transfer)."""
        turns = [LLMResponse("", [{"name": "hang_up", "arguments": {}}])]
        agent, esl = build_agent(self.mock, turns, ["goodbye"])
        park(agent, esl, "call-c3")
        self.assertTrue(self.mock.wait_for_command("uuid_kill call-c3", timeout=8))

        transfer_cmds = [c for c in self.mock.commands if c.startswith("uuid_transfer")]
        self.assertFalse(transfer_cmds)
        agent.stop()
        esl.stop()

    def test_silence_routes_to_specialist(self):
        """Repeated silence exceeds the retry limit -> handoff."""
        agent, esl = build_agent(self.mock, [], ["", "", "", "", ""])
        park(agent, esl, "call-c4")
        self.assertTrue(self.mock.wait_for_command("uuid_transfer call-c4", timeout=8))
        transfer_cmds = [c for c in self.mock.commands if c.startswith("uuid_transfer")]
        self.assertTrue(transfer_cmds)
        agent.stop()
        esl.stop()

    def test_llm_error_handoff(self):
        """An LLM failure must still route the caller to a human."""
        class BrokenLLM:
            def chat(self, messages, tools=None, tool_choice="auto"):
                from xcall_agent.llm_chat import LLMChatError

                raise LLMChatError("boom")

        agent, esl = build_agent(self.mock, [], ["hello"])
        agent.llm_chat = BrokenLLM()
        park(agent, esl, "call-c5")
        self.assertTrue(self.mock.wait_for_command("uuid_transfer call-c5", timeout=8))
        transfer_cmds = [c for c in self.mock.commands if c.startswith("uuid_transfer")]
        self.assertTrue(transfer_cmds)
        agent.stop()
        esl.stop()


if __name__ == "__main__":
    unittest.main()
