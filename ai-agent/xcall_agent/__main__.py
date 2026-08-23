"""XCall AI agent entry point.

Run with::

    python -m xcall_agent --config config.yaml

Modes:
  - script    (default) : follow the YAML state machine (helpdesk_triage.yaml)
  - assistant           : LLM-driven conversation using the assistant
                          configured in the XCall portal (or assistant.json)

The agent connects to FreeSWITCH over ESL, waits for calls parked into the
xcall_ai context, and runs the conversation. It auto-reconnects if the ESL
connection drops (production hardening).
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

def build_script_agent(config: Config, log):
    script_path = config.script.get("file", "scripts/helpdesk_triage.yaml")
    if not os.path.isabs(script_path):
        script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", script_path)
    script = Script.load(script_path)

    stt = make_stt(config.stt)
    tts = make_tts(config.tts)
    llm = make_llm(config.llm)

    log.info(
        "script mode ready (STT=%s TTS=%s LLM=%s script=%s)",
        config.stt.get("engine"), config.tts.get("engine"),
        config.llm.get("engine"), script_path,
    )
    return script, stt, tts, llm


def build_assistant_agent(config: Config, log):
    from .assistant_config import load_assistant_config
    from .llm_chat import make_llm_chat

    acfg = config.assistant
    assistant = load_assistant_config(acfg)
    llm_chat = make_llm_chat(assistant)
    stt = make_stt(config.stt)
    tts = make_tts(config.tts)

    log.info(
        "assistant mode ready: %s (%s/%s) STT=%s TTS=%s",
        assistant.get("assistant_name"),
        assistant.get("assistant_provider"),
        assistant.get("assistant_model"),
        config.stt.get("engine"), config.tts.get("engine"),
    )
    return assistant, llm_chat, stt, tts


def run_loop(config: Config, agent, esl, log) -> None:
    """Keep ESL connected with backoff; run until SIGINT/SIGTERM."""
    def _shutdown(_sig, _frame):
        log.info("shutting down")
        agent.stop()
        esl.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    host = config.esl.get("host", "127.0.0.1")
    port = int(config.esl.get("port", 8021))
    password = config.esl.get("password", "ClueCon")
    backoff = 2

    log.info("agent running; press Ctrl+C to stop")

    while True:
        if not esl.connected:
            try:
                esl.start()
                backoff = 2
                log.info("ESL connected to %s:%s", host, port)
            except Exception as exc:
                log.error("ESL connect failed: %s (retry in %ds)", exc, backoff)
                time.sleep(backoff)
                backoff = min(backoff * 2, 60)
                continue
        time.sleep(1)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="xcall-agent", description="XCall AI voice agent")
    parser.add_argument("--config", default="config.yaml", help="path to config.yaml")
    parser.add_argument(
        "--mode",
        choices=["script", "assistant"],
        default=None,
        help="conversation engine: script (YAML) or assistant (LLM from the portal)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="load config + engine and exit (validation only)",
    )
    args = parser.parse_args(argv)

    config = Config.load(args.config)
    setup_logging(config.logging_cfg)
    log = logging.getLogger("xcall")

    mode = args.mode or config.get("agent", "mode", "script")
    if mode not in ("script", "assistant"):
        log.error("invalid agent.mode: %r", mode)
        return 1

    if mode == "assistant":
        assistant, llm_chat, stt, tts = build_assistant_agent(config, log)
        if args.dry_run:
            log.info("dry run complete")
            return 0

        from .conversational import ConversationalVoiceAgent

        esl = EslClient(
            host=config.esl.get("host", "127.0.0.1"),
            port=int(config.esl.get("port", 8021)),
            password=config.esl.get("password", "ClueCon"),
        )
        agent = ConversationalVoiceAgent(esl, assistant, llm_chat, stt, tts, config.data)
    else:
        script, stt, tts, llm = build_script_agent(config, log)
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
    agent.start()
    run_loop(config, agent, esl, log)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

