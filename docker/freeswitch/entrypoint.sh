#!/usr/bin/env bash
# XCall — FreeSWITCH container entrypoint.
#
# - generates the verto/WSS self-signed certificate if missing
# - ensures the AI spool dirs exist and are writable
# - launches FreeSWITCH with the XCall config overlay
set -euo pipefail

CERT_DIR=/etc/freeswitch/tls
mkdir -p "$CERT_DIR"

if [ ! -f "$CERT_DIR/wss.pem" ] || [ ! -f "$CERT_DIR/wss.key" ]; then
    echo "[xcall] generating self-signed cert for verto (wss)"
    openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/wss.key" \
        -out "$CERT_DIR/wss.pem" -days 825 -nodes \
        -subj "/CN=xcall" \
        -addext "subjectAltName=DNS:localhost,DNS:*.local,IP:127.0.0.1"
    cp "$CERT_DIR/wss.pem" "$CERT_DIR/wss-chain.pem"
    chown -R freeswitch:freeswitch "$CERT_DIR"
fi

mkdir -p /var/spool/xcall/recordings /var/spool/xcall/tts
chown -R freeswitch:freeswitch /var/spool/xcall

exec "$@"
