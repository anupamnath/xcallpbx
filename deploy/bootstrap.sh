#!/usr/bin/env bash
# ============================================================================ #
#  XCall — one-command VPS installer (Debian 12)
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/anupamnath/xcallpbx/main/deploy/bootstrap.sh | sudo bash
#
#  Optional args:
#    curl -fsSL https://raw.githubusercontent.com/anupamnath/xcallpbx/main/deploy/bootstrap.sh | \
#      sudo bash -s -- --domain pbx.example.com --admin-pass 'Str0ngPass' \
#                        --db-pass 'DbPass' --esl-pass 'ClueCon' --email you@example.com
#
#  FreeSWITCH note: the old public apt repos (files.freeswitch.org) now require
#  a SignalWire login, so by default FreeSWITCH is built from source
#  (~30-60 min). To use the fast official repo instead, pass a free token from
#  https://signalwire.com:
#      ... | sudo bash -s -- --signalwire-token '<token>' --domain pbx.example.com
#
#  This script:
#    1. installs git + curl
#    2. clones the XCall repo to /opt/xcall
#    3. runs deploy/provision.sh with the same arguments
# ============================================================================ #
set -euo pipefail

REPO_URL="${XCALL_REPO_URL:-https://github.com/anupamnath/xcallpbx.git}"
INSTALL_DIR="${XCALL_INSTALL_DIR:-/opt/xcall}"

if [ "$(id -u)" -ne 0 ]; then
    echo "error: run as root (sudo)." >&2
    exit 1
fi

echo "== XCall bootstrap =="
echo "repo : $REPO_URL"
echo "dir  : $INSTALL_DIR"

# git + curl are all we need to clone and run the installer
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ca-certificates

# clone (or update) the project
if [ -d "$INSTALL_DIR/.git" ]; then
    echo "updating existing XCall install at $INSTALL_DIR"
    git -C "$INSTALL_DIR" fetch --quiet origin
    git -C "$INSTALL_DIR" checkout --quiet main || git -C "$INSTALL_DIR" checkout --quiet master || true
    git -C "$INSTALL_DIR" pull --quiet --ff-only || true
else
    echo "cloning XCall -> $INSTALL_DIR"
    git clone --quiet "$REPO_URL" "$INSTALL_DIR"
fi

echo
echo "== running XCall provisioner =="
exec bash "$INSTALL_DIR/deploy/provision.sh" "$@"
