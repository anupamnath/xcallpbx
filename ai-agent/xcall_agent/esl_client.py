"""Minimal Event Socket (ESL) client for FreeSWITCH.

Implements just enough of the ESL protocol (documented at
https://docs.freeswitch.org) to:

- connect + authenticate
- issue `api` commands (e.g. uuid_record, uuid_playback, uuid_transfer)
- subscribe to events and receive them as objects

The agent uses this to drive a parked call: play TTS prompts, record the
caller's speech, and finally transfer to a human specialist.

Only Python stdlib (socket, threading) is used so this runs anywhere.
"""

from __future__ import annotations

import logging
import socket
import threading
import time
from typing import Callable, Optional

log = logging.getLogger("xcall.esl")


class EslError(Exception):
    """Raised when FreeSWITCH returns an error or the connection fails."""


class EslEvent:
    """A parsed ESL event (headers + optional content body)."""

    def __init__(self, headers: dict, body: str = ""):
        self.headers = headers
        self.body = body

    @property
    def name(self) -> str:
        return self.headers.get("Event-Name", "")

    @property
    def uuid(self) -> str:
        return self.headers.get("Unique-ID", self.headers.get("Core-UUID", ""))

    def get(self, key: str, default: str = "") -> str:
        return self.headers.get(key, default)

    def __repr__(self) -> str:  # pragma: no cover
        return f"<EslEvent {self.name} uuid={self.uuid}>"


