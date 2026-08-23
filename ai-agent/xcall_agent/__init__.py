"""XCall AI Agent.

A Python voice agent that connects to FreeSWITCH over the Event Socket (ESL),
runs a scripted conversation (TTS prompt -> record caller -> STT -> LLM decision),
and at the script's handoff point forwards the call to a human specialist.

This is the "brain" that makes an inbound call behave like a polite first-line
support agent. It never places outbound calls on its own; FreeSWITCH routes the
inbound call into the agent, and the agent transfers it back to FreeSWITCH for the
handoff to a human.
"""

__version__ = "1.0.0"
