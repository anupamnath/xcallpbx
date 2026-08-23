"""Tests for audio helpers: VAD, silence trimming, speech detection."""

import os
import struct
import sys
import tempfile
import unittest
import wave

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from xcall_agent.audio import (  # noqa: E402
    find_speech_bounds,
    has_speech,
    read_wav,
    trim_silence,
)


def write_wav(path, samples, rate=16000):
    with wave.open(path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        wf.writeframes(struct.pack(f"<{len(samples)}h", *samples))


class TestAudioHelpers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="xcall_audio_")

    def tearDown(self):
        import shutil

        shutil.rmtree(self.tmp, ignore_errors=True)

    def _sample(self, seconds, value=0):
        return [value] * int(16000 * seconds)

    def test_has_speech_detects_tone(self):
        # 2s of silence then 1s of loud tone
        samples = self._sample(2, 0) + self._sample(1, 8000)
        path = os.path.join(self.tmp, "tone.wav")
        write_wav(path, samples)
        self.assertTrue(has_speech(path, threshold=1000))

    def test_has_speech_silence(self):
        path = os.path.join(self.tmp, "silence.wav")
        write_wav(path, self._sample(2, 0))
        self.assertFalse(has_speech(path, threshold=1000))

    def test_find_speech_bounds(self):
        samples = self._sample(0.5, 0) + self._sample(0.5, 10000) + self._sample(0.5, 0)
        start, end = find_speech_bounds(samples, 16000, threshold=1000)
        self.assertIsNotNone(start)
        self.assertIsNotNone(end)
        self.assertGreater(end, start)
        # start should be inside the tone region (after 0.5s of silence)
        self.assertGreater(start, 16000 * 0.3)
        self.assertLess(start, 16000 * 0.8)

    def test_trim_silence_writes_shorter_file(self):
        samples = self._sample(1, 0) + self._sample(1, 8000) + self._sample(1, 0)
        src = os.path.join(self.tmp, "src.wav")
        dst = os.path.join(self.tmp, "trim.wav")
        write_wav(src, samples)
        result = trim_silence(src, dst, threshold=1000)
        self.assertEqual(result, dst)
        data, rate = read_wav(dst)
        n_frames = len(data) // 2
        self.assertLess(n_frames, len(samples))
        self.assertGreater(n_frames, 0)

    def test_trim_silence_all_silence_returns_source(self):
        src = os.path.join(self.tmp, "quiet.wav")
        dst = os.path.join(self.tmp, "quiet_trim.wav")
        write_wav(src, self._sample(1, 0))
        result = trim_silence(src, dst, threshold=1000)
        self.assertEqual(result, src)


if __name__ == "__main__":
    unittest.main()
