import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from xcall_agent.llm_chat import LLMChatClient, LLMChatError, make_llm_chat  # noqa: E402


class MockLLMServer(BaseHTTPRequestHandler):
    """Serves canned OpenAI-compatible responses and records requests."""

    responses = []
    requests = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.requests.append({
            "path": self.path,
            "body": json.loads(body or "{}"),
            "auth": self.headers.get("Authorization", ""),
        })
        payload = json.dumps(self.responses.pop(0) if self.responses else {"choices": [{"message": {"content": ""}}]})
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload.encode())

    def log_message(self, *args):  # pragma: no cover
        pass


class TestLLMChatClient(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        MockLLMServer.responses = []
        MockLLMServer.requests = []
        cls.server = HTTPServer(("127.0.0.1", 0), MockLLMServer)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_text_reply(self):
        MockLLMServer.responses = [{"choices": [{"message": {"content": "Hello!"}}]}]
        MockLLMServer.requests = []
        client = LLMChatClient(base_url=f"http://127.0.0.1:{self.port}/v1", api_key="k", model="m")
        resp = client.chat([{"role": "user", "content": "hi"}])
        self.assertEqual(resp.text, "Hello!")
        self.assertFalse(resp.has_tools)
        self.assertEqual(MockLLMServer.requests[0]["auth"], "Bearer k")
        self.assertEqual(MockLLMServer.requests[0]["body"]["model"], "m")

    def test_content_parts(self):
        MockLLMServer.responses = [{"choices": [{"message": {"content": [{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]}}]}]
        client = LLMChatClient(base_url=f"http://127.0.0.1:{self.port}/v1")
        resp = client.chat([{"role": "user", "content": "hi"}])
        self.assertEqual(resp.text, "a b")

    def test_tool_call(self):
        MockLLMServer.responses = [{
            "choices": [{"message": {
                "content": "",
                "tool_calls": [{"function": {"name": "transfer_to_specialist",
                                              "arguments": "{\"extension\": \"7777\"}"}}]
            }}]
        }]
        client = LLMChatClient(base_url=f"http://127.0.0.1:{self.port}/v1")
        resp = client.chat([{"role": "user", "content": "please escalate"}], tools=[])
        self.assertTrue(resp.has_tools)
        self.assertEqual(resp.tool_calls[0]["name"], "transfer_to_specialist")
        self.assertEqual(resp.tool_calls[0]["arguments"]["extension"], "7777")

    def test_bad_response_shape(self):
        MockLLMServer.responses = [{"unexpected": True}]
        client = LLMChatClient(base_url=f"http://127.0.0.1:{self.port}/v1")
        with self.assertRaises(LLMChatError):
            client.chat([{"role": "user", "content": "hi"}])

    def test_connection_error(self):
        client = LLMChatClient(base_url="http://127.0.0.1:1/v1", timeout=1)
        with self.assertRaises(LLMChatError):
            client.chat([{"role": "user", "content": "hi"}])

    def test_make_llm_chat_defaults(self):
        cfg = {"assistant_provider": "openai", "assistant_api_base_url": "", "assistant_model": ""}
        client = make_llm_chat(cfg)
        self.assertEqual(client.base_url, "https://api.openai.com/v1")
        self.assertEqual(client.model, "gpt-4o-mini")

    def test_make_llm_chat_ollama_strips_v1(self):
        cfg = {"assistant_provider": "ollama", "assistant_api_base_url": "http://127.0.0.1:11434/v1", "assistant_model": "llama3.1"}
        client = make_llm_chat(cfg)
        self.assertEqual(client.base_url, "http://127.0.0.1:11434")

    def test_make_llm_chat_local_providers(self):
        # LM Studio
        client = make_llm_chat({"assistant_provider": "lmstudio"})
        self.assertEqual(client.base_url, "http://127.0.0.1:1234/v1")
        self.assertEqual(client.model, "local-model")
        # vLLM
        client = make_llm_chat({"assistant_provider": "vllm"})
        self.assertEqual(client.base_url, "http://127.0.0.1:8000/v1")
        # llama.cpp
        client = make_llm_chat({"assistant_provider": "llamacpp", "assistant_model": "llama-2-7b"})
        self.assertEqual(client.base_url, "http://127.0.0.1:8080/v1")
        self.assertEqual(client.model, "llama-2-7b")
        # LocalAI
        client = make_llm_chat({"assistant_provider": "localai"})
        self.assertEqual(client.base_url, "http://127.0.0.1:8080/v1")

    def test_local_provider_uses_openai_compatible_path(self):
        # a local provider with a reachable base URL should hit /chat/completions
        MockLLMServer.responses = [{"choices": [{"message": {"content": "local hello"}}]}]
        MockLLMServer.requests = []
        cfg = {
            "assistant_provider": "lmstudio",
            "assistant_api_base_url": f"http://127.0.0.1:{self.port}/v1",
            "assistant_model": "local-model",
        }
        client = make_llm_chat(cfg)
        self.assertEqual(client.provider, "lmstudio")
        resp = client.chat([{"role": "user", "content": "hi"}])
        self.assertEqual(resp.text, "local hello")
        self.assertTrue(MockLLMServer.requests[0]["path"].endswith("/chat/completions"))


if __name__ == "__main__":
    unittest.main()
