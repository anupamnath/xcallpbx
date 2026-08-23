#!/usr/bin/env bash
# XCall — web softphone vendor script.
#
# Downloads the SIP.js UMD browser build used by the in-portal softphone so
# the portal works fully offline (no CDN dependency). Run once during setup.
set -euo pipefail

VERSION="${SIPJS_VERSION:-0.15.11}"
DEST="$(dirname "$0")/vendor"
mkdir -p "$DEST"

echo "Fetching SIP.js ${VERSION} ..."
curl -fsSL "https://unpkg.com/sip.js@${VERSION}/dist/sip.min.js" -o "${DEST}/sip.min.js"

echo "Done: ${DEST}/sip.min.js ($(wc -c < "${DEST}/sip.min.js") bytes)"
echo "If the download fails (no internet), fetch sip.min.js manually and place it at ${DEST}/sip.min.js"

