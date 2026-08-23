"""A mock FreeSWITCH ESL server for tests.

Speaks just enough of the ESL protocol to let the real EslClient connect,
authenticate, subscribe, issue api commands, and receive a scripted set of
events. This lets us exercise the VoiceAgent end-to-end without a PBX.
"""

from __future__ import annotations

import json
import socket
import threading
import time


class MockFreeSwitch:
    """Tiny in-process FreeSWITCH ESL stand-in.

    Behaviors:
      - accepts `auth <pw>` (password match enforced)
      - accepts `event plain ALL` subscription
      - handles `api <cmd>` lines; a handful of uuid_* commands are parsed and
        logged into `self.commands`; unknown commands return "+OK"
      - a test can call :meth:`push_event` to inject CHANNEL_PARK etc.
    """

    def __init__(self, host: str = "127.0.0.1", port: int = 0, password: str = "ClueCon"):
        self.host = host
        self.port = port
        self.password = password
        self.commands: list[str] = []
        self.events: list[dict] = []
        self.conns: list[socket.socket] = []
        self._srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._srv.bind((host, port))
        self._srv.listen(4)
        self.port = self._srv.getsockname()[1]
        self._thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._stop = threading.Event()

    # ------------------------------------------------------------------ #
    # lifecycle
    # ------------------------------------------------------------------ #
    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        try:
            self._srv.close()
        except OSError:
            pass
        for conn in self.conns:
            try:
                conn.close()
            except OSError:
                pass

    # ------------------------------------------------------------------ #
    # server loop
    # ------------------------------------------------------------------ #
    def _accept_loop(self) -> None:
        self._srv.settimeout(0.5)
        while not self._stop.is_set():
            try:
                conn, _addr = self._srv.accept()
            except OSError:
                continue
            self.conns.append(conn)
            t = threading.Thread(target=self._handle_conn, args=(conn,), daemon=True)
            t.start()

    def _handle_conn(self, conn: socket.socket) -> None:
        buf = b""
        conn.settimeout(0.5)
        try:
            while not self._stop.is_set():
                try:
                    chunk = conn.recv(65536)
                except socket.timeout:
                    # allow pushes from the test thread to be drained
                    continue
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
                while b"\n\n" in buf:
                    line, buf = buf.split(b"\n\n", 1)
                    self._process_line(conn, line.decode("utf-8", "replace"))
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def _process_line(self, conn: socket.socket, line: str) -> None:
        parts = line.split(None, 1)
        verb = parts[0].lower()
        arg = parts[1] if len(parts) > 1 else ""

        if verb == "auth":
            ok = arg == self.password
            self._send(
                conn,
                {"Reply-Text": "+OK accepted" if ok else "-ERR invalid"},
            )
        elif verb == "event":
            self._send(conn, {"Reply-Text": "+OK event listener enabled"})
        elif verb == "api":
            self.commands.append(arg)
            # return a realistic body for getvar-style commands
            body = self._api_body(arg)
            self._send(conn, {"Reply-Text": "+OK", "Content-Length": len(body)}, body=body)
        elif verb == "noevents":
            self._send(conn, {"Reply-Text": "+OK no events"})
        else:
            self._send(conn, {"Reply-Text": "+OK"})

    @staticmethod
    def _api_body(arg: str) -> str:
        if arg.startswith("uuid_getvar"):
            return "true\n"
        if arg.startswith("uuid_dump"):
            return "CHANNEL\n"
        return "OK\n"

    @staticmethod
    def _send(conn: socket.socket, headers: dict, body: str = "") -> None:
        out = []
        for key, value in headers.items():
            out.append(f"{key}: {value}")
        out.append("")
        out.append("")
        payload = "\n".join(out)
        if body:
            payload += body
        conn.sendall(payload.encode("utf-8"))

    # ------------------------------------------------------------------ #
    # test helpers
    # ------------------------------------------------------------------ #
    def push_event(self, name: str, uuid: str, **extra) -> None:
        """Inject an event to all connected ESL clients (headers only)."""
        headers = {
            "Event-Name": name,
            "Event-Subclass": "xcall",
            "Unique-ID": uuid,
            "Caller-Context": extra.pop("context", "xcall_ai"),
            **extra,
        }
        self.events.append(headers)
        for conn in self.conns:
            self._send(conn, headers)

    def wait_for_command(self, prefix: str, timeout: float = 5.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if any(cmd.startswith(prefix) for cmd in self.commands):
                return True
            time.sleep(0.05)
        return False

    def wait_for_event_count(self, name: str, count: int, timeout: float = 5.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            n = sum(1 for ev in self.events if ev.get("Event-Name") == name)
            if n >= count:
                return True
            time.sleep(0.05)
        return False
