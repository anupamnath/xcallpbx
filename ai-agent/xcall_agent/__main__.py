"""XCall AI agent entry point.

Run with::

    python -m xcall_agent --config config.yaml

The agent connects to FreeSWITCH over ESL, waits for calls parked into the
xcall_ai context, and runs the scripted conversation.
"""

from __future__ import annotations

import argparse
import logging
import logging.handlers
import os
import signal
import sys
import time

from .config import Config
from .esl_client import EslClient
from .llm import make_llm
from .orchestrator import VoiceAgent
from .script_engine import Script
from .stt import make_stt
from .tts import make_tts


def setup_logging(cfg: dict) -> None:
    level = getattr(logging, (cfg.get("level") or "INFO").upper(), logging.INFO)
    root = logging.getLogger()
    root.setLevel(level)

    fmt = logging.Formatter(
        "%(asctime)s %(levelname)-7s %(name)s: %(message)s", "%Y-%m-%d %H:%M:%S"
    )
    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    root.addHandler(sh)

    log_file = cfg.get("file")
    if log_file:
        try:
            os.makedirs(os.path.dirname(log_file) or ".", exist_ok=True)
            fh = logging.handlers.RotatingFileHandler(
                log_file, maxBytes=5_000_000, backupCount=3, encoding="utf-8"
            )
            fh.setFormatter(fmt)
            root.addHandler(fh)
        except OSError:
            logging.getLogger("xcall").warning("could not open log file %s", log_file)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="xcall-agent", description="XCall AI voice agent")
    parser.add_argument("--config", default="config.yaml", help="path to config.yaml")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="load config + script and exit (validation only)",
    )
    args = parser.parse_args(argv)

    config = Config.load(args.config)
    setup_logging(config.logging_cfg)
    log = logging.getLogger("xcall")

    script_path = config.script.get("file", "scripts/helpdesk_triage.yaml")
    if not os.path.isabs(script_path):
        script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", script_path)
    script = Script.load(script_path)

    stt = make_stt(config.stt)
    tts = make_tts(config.tts)
    llm = make_llm(config.llm)

    log.info(
        "XCall AI agent ready (STT=%s TTS=%s LLM=%s script=%s)",
        config.stt.get("engine"),
        config.tts.get("engine"),
        config.llm.get("engine"),
        script_path,
    )

    if args.dry_run:
        log.info("dry run complete")
        return 0

    esl = EslClient(
        host=config.esl.get("host", "127.0.0.1"),
        port=int(config.esl.get("port", 8021)),
        password=config.esl.get("password", "ClueCon"),
    )
    agent = VoiceAgent(esl, script, stt, tts, llm, config.data)
    esl.event_handler = agent.handle_event
    esl.start()
    if not esl.wait_connected(timeout=10):
        log.error("could not connect to FreeSWITCH ESL at %s:%s", config.esl.get("host"), config.esl.get("port"))
        return 1

    agent.start()

    def _shutdown(_sig, _frame):
        log.info("shutting down")
        agent.stop()
        esl.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    log.info("agent running; press Ctrl+C to stop")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        _shutdown(None, None)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
