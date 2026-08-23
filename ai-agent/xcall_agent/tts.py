"""Text-to-speech adapters.

The agent speaks script prompts to the caller. Engines:

- ``piper`` : local neural TTS (https://github.com/rhasspy/piper) — fast, natural
- ``espeak``: eSpeak NG fallback (robotic but always available)
- ``stub``  : writes a silent/placeholder wav (testing / dry runs)

All adapters expose ``speak(text, out_wav) -> str (path)`` and cache results.
"""

from __future__ import annotations

import hashlib
import logging
import os
import shutil
import struct
import subprocess
import wave

log = logging.getLogger("xcall.tts")


class TTSError(Exception):
    """Raised when speech synthesis fails."""


class TTSEngine:
    def __init__(self, cache_dir: str = "tts_cache", sample_rate: int = 16000):
        self.cache_dir = cache_dir
        self.sample_rate = sample_rate
        if cache_dir:
            os.makedirs(cache_dir, exist_ok=True)

    def _cache_path(self, text: str) -> str:
        key = hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]
        return os.path.join(self.cache_dir, f"{key}.wav")

    def speak(self, text: str, out_wav: str = "") -> str:
        """Synthesize text to a wav file. Returns the path written."""
        if not text.strip():
            return self.silence(out_wav)
        if self.cache_dir:
            cached = self._cache_path(text)
            if os.path.exists(cached):
                return cached
        result = self._synth(text, out_wav or cached)
        return result

    def silence(self, out_wav: str = "", seconds: float = 1.0) -> str:
        """Generate a silence wav (used as a 'no prompt' placeholder)."""
        out = out_wav or os.path.join(self.cache_dir, "_silence.wav")
        frames = int(self.sample_rate * seconds)
        with wave.open(out, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(self.sample_rate)
            wf.writeframes(b"\x00\x00" * frames)
        return out

    def _synth(self, text: str, out_wav: str) -> str:  # pragma: no cover
        raise NotImplementedError


class PiperTTS(TTSEngine):
    """Local neural TTS via the piper CLI."""

    def __init__(
        self,
        cache_dir: str = "tts_cache",
        sample_rate: int = 16000,
        piper_path: str = "piper",
        model_path: str = "models/en_US-lessac-medium.onnx",
    ):
        super().__init__(cache_dir, sample_rate)
        self.piper_path = piper_path
        self.model_path = model_path

    def _synth(self, text: str, out_wav: str) -> str:
        if shutil.which(self.piper_path) is None:
            raise TTSError(f"piper binary not found: {self.piper_path!r}")
        if not os.path.exists(self.model_path):
            raise TTSError(f"piper model not found: {self.model_path!r}")
        args = [
            self.piper_path,
            "-m", self.model_path,
            "-f", out_wav,
        ]
        try:
            proc = subprocess.run(
                args, input=text.encode("utf-8"), capture_output=True, timeout=60
            )
            if proc.returncode != 0:
                raise TTSError(
                    f"piper failed: {proc.stderr.decode('utf-8', 'replace')[:300]}"
                )
        except subprocess.TimeoutExpired as exc:
            raise TTSError("piper timed out") from exc
        return out_wav


class EspeakTTS(TTSEngine):
    """eSpeak NG — always available, robotic quality."""

    def __init__(
        self,
        cache_dir: str = "tts_cache",
        sample_rate: int = 16000,
        espeak_path: str = "espeak-ng",
    ):
        super().__init__(cache_dir, sample_rate)
        self.espeak_path = espeak_path

    def _synth(self, text: str, out_wav: str) -> str:
        if shutil.which(self.espeak_path) is None:
            raise TTSError(f"espeak-ng binary not found: {self.espeak_path!r}")
        args = [self.espeak_path, "-w", out_wav, "-s", "150", text]
        try:
            proc = subprocess.run(args, capture_output=True, timeout=60)
            if proc.returncode != 0:
                raise TTSError(
                    f"espeak failed: {proc.stderr.decode('utf-8', 'replace')[:300]}"
                )
        except subprocess.TimeoutExpired as exc:
            raise TTSError("espeak timed out") from exc
        return out_wav


class StubTTS(TTSEngine):
    """Testing adapter: writes a 1s silent wav (or a small tone) per prompt."""

    def __init__(self, cache_dir: str = "tts_cache", sample_rate: int = 16000):
        super().__init__(cache_dir, sample_rate)

    def _synth(self, text: str, out_wav: str) -> str:
        # write a short 440 Hz tone so test flows are audibly detectable
        frames = int(self.sample_rate * 0.3)
        with wave.open(out_wav, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(self.sample_rate)
            data = b"".join(
                struct.pack("<h", int(2000 * (0.5 + 0.5)))
                for _ in range(frames)
            )
            wf.writeframes(data)
        return out_wav


def make_tts(cfg: dict) -> TTSEngine:
    """Factory based on config['tts']."""
    engine = (cfg.get("engine") or "stub").lower()
    kwargs = {
        "cache_dir": cfg.get("cache_dir", "tts_cache"),
        "sample_rate": int(cfg.get("sample_rate", 16000)),
    }
    if engine == "piper":
        return PiperTTS(
            **kwargs,
            piper_path=cfg.get("piper_path", "piper"),
            model_path=cfg.get("piper_model", "models/en_US-lessac-medium.onnx"),
        )
    if engine == "espeak":
        return EspeakTTS(**kwargs, espeak_path=cfg.get("espeak_path", "espeak-ng"))
    if engine == "stub":
        return StubTTS(**kwargs)
    raise TTSError(f"unknown TTS engine: {engine!r}")