class EslClient:
    """ESL client running on a background thread.

    Use :meth:`start` to connect and :meth:`stop` to disconnect.  Events are
    delivered to ``event_handler`` (callable taking an ``EslEvent``).
    """

    RECV_BUFSIZE = 65536

    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 8021,
        password: str = "ClueCon",
        event_handler: Optional[Callable[[EslEvent], None]] = None,
        connect_timeout: float = 5.0,
    ):
        self.host = host
        self.port = port
        self.password = password
        self.event_handler = event_handler
        self.connect_timeout = connect_timeout

        self._sock: Optional[socket.socket] = None
        self._lock = threading.Lock()
        self._recv_thread: Optional[threading.Thread] = None
        self._running = threading.Event()
        self._connected = threading.Event()
        # single-reader reply routing: api() waits on this condition while the
        # recv thread parses every block and hands command replies back.
        self._reply_cond = threading.Condition()
        self._pending_reply: Optional[tuple[dict, str]] = None

    # ------------------------------------------------------------------ #
    # lifecycle
    # ------------------------------------------------------------------ #
    def start(self) -> None:
        """Connect and authenticate. Raises EslError on failure."""
        self._connect()
        self._send(f"auth {self.password}\n\n")
        reply = self._read_reply()
        if "Reply-Text" not in reply or "OK" not in reply.get("Reply-Text", ""):
            raise EslError(f"ESL auth failed: {reply.get('Reply-Text', reply)}")
        # subscribe to the events the agent needs
        self._send("event plain ALL\n\n")
        reply = self._read_reply()
        if "Reply-Text" not in reply:
            raise EslError(f"ESL event subscribe failed: {reply}")

        self._connected.set()
        self._running.set()
        self._recv_thread = threading.Thread(
            target=self._recv_loop, name="esl-recv", daemon=True
        )
        self._recv_thread.start()
        log.info("ESL connected to %s:%s", self.host, self.port)

    def stop(self) -> None:
        self._running.clear()
        self._connected.clear()
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        if self._recv_thread and self._recv_thread.is_alive():
            self._recv_thread.join(timeout=3)
        log.info("ESL disconnected")

    @property
    def connected(self) -> bool:
        return self._connected.is_set()

    def wait_connected(self, timeout: float = 10.0) -> bool:
        return self._connected.wait(timeout)


    # ------------------------------------------------------------------ #
    # low level
    # ------------------------------------------------------------------ #
    def _connect(self) -> None:
        sock = socket.create_connection(
            (self.host, self.port), timeout=self.connect_timeout
        )
        sock.settimeout(1.0)
        self._sock = sock

    def _send(self, data: str) -> None:
        if not self._sock:
            raise EslError("ESL not connected")
        with self._lock:
            self._sock.sendall(data.encode("utf-8"))

    def _read_reply(self) -> dict:
        """Read one reply/event block (headers only). Used for command replies."""
        headers, _body = self._read_block(self._sock.recv)
        return headers

    def _read_block(self, recv_fn) -> tuple[dict, str]:
        """Read a full ESL block: headers + optional body (via Content-Length)."""
        buf = b""
        headers: dict = {}

        # read until we hit a blank line -> end of headers
        while b"\n\n" not in buf:
            chunk = recv_fn(self.RECV_BUFSIZE)
            if not chunk:
                raise EslError("ESL connection closed while reading headers")
            buf += chunk

        header_data, rest = buf.split(b"\n\n", 1)
        for line in header_data.decode("utf-8", "replace").split("\n"):
            line = line.strip()
            if not line or ":" not in line:
                continue
            key, _, value = line.partition(":")
            headers[key.strip()] = value.strip()

        # body
        content_length = int(headers.get("Content-Length", 0) or 0)
        body = ""
        if content_length > 0:
            body_buf = rest
            while len(body_buf) < content_length:
                chunk = recv_fn(self.RECV_BUFSIZE)
                if not chunk:
                    raise EslError("ESL connection closed while reading body")
                body_buf += chunk
            body = body_buf[:content_length].decode("utf-8", "replace")

        return headers, body

    def _recv_loop(self) -> None:
        """Read events in a loop and dispatch them.

        Command replies (blocks with a ``Reply-Text`` header) are routed to a
        waiting ``api()`` caller; everything else is delivered to the event
        handler. A single reader avoids socket read races.
        """
        try:
            while self._running.is_set() and self._sock:
                try:
                    headers, body = self._read_block(self._sock.recv)
                except socket.timeout:
                    continue
                except (OSError, EslError) as exc:  # pragma: no cover
                    log.debug("recv loop ending: %s", exc)
                    break

                # route command replies to a waiting api() caller
                if "Reply-Text" in headers:
                    with self._reply_cond:
                        self._pending_reply = (headers, body)
                        self._reply_cond.notify_all()
                    continue

                event = EslEvent(headers, body)
                if self.event_handler:
                    try:
                        self.event_handler(event)
                    except Exception:  # never let a handler kill the loop
                        log.exception("event handler failed")
        finally:
            self._connected.clear()
            log.info("ESL receive loop ended")

    # ------------------------------------------------------------------ #
    # commands
    # ------------------------------------------------------------------ #
    def api(self, command: str, timeout: float = 10.0) -> str:
        """Run a synchronous FreeSWITCH API command, return reply body.

        The command is sent, then the caller waits on a condition until the
        recv thread delivers the matching ``Reply-Text`` block.  This keeps a
        single reader on the socket (no races with the event stream).
        """
        if not self._sock:
            raise EslError("ESL not connected")
        log.debug("api: %s", command)
        with self._lock:
            self._sock.sendall(f"api {command}\n\n".encode("utf-8"))

        deadline = time.monotonic() + timeout
        with self._reply_cond:
            while not self._pending_reply:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise EslError(f"api {command!r} timed out after {timeout}s")
                self._reply_cond.wait(timeout=remaining)
            reply, body = self._pending_reply
            self._pending_reply = None

        if "Reply-Text" in reply and "ERROR" in reply["Reply-Text"]:
            raise EslError(f"api {command!r} failed: {reply['Reply-Text']}")
        return body

    def bgapi(self, command: str) -> str:
        """Run an asynchronous FreeSWITCH API command."""
        return self.api(command)

    # ------------------------------------------------------------------ #
    # high-level helpers used by the agent
    # ------------------------------------------------------------------ #
    def answer(self, uuid: str) -> None:
        self.api(f"uuid_answer {uuid}")

    def park(self, uuid: str) -> None:
        self.api(f"uuid_park {uuid}")

    def playback(self, uuid: str, file_path: str) -> None:
        """Play a file to a channel (non-blocking broadcast)."""
        self.api(f"uuid_broadcast {uuid} playback::{file_path} aleg")

    def record_start(self, uuid: str, file_path: str, max_seconds: int = 15) -> None:
        """Start recording a channel's audio to a wav file."""
        self.api(f"uuid_record {uuid} start {file_path} {max_seconds}")

    def record_stop(self, uuid: str) -> None:
        self.api(f"uuid_record {uuid} stop")

    def set_var(self, uuid: str, name: str, value: str) -> None:
        self.api(f"uuid_setvar {uuid} {name} {value}")

    def get_var(self, uuid: str, name: str) -> str:
        return self.api(f"uuid_getvar {uuid} {name}").strip()

    def hangup(self, uuid: str, cause: str = "NORMAL_CLEARING") -> None:
        self.api(f"uuid_kill {uuid} {cause}")

    def transfer(self, uuid: str, destination: str, context: str = "default") -> None:
        """Transfer a channel to a dialplan extension (rings the specialist)."""
        self.api(f"uuid_transfer {uuid} {destination} xml {context}")

    def originate(
        self,
        endpoint: str,
        dest_url: str,
        timeout: int = 30,
        vars: Optional[dict] = None,
    ) -> str:
        """Place a call leg (used to warm up / test; agent does not dial out normally)."""
        var_str = " ".join(f"{{{k}={v}}}" for k, v in (vars or {}).items())
        cmd = f"originate {var_str}{endpoint}/{dest_url} &park {timeout}"
        return self.api(cmd).strip()

    def channel_status(self, uuid: str) -> str:
        try:
            return self.api(f"uuid_dump {uuid}")
        except EslError:
            return ""


class JsonEslClient(EslClient):
    """ESL client variant that requests JSON event bodies (useful for DTMF etc.)."""

    def start(self) -> None:
        super().start()
        self._send("event json ALL\n\n")
        self._read_reply()

