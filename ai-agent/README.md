# XCall AI Agent

A Python voice agent that automates scripted inbound calls on a FreeSWITCH PBX:
it answers calls parked in the `xcall_ai` context, runs a conversation
(script → TTS → record → STT → LLM/keyword routing), and at the handoff node
plays "please hold" and transfers the caller to a human specialist.

> It never dials out. Inbound calls → agent → handoff to human.

## Layout

```
xcall_agent/
├── __main__.py        # entrypoint (python -m xcall_agent --config config.yaml)
├── config.py          # config loading + defaults
├── esl_client.py      # FreeSWITCH Event Socket client
├── orchestrator.py    # VoiceAgent: drives parked calls
├── script_engine.py   # YAML script state machine
├── stt.py             # whisper / vosk / stub
├── tts.py             # piper / espeak / stub
└── llm.py             # ollama / none
scripts/helpdesk_triage.yaml   # sample legitimate script
tests/                          # unit + mock-ESL end-to-end tests
```

## Run

```bash
pip install -r requirements.txt
cp config.example.yaml config.yaml      # edit as needed

python -m xcall_agent --config config.yaml --dry-run   # validate
python -m unittest discover -s tests -v                # tests (no PBX needed)
python -m xcall_agent --config config.yaml             # run
```

The default config uses **stub** STT/TTS/LLM so the agent runs anywhere with no
ML dependencies. See `docs/AI_AGENT.md` to enable local whisper / piper /
ollama.

## Requirements

- FreeSWITCH with `mod_event_socket` (ESL) reachable on 8021 (or your chosen
  port).
- The `xcall_ai` dialplan context parks calls with `xcall_agent=true`.
- A destination extension for handoffs (default 7000) — see
  `freeswitch/conf/dialplan/xcall_ai.xml` and `xcall_default.xml`.

## Tests

The test suite runs a mock FreeSWITCH ESL server so you can verify the full
conversation flow (greeting → triage → verify → hold → handoff) without a PBX.
