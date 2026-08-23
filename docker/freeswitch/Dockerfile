# XCall — FreeSWITCH image.
#
# Base: signalwire's FreeSWITCH Docker image (Ubuntu + FreeSWITCH). We overlay
# the XCall config and enable the verto/WebRTC + ESL endpoints.
#
# Note: if you need mod_audio_stream / mod_audio_fork for real-time bidirectional
# audio to an external AI, replace the base image with a source build that
# compiles those modules (see docs/AI_AGENT.md for the build notes). The stock
# image includes mod_verto + mod_event_socket + mod_shell_stream, which is all
# the ESL turn-based agent requires.

FROM signalwire/freeswitch:latest

# FreeSWITCH needs a couple of shared libs present in the base
USER root

# install helper tools + cert tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssl \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Overlay XCall config
COPY freeswitch/conf/ /etc/freeswitch/

# TLS certs for verto (wss). Regenerated on container start if missing.
COPY docker/freeswitch/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Mount points for AI agent audio
RUN mkdir -p /var/spool/xcall/recordings /var/spool/xcall/tts \
    && chown -R freeswitch:freeswitch /var/spool/xcall

USER freeswitch
ENTRYPOINT ["/entrypoint.sh"]
CMD ["freeswitch", "-nonat", "-nf"]
