"""Audio helpers: wav I/O, silence/trim, energy-based VAD.

The agent records the caller's speech (8kHz or 16kHz mono PCM16 wav) then
trims leading/trailing silence and applies a simple energy threshold before
handing the file to the STT engine. All functions use stdlib only.
"""

from __future__ import annotations

import wave

try:
    import numpy as np  # type: ignore

    HAVE_NUMPY = True
except ImportError:  # pragma: no cover
    HAVE_NUMPY = False


def read_wav(path: str) -> tuple[bytes, int]:
    """Read a wav, return (pcm16 bytes, sample_rate)."""
    with wave.open(path, "rb") as wf:
        channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        rate = wf.getframerate()
        data = wf.readframes(wf.getnframes())
    if channels != 1:
        raise ValueError(f"expected mono audio, got {channels} channels")
    if sampwidth != 2:
        raise ValueError(f"expected 16-bit PCM, got {sampwidth*8}-bit")
    return data, rate


def samples_from_bytes(data: bytes):
    """Convert PCM16 bytes to a sequence of ints (numpy if available)."""
    if HAVE_NUMPY:
        return numpy_from_bytes(data)
    import struct

    n = len(data) // 2
    return struct.unpack(f"<{n}h", data)


def numpy_from_bytes(data: bytes):
    return np.frombuffer(data, dtype=np.int16)


def energy(samples) -> float:
    """Root-mean-square energy of a sample buffer."""
    if not len(samples):
        return 0.0
    if HAVE_NUMPY:
        arr = np.asarray(samples, dtype=np.float32)
        return float(np.sqrt(np.mean(arr * arr)))
    total = 0.0
    for s in samples:
        total += s * s
    return (total / len(samples)) ** 0.5


def find_speech_bounds(samples, sample_rate: int, threshold: float, min_hold: int = 5):
    """Locate first/last frames above an energy threshold.

    A simple frame-based VAD: frames of 20ms; a frame is 'speech' if its RMS
    exceeds ``threshold``. ``min_hold`` consecutive non-speech frames are
    required to end an utterance (silence tolerance).
    """
    frame_ms = 20
    frame_len = int(sample_rate * frame_ms / 1000)
    n = len(samples)
    if n == 0:
        return None, None

    speech_flags = []
    for i in range(0, n - frame_len, frame_len):
        frame = samples[i : i + frame_len]
        speech_flags.append(energy(frame) > threshold)

    # find contiguous speech regions
    start = None
    end = None
    quiet_run = 0
    for idx, is_speech in enumerate(speech_flags):
        if is_speech:
            if start is None:
                start = idx
            end = idx
            quiet_run = 0
        else:
            quiet_run += 1
            if start is not None and quiet_run > min_hold:
                break
    if start is None:
        return None, None
    start_sample = start * frame_len
    end_sample = min(n, (end + 1) * frame_len)
    return start_sample, end_sample


def trim_silence(
    path_in: str,
    path_out: str,
    threshold: float = 800,
    sample_rate: int = 16000,
    padding_frames: int = 8,
) -> str:
    """Trim leading/trailing silence from a wav and write to path_out.

    Returns path_out. If nothing above threshold, returns the input path
    unchanged (caller decides what to do with 'no speech').
    """
    data, rate = read_wav(path_in)
    samples = samples_from_bytes(data)
    start, end = find_speech_bounds(samples, rate, threshold)
    if start is None:
        return path_in

    frame_len = int(rate * 20 / 1000)
    start = max(0, start - padding_frames * frame_len)
    end = min(len(samples), end + padding_frames * frame_len)
    trimmed = samples[start:end]

    with wave.open(path_out, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        if HAVE_NUMPY:
            wf.writeframes(np.asarray(trimmed, dtype=np.int16).tobytes())
        else:
            import struct

            wf.writeframes(struct.pack(f"<{len(trimmed)}h", *trimmed))
    return path_out


def has_speech(path: str, threshold: float = 800) -> bool:
    """Quick check whether a recording contains speech above the threshold."""
    try:
        data, rate = read_wav(path)
        samples = samples_from_bytes(data)
        start, _end = find_speech_bounds(samples, rate, threshold)
        return start is not None
    except Exception:  # pragma: no cover
        return False
