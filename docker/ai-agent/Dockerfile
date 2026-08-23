# XCall — AI voice agent image.
#
# A self-contained build of the ai-agent service. STT/TTS default to "stub"
# engines (no ML model downloads) so the container runs anywhere; set the env
# vars to enable local whisper/piper/ollama engines (see .env.example and
# ai-agent/config.example.yaml).

FROM python:3.12-slim

# system deps: espeak-ng (fallback TTS), ffmpeg (audio), curl
RUN apt-get update && apt-get install -y --no-install-recommends \
        espeak-ng \
        ffmpeg \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# deps first (caching)
COPY ai-agent/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# app
COPY ai-agent/ ./ai-agent/
ENV PYTHONPATH=/app/ai-agent
WORKDIR /app/ai-agent

# writable spool + cache
RUN mkdir -p /app/ai-agent/tts_cache /var/spool/xcall/recordings \
    && mkdir -p /app/ai-agent/logs

# default config (copy example; operators can mount their own config.yaml)
RUN cp /app/ai-agent/config.example.yaml /app/ai-agent/config.yaml

CMD ["python", "-m", "xcall_agent", "--config", "/app/ai-agent/config.yaml"]
