"""Speech-to-text adapters.

The agent transcribes the caller's recorded speech so the script engine can
decide the next step. Engines:

- ``whisper`` : faster-whisper (local, good quality, CPU/GPU)
- ``stub``    : returns a configurable canned transcript (testing / dry runs)

All adapters expose ``transcribe(wav_path: str) -> str``.
"""

from __future__ import annotations

import logging
import os

log = logging.getLogger("xcall.stt")


class STTError(Exception):
    """Raised when transcription fails."""


class STTEngine:
    def transcribe(self, wav_path: str) -> str:
        raise NotImplementedError

    def close(self) -> None:  # pragma: no cover
        pass


class StubSTT(STTEngine):
    """Testing adapter: returns a canned transcript (or one chosen per file)."""

    def __init__(self, text: str = "yes", mapping_file: str = ""):
        self.text = text
        self.mapping_file = mapping_file
        self._mapping: dict = {}
        if mapping_file and os.path.exists(mapping_file):
            with open(mapping_file, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line or "=" not in line:
                        continue
                    key, _, value = line.partition("=")
                    self._mapping[key.strip()] = value.strip()

    def transcribe(self, wav_path: str) -> str:
        base = os.path.basename(wav_path)
        if base in self._mapping:
            return self._mapping[base]
        return self.text


class WhisperSTT(STTEngine):
    """Local transcription via faster-whisper (https://github.com/SYSTRAN/faster-whisper)."""

    def __init__(
        self,
        model_size: str = "base",
        device: str = "cpu",
        compute_type: str = "int8",
        language: str = "en",
    ):
        self.model_size = model_size
        self.device = device
        self.compute_type = compute_type
        self.language = language
        self._model = None

    def _load(self):
        if self._model is None:
            try:
                from faster_whisper import WhisperModel
            except ImportError as exc:  # pragma: no cover
                raise STTError(
                    "faster-whisper not installed. Run: pip install faster-whisper"
                ) from exc
            log.info("loading whisper model %s on %s", self.model_size, self.device)
            self._model = WhisperModel(
                self.model_size, device=self.device, compute_type=self.compute_type
            )

    def transcribe(self, wav_path: str) -> str:
        self._load()
        segments, _info = self._model.transcribe(
            wav_path, language=self.language, beam_size=1, vad_filter=True
        )
        parts = [seg.text.strip() for seg in segments]
        text = " ".join(parts).strip()
        log.debug("STT(%s): %r", self.model_size, text)
        return text

    def close(self) -> None:  # pragma: no cover
        self._model = None


class VoskSTT(STTEngine):
    """Local transcription via vosk (lightweight, streaming-capable)."""

    def __init__(self, model_path: str = "models/vosk-model-small-en-us-0.15"):
        self.model_path = model_path
        self._model = None

    def _load(self):
        if self._model is None:
            try:
                from vosk import Model, KaldiRecognizer
            except ImportError as exc:  # pragma: no cover
                raise STTError("vosk not installed. Run: pip install vosk") from exc
            import wave

            log.info("loading vosk model from %s", self.model_path)
            self._model = Model(self.model_path)

    def transcribe(self, wav_path: str) -> str:
        import json
        import wave

        self._load()
        from vosk import KaldiRecognizer

        wf = wave.open(wav_path, "rb")
        rec = KaldiRecognizer(self._model, wf.getframerate())
        while True:
            data = wf.readframes(4000)
            if len(data) == 0:
                break
            rec.AcceptWaveform(data)
        res = json.loads(rec.FinalResult())
        text = res.get("text", "").strip()
        log.debug("STT(vosk): %r", text)
        return text


def make_stt(cfg: dict) -> STTEngine:
    """Factory based on config['stt']."""
    engine = (cfg.get("engine") or "stub").lower()
    if engine == "whisper":
        return WhisperSTT(
            model_size=cfg.get("model", "base"),
            device=cfg.get("device", "cpu"),
            compute_type=cfg.get("compute_type", "int8"),
            language=cfg.get("language", "en"),
        )
    if engine == "vosk":
        return VoskSTT(model_path=cfg.get("model_path", "models/vosk-model-small-en-us-0.15"))
    if engine == "stub":
        return StubSTT(
            text=cfg.get("stub_text", "yes"),
            mapping_file=cfg.get("stub_mapping", ""),
        )
    raise STTError(f"unknown STT engine: {engine!r}")
