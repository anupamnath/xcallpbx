#!/usr/bin/env bash
# XCall — one-shot installer for a bare Ubuntu 22.04 / Debian 12 server.
#
# Installs FreeSWITCH + FusionPBX, applies the XCall rebrand, configures the
# AI agent as a systemd service, and prints the finishing steps.
#
# Run as root:
#   sudo bash deploy/install.sh
#
# This mirrors the FusionPBX official installer, then layers the XCall
# configuration on top. For production, run the FusionPBX installer yourself
# first (it may have version-specific steps) and use this script for the
# XCall layer only.

set -euo pipefail

X_DOMAIN="${X_DOMAIN:-xcall.local}"
PBX_ROOT="${PBX_ROOT:-/var/www/fusionpbx}"
ESL_PASSWORD="${ESL_PASSWORD:-ClueCon}"

echo "== XCall installer (Ubuntu/Debian) =="

# ---- 0. prerequisites -------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "run as root: sudo bash $0" >&2
    exit 1
fi

# ---- 1. FreeSWITCH + FusionPBX (official installer) --------------------
if ! command -v fs_cli >/dev/null 2>&1; then
    echo "installing FreeSWITCH + FusionPBX via official installer ..."
    wget -O - https://raw.githubusercontent.com/fusionpbx/fusionpbx-install.sh/master/ubuntu/pre-install.sh | sh
    cd /usr/src/fusionpbx-install.sh/ubuntu && ./install.sh
    echo "FreeSWITCH + FusionPBX installed."
fi

# ---- 2. XCall FreeSWITCH overlay ---------------------------------------
echo "applying XCall FreeSWITCH config ..."
cp -r "$(dirname "$0")/../freeswitch/conf/"* /etc/freeswitch/
mkdir -p /etc/freeswitch/tls
openssl req -x509 -newkey rsa:2048 -keyout /etc/freeswitch/tls/wss.key \
    -out /etc/freeswitch/tls/wss.pem -days 825 -nodes \
    -subj "/CN=${X_DOMAIN}" \
    -addext "subjectAltName=DNS:${X_DOMAIN},DNS:localhost,IP:127.0.0.1"
cat /etc/freeswitch/tls/wss.pem > /etc/freeswitch/tls/wss-chain.pem
chown -R freeswitch:freeswitch /etc/freeswitch/tls

mkdir -p /var/spool/xcall/recordings /var/spool/xcall/tts
chown -R freeswitch:freeswitch /var/spool/xcall

# ---- 3. XCall portal rebrand --------------------------------------------
echo "rebranding portal -> XCall ..."
bash "$(dirname "$0")/../portal/rebrand/install-rebrand.sh" "$PBX_ROOT"

# ---- 4. AI agent (systemd) ----------------------------------------------
echo "installing AI agent ..."
AI_DIR=/opt/xcall/ai-agent
mkdir -p "$AI_DIR"
cp -r "$(dirname "$0")/../ai-agent/." "$AI_DIR/"
cd "$AI_DIR"
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt

# config with the real ESL password
sed -e "s/^\(\s*password:\).*/\1 \"${ESL_PASSWORD}\"/" \
    -e 's/^\(\s*host:\).*/\1 "127.0.0.1"/' \
    config.example.yaml > config.yaml

install -m 644 "$(dirname "$0")/xcall-agent.service" /etc/systemd/system/xcall-agent.service
systemctl daemon-reload
systemctl enable --now xcall-agent.service

# ---- 5. done ------------------------------------------------------------
echo
echo "=== XCall installed ==="
echo "  Portal:    https://${X_DOMAIN}/   (set the hostname/DNS first)"
echo "  AI agent:  systemctl status xcall-agent"
echo "  Softphone: log in to the portal, then open /webphone/"
echo
echo "Next steps:"
echo "  1. Finish the FusionPBX web installer (first visit to the portal)."
echo "  2. In the portal, set the theme custom_css = /themes/default/images/xcall.css"
echo "  3. Create a specialist extension 7000 with WebRTC enabled."
echo "  4. Route inbound calls to extension ${xcall_ai_extension:-5000} or the xcall_ai context."
