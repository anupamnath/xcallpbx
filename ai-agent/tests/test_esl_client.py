import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tests"))

from mock_freeswitch import MockFreeSwitch  # noqa: E402
from xcall_agent.esl_client import EslClient, EslError, EslEvent  # noqa: E402


class TestEslClient(unittest.TestCase):
    def setUp(self):
        self.mock = MockFreeSwitch(password="ClueCon")
        self.mock.start()

    def tearDown(self):
        self.mock.stop()

    def test_connect_auth_subscribe(self):
        client = EslClient(host="127.0.0.1", port=self.mock.port, password="ClueCon")
        client.start()
        self.assertTrue(client.wait_connected(timeout=3))
        self.assertTrue(client.connected)
        client.stop()

    def test_bad_password_raises(self):
        client = EslClient(host="127.0.0.1", port=self.mock.port, password="wrong")
        with self.assertRaises(EslError):
            client.start()
        client.stop()

    def test_api_command(self):
        client = EslClient(host="127.0.0.1", port=self.mock.port, password="ClueCon")
        client.start()
        client.wait_connected(timeout=3)
        result = client.api("uuid_getvar abc123 xcall_agent")
        self.assertIn("true", result)
        self.assertTrue(self.mock.wait_for_command("uuid_getvar abc123"))
        client.stop()

    def test_events_delivered(self):
        import time

        received = []

        def handler(ev):
            received.append(ev)

        client = EslClient(host="127.0.0.1", port=self.mock.port, password="ClueCon", event_handler=handler)
        client.start()
        client.wait_connected(timeout=3)
        self.mock.push_event("CHANNEL_PARK", "abc-123", context="xcall_ai")
        self.mock.push_event("CHANNEL_HANGUP", "abc-123", context="xcall_ai")

        deadline = time.time() + 3.0
        while len(received) < 2 and time.time() < deadline:
            time.sleep(0.05)
        client.stop()
        names = [ev.name for ev in received]
        self.assertIn("CHANNEL_PARK", names)
        self.assertIn("CHANNEL_HANGUP", names)
        self.assertEqual(received[0].uuid, "abc-123")


class TestEslEvent(unittest.TestCase):
    def test_properties(self):
        ev = EslEvent({"Event-Name": "DTMF", "Unique-ID": "u1", "DTMF-Digit": "5"})
        self.assertEqual(ev.name, "DTMF")
        self.assertEqual(ev.uuid, "u1")
        self.assertEqual(ev.get("DTMF-Digit"), "5")


if __name__ == "__main__":
    unittest.main()
