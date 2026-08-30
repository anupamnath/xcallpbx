#!/usr/bin/env bash
# ============================================================================ #
#  XCall - self-contained Debian 12 provisioner
#
#  Installs the complete XCall system from a bare VPS. The base install is
#  delegated to FusionPBX's official installer (fusionpbx-install.sh) so the
#  FreeSWITCH source build, PostgreSQL, the FusionPBX app, schema, domain and
#  admin user are exactly what the FusionPBX project tests and ships. The
#  XCall layer is then applied on top: rebrand + admin panel + AI assistant
#  manager + WebRTC softphone + AI voice agent.
#
#  Run via bootstrap.sh (recommended):
#    curl -fsSL https://raw.githubusercontent.com/anupamnath/xcallpbx/main/deploy/bootstrap.sh | sudo bash
#
#  Options (all optional, sensible defaults for a fresh box):
#    --domain <fqdn>          public hostname (default: <hostname -f>)
#    --admin-pass <pass>      FusionPBX admin password (default: random)
#    --db-pass <pass>         postgres password for fusionpbx (default: random)
#    --esl-pass <pass>        FreeSWITCH event-socket password (default: ClueCon)
#    --email <addr>           Let's Encrypt contact email (default: none -> self-signed)
#    --install-dir <path>     repo location (default: /opt/xcall)
#    --skip-ai                skip the AI agent install (still installs the panel)
#    --signalwire-token <tok> free token from https://signalwire.com -> fast
#                             FreeSWITCH apt install. Without it FreeSWITCH is
#                             built from source (self-contained, ~30-60 min).
#
#  NOTE: passwords are restricted to alphanumerics (A-Za-z0-9) to keep them
#  safe in config files, SQL and shell. Pass plain alphanumeric passwords.
# ============================================================================ #
set -euo pipefail

# ---------------- logging helpers ------------------------------------------ #
log()  { echo -e "\e[1;36m[xcall]\e[0m $*"; }
warn() { echo -e "\e[1;33m[xcall!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[xcall!!]\e[0m $*" >&2; exit 1; }

# ---------------- args ----------------------------------------------------- #
DOMAIN=""
DOMAIN_ARG=0
ADMIN_PASS=""
DB_PASS=""
ESL_PASS="ClueCon"
EMAIL=""
INSTALL_DIR="/opt/xcall"
SKIP_AI=0
SW_TOKEN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)      DOMAIN="${2:-}"; DOMAIN_ARG=1; shift 2 ;;
        --admin-pass)  ADMIN_PASS="${2:-}"; shift 2 ;;
        --db-pass)     DB_PASS="${2:-}"; shift 2 ;;
        --esl-pass)    ESL_PASS="${2:-}"; shift 2 ;;
        --email)       EMAIL="${2:-}"; shift 2 ;;
        --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
        --skip-ai)     SKIP_AI=1; shift ;;
        --signalwire-token) SW_TOKEN="${2:-}"; shift 2 ;;
        -h|--help)     grep -E '^\s*--' "$0"; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

# ---------------- password sanitization ------------------------------------ #
# alphanumeric only: safe in config.conf (INI), SQL, heredocs, sed and YAML.
sanitize() {
    local p="${1:-}"
    p=$(printf '%s' "$p" | tr -dc 'A-Za-z0-9')
    if [ -z "$p" ]; then p=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20); fi
    printf '%s' "$p"
}
ADMIN_PASS=$(sanitize "$ADMIN_PASS")
DB_PASS=$(sanitize "$DB_PASS")
ESL_PASS=$(sanitize "$ESL_PASS")
SW_TOKEN=$(printf '%s' "$SW_TOKEN" | tr -d " '\\\"")

# ---------------- preflight ------------------------------------------------ #
[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash $0"

if [ -f /etc/os-release ]; then
    . /etc/os-release
fi
if [ "${VERSION_CODENAME:-}" != "bookworm" ]; then
    warn "Detected $PRETTY_NAME - this installer targets Debian 12 (bookworm)."
    warn "Continue anyway? (y/N)"
    read -r CONTINUE
    [ "${CONTINUE:-n}" = "y" ] || die "aborted"
fi

DOMAIN="${DOMAIN:-$(hostname -f)}"

export DEBIAN_FRONTEND=noninteractive
export TZ="${TZ:-UTC}"

log "== XCall provisioner =="
log "domain    : $DOMAIN"
log "admin     : admin / ${ADMIN_PASS:0:3}***"
log "postgres  : fusionpbx / ${DB_PASS:0:3}***"
log "esl       : $ESL_PASS"
log "repo      : $INSTALL_DIR"
[ "$SKIP_AI" -eq 1 ] && log "ai agent  : SKIPPED"

# ---------------- base packages -------------------------------------------- #
log "installing base packages"
apt-get update -qq
apt-get install -y -qq \
    sudo wget curl git gnupg lsb-release ca-certificates apt-transport-https \
    openssl ssl-cert haveged iptables 2>&1 | tail -n 1

# ---------------- clean partial state from earlier failed runs ------------- #
cleanup_partial_xcall() {
    log "cleaning partial FusionPBX state from earlier attempts"
    # remove any old XCall nginx site (the official installer sets up nginx)
    rm -f /etc/nginx/sites-enabled/xcall /etc/nginx/sites-available/xcall 2>/dev/null || true
    # keep a healthy FusionPBX web root (fast resume); remove a broken/partial one
    if [ ! -f /var/www/fusionpbx/index.php ]; then
        rm -rf /var/www/fusionpbx
        rm -f /etc/fusionpbx/config.conf
    fi
    # drop a fusionpbx database that has no schema (empty/partial)
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='fusionpbx'" 2>/dev/null | grep -q 1; then
        if ! sudo -u postgres psql -d fusionpbx -tAc "SELECT 1 FROM information_schema.tables WHERE table_name='v_domains'" 2>/dev/null | grep -q 1; then
            log "dropping empty/partial fusionpbx database"
            sudo -u postgres psql -c "DROP DATABASE IF EXISTS fusionpbx;" >/dev/null 2>&1 || true
            sudo -u postgres psql -c "DROP ROLE IF EXISTS fusionpbx;" >/dev/null 2>&1 || true
        fi
    fi
    # freeswitch DB role (used by the installer's finish.sh)
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='freeswitch'" 2>/dev/null | grep -q 1; then
        sudo -u postgres psql -c "CREATE ROLE freeswitch WITH LOGIN PASSWORD '$DB_PASS';" >/dev/null 2>&1 || true
    fi
}
cleanup_partial_xcall

# resume mode: if the FusionPBX base is already installed, skip the installer
SKIP_BASE=0
if [ -f /var/www/fusionpbx/index.php ] && \
   sudo -u postgres psql -d fusionpbx -tAc "SELECT 1 FROM v_domains" 2>/dev/null | grep -q 1; then
    SKIP_BASE=1
    log "FusionPBX base already present - resuming (skipping the official installer)"
fi

# ---------------- database credentials (resume-safe) ------------------------ #
# The FusionPBX base may have been installed earlier by the official installer,
# which generated its OWN database password and stored it in
# /etc/fusionpbx/config.conf. Never assume --db-pass matches it: prefer the
# password the running portal already uses, then --db-pass, and only as a last
# resort reset the role to --db-pass. (In a fresh install the installer just
# created the role with $DB_PASS, so this block is skipped.)
DB_PASS_ACTUAL="$DB_PASS"
if [ "$SKIP_BASE" -eq 1 ]; then
    EXISTING_DB_PASS=""
    if [ -f /etc/fusionpbx/config.conf ]; then
        EXISTING_DB_PASS=$(sed -n 's/^database\.0\.password[[:space:]]*=[[:space:]]*//p' /etc/fusionpbx/config.conf | head -n 1)
    fi
    db_connect_ok() { PGPASSWORD="$1" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -tAc "SELECT 1" >/dev/null 2>&1; }
    if [ -n "$EXISTING_DB_PASS" ] && db_connect_ok "$EXISTING_DB_PASS"; then
        DB_PASS_ACTUAL="$EXISTING_DB_PASS"
        log "using the database password already configured in /etc/fusionpbx/config.conf"
    elif db_connect_ok "$DB_PASS"; then
        DB_PASS_ACTUAL="$DB_PASS"
    elif sudo -u postgres psql -c "ALTER ROLE fusionpbx WITH PASSWORD '$DB_PASS';" >/dev/null 2>&1; then
        DB_PASS_ACTUAL="$DB_PASS"
        # keep the portal's config.conf in sync with the new role password
        if [ -f /etc/fusionpbx/config.conf ]; then
            sed -i "s|^database\.0\.password[[:space:]]*=.*|database.0.password = $DB_PASS|" /etc/fusionpbx/config.conf
        fi
        log "reset the fusionpbx database role password to match --db-pass (config.conf synced)"
    else
        die "cannot authenticate to the fusionpbx database - re-run with --db-pass '<the actual FusionPBX database password>' (the portal's copy lives in /etc/fusionpbx/config.conf)"
    fi

    # resume-safe domain: keep the domain the portal already runs unless the
    # operator explicitly passed --domain (avoids resetting nginx server_name
    # to the bare hostname on re-runs). config.conf has no domain key - the
    # authoritative value is the enabled domain row in the database.
    if [ "$DOMAIN_ARG" -eq 0 ]; then
        EXISTING_DOMAIN=$(PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -tAc \
            "select domain_name from v_domains where domain_enabled='true' order by domain_uuid limit 1;" 2>/dev/null | head -n 1)
        if [ -n "$EXISTING_DOMAIN" ]; then
            DOMAIN="$EXISTING_DOMAIN"
            log "using the domain already present in the database: $DOMAIN"
        fi
    fi

    # resume-safe event-socket password: reuse the one FreeSWITCH already runs
    # (re-running must not silently rotate the AI agent's ESL credentials)
    if [ -f /etc/freeswitch/autoload_configs/event_socket.conf.xml ]; then
        EXISTING_ESL=$(sed -n 's/.*<param name="password" value="\([^"]*\)".*/\1/p' \
            /etc/freeswitch/autoload_configs/event_socket.conf.xml | head -n 1)
        if [ -n "$EXISTING_ESL" ]; then
            ESL_PASS="$EXISTING_ESL"
            log "reusing the existing FreeSWITCH event-socket password"
        fi
    fi
fi

# ---------------- official FusionPBX installer (base system) --------------- #
PBX_ROOT=/var/www/fusionpbx
if [ "$SKIP_BASE" -eq 0 ]; then
log "cloning the official FusionPBX installer"
if [ ! -d /usr/src/fusionpbx-install.sh/.git ]; then
    git clone -q https://github.com/fusionpbx/fusionpbx-install.sh.git /usr/src/fusionpbx-install.sh
else
    git -C /usr/src/fusionpbx-install.sh pull -q --ff-only 2>/dev/null || true
fi

# patch the installer's config with our settings
CONF=/usr/src/fusionpbx-install.sh/debian/resources/config.sh
sed -i "s|^domain_name=.*|domain_name=$DOMAIN|"       "$CONF"
sed -i "s|^system_username=.*|system_username=admin|" "$CONF"
sed -i "s|^system_password=.*|system_password=$ADMIN_PASS|" "$CONF"
sed -i "s|^system_branch=.*|system_branch=5.5|"       "$CONF"
sed -i "s|^database_name=.*|database_name=fusionpbx|" "$CONF"
sed -i "s|^database_username=.*|database_username=fusionpbx|" "$CONF"
sed -i "s|^database_password=.*|database_password=$DB_PASS|" "$CONF"
sed -i "s|^database_host=.*|database_host=127.0.0.1|" "$CONF"
sed -i "s|^database_port=.*|database_port=5432|"     "$CONF"
sed -i "s|^database_repo=.*|database_repo=system|"   "$CONF"
sed -i "s|^database_version=.*|database_version=15|" "$CONF"
sed -i "s|^php_version=.*|php_version=8.2|"         "$CONF"
sed -i "s|^letsencrypt_folder=.*|letsencrypt_folder=false|" "$CONF"
if [ -n "$SW_TOKEN" ]; then
    # fast path: official SignalWire apt repo (needs a free token)
    sed -i "s|^switch_source=.*|switch_source=false|"   "$CONF"
    sed -i "s|^switch_package=.*|switch_package=true|"  "$CONF"
    sed -i "s|^switch_token=.*|switch_token=$SW_TOKEN|" "$CONF"
else
    # self-contained path: build FreeSWITCH 1.10.12 from the fusionpbx fork
    sed -i "s|^switch_source=.*|switch_source=true|"    "$CONF"
    sed -i "s|^switch_package=.*|switch_package=false|" "$CONF"
    sed -i "s|^switch_branch=.*|switch_branch=stable|"  "$CONF"
    sed -i "s|^switch_version=.*|switch_version=1.10.12|" "$CONF"
    sed -i "s|^sofia_version=.*|sofia_version=1.13.18|"  "$CONF"
fi

# the fusionpbx/freeswitch fork tags releases as v1.10.12 (with the 'v')
sed -i 's|git checkout \$switch_version|git checkout v\$switch_version|' \
    /usr/src/fusionpbx-install.sh/debian/resources/switch/source-release.sh

# low-memory guard: build single-threaded on boxes with < 4 GB RAM
python3 - <<'PY'
import io
p = "/usr/src/fusionpbx-install.sh/debian/resources/switch/source-release.sh"
s = io.open(p, encoding="utf-8").read()
guard = 'make -j $(if [ "$(awk \'/MemTotal/{print $2}\' /proc/meminfo 2>/dev/null)" -lt 4000000 ]; then echo 1; else getconf _NPROCESSORS_ONLN; fi)'
s = s.replace("make -j $(getconf _NPROCESSORS_ONLN)", guard)
io.open(p, "w", encoding="utf-8").write(s)
print("patched source-release.sh with the low-memory build guard")
PY

# The official installer's config.sh ships CRLF line endings on some versions,
# which makes `source ./config.sh` fail with "Syntax error: newline unexpected"
# and abort the whole base install. Normalize to LF so it sources cleanly.
sed -i 's/\r$//' "$CONF" 2>/dev/null || true

log "running the official FusionPBX Debian installer (php, postgres, nginx,"
log "FreeSWITCH source build, FusionPBX app, schema, domain and admin)..."
cd /usr/src/fusionpbx-install.sh/debian
bash install.sh >/tmp/xcall-fusionpbx-install.log 2>&1 || {
    echo "FusionPBX base installer FAILED (exit $?)."
    echo "  Common cause: the FreeSWITCH source build failed, or config.sh line endings."
    echo "  See: /tmp/xcall-fusionpbx-install.log (tail below)"
    tail -n 80 /tmp/xcall-fusionpbx-install.log
    echo "  Tip: pass --signalwire-token '<free token>' to use the fast package repo instead."
    exit 1
}
tail -n 50 /tmp/xcall-fusionpbx-install.log

log "official FusionPBX installer finished."

# ---------------- verify the FusionPBX schema ------------------------------ #
log "verifying the FusionPBX database schema"
if [ ! -d "$PBX_ROOT" ]; then
    die "FusionPBX web root missing at $PBX_ROOT — the base installer did not complete. See /tmp/xcall-fusionpbx-install.log (tail below), and consider --signalwire-token for the fast FreeSWITCH package install."
fi
if ! PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -tAc \
       "SELECT 1 FROM v_domains" 2>/dev/null | grep -q 1; then
    warn "v_domains is missing - re-running the schema upgrade with full output:"
    cd "$PBX_ROOT"
    /usr/bin/php core/upgrade/upgrade.php --schema 2>&1 | tail -n 50
    if ! PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -tAc \
           "SELECT 1 FROM v_domains" 2>/dev/null | grep -q 1; then
        echo "--- /etc/fusionpbx/config.conf (password hidden) ---"
        sed -E 's/^(database\.0\.password = ).*/\1***/' /etc/fusionpbx/config.conf 2>/dev/null | tail -n 25
        die "FusionPBX schema was not created. Full log: /tmp/xcall-fusionpbx-install.log"
    fi
fi
fi   # end of resume-mode skip

# ensure the domain row exists (the installer inserts it; be idempotent)
if ! PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -tAc \
       "SELECT 1 FROM v_domains WHERE domain_name='$DOMAIN'" | grep -q 1; then
    log "adding domain: $DOMAIN"
    DOMAIN_UUID=$(/usr/bin/php "$PBX_ROOT/resources/uuid.php")
    PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -c \
        "insert into v_domains (domain_uuid, domain_name, domain_enabled) values('$DOMAIN_UUID', '$DOMAIN', 'true');" >/dev/null
fi
DOMAIN_UUID=$(PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -tAc \
    "select domain_uuid from v_domains where domain_name='$DOMAIN';")

# make sure the admin user exists
if ! PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -tAc \
       "SELECT 1 FROM v_users WHERE username='admin'" | grep -q 1; then
    log "adding admin user"
    USER_UUID=$(/usr/bin/php "$PBX_ROOT/resources/uuid.php")
    USER_SALT=$(/usr/bin/php "$PBX_ROOT/resources/uuid.php")
    PASSWORD_HASH=$(/usr/bin/php -r "echo md5('$USER_SALT$ADMIN_PASS');")
    PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -c \
        "insert into v_users (user_uuid, domain_uuid, username, password, salt, user_enabled) values('$USER_UUID', '$DOMAIN_UUID', 'admin', '$PASSWORD_HASH', '$USER_SALT', 'true');" >/dev/null
    GROUP_UUID=$(PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -qtAX -c \
        "select group_uuid from v_groups where group_name = 'superadmin';")
    USER_GROUP_UUID=$(/usr/bin/php "$PBX_ROOT/resources/uuid.php")
    PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -c \
        "insert into v_user_groups (user_group_uuid, domain_uuid, group_name, group_uuid, user_uuid) values('$USER_GROUP_UUID', '$DOMAIN_UUID', 'superadmin', '$GROUP_UUID', '$USER_UUID');" >/dev/null
fi

# save deployment state (used by the summary + agent config)
mkdir -p "$INSTALL_DIR"
cat > "$INSTALL_DIR/.deploy-state" <<EOF
DOMAIN_UUID=$DOMAIN_UUID
DOMAIN=$DOMAIN
DB_PASS=$DB_PASS_ACTUAL
ADMIN_PASS=$ADMIN_PASS
ESL_PASS=$ESL_PASS
EOF
chmod 600 "$INSTALL_DIR/.deploy-state"

log "FusionPBX core installed (schema + domain + admin verified)."

# ---------------- XCall portal overlay -------------------------------------- #
log "applying XCall branding + admin panel + webphone + AI assistant"
if [ -f "$INSTALL_DIR/portal/rebrand/install-rebrand.sh" ]; then
    # PGPASSWORD + PGHOST are required: the rebrand runs psql as the fusionpbx
    # user over TCP (peer auth on the local socket would reject it)
    PGPASSWORD="$DB_PASS_ACTUAL" PGHOST=127.0.0.1 bash "$INSTALL_DIR/portal/rebrand/install-rebrand.sh" "$PBX_ROOT" fusionpbx \
        || warn "rebrand script reported a warning"
fi

# brand values into v_default_settings for the current domain
PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -q <<'SQL' 2>/dev/null || true
UPDATE v_default_settings SET default_setting_value = 'XCall PBX'
 WHERE default_setting_category = 'theme'
   AND default_setting_subcategory = 'menu_brand_text';
UPDATE v_default_settings SET default_setting_value = 'Powered by XCall PBX'
 WHERE default_setting_category = 'theme'
   AND default_setting_subcategory = 'footer';
SQL

# ---------------- verify the XCall add-ons ---------------------------------- #
log "verifying XCall add-ons (admin panel, AI assistant, webphone)"
for p in admin/index.php ai-assistant/assistants.php ai-assistant/api_helpers.php \
         webphone/index.html webphone/config.php webphone/vendor/sip.min.js; do
    if [ ! -f "$PBX_ROOT/$p" ]; then
        warn "missing portal add-on file: $p - re-running the rebrand"
        PGPASSWORD="$DB_PASS_ACTUAL" PGHOST=127.0.0.1 \
            bash "$INSTALL_DIR/portal/rebrand/install-rebrand.sh" "$PBX_ROOT" fusionpbx \
            >/tmp/xcall-rebrand.log 2>&1 || warn "rebrand re-run reported a warning"
        break
    fi
done

# the v_xcall_* tables must exist for the admin panel + AI assistant
if ! PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -tAc \
       "SELECT 1 FROM information_schema.tables WHERE table_name='v_xcall_assistants'" 2>/dev/null | grep -q 1; then
    log "v_xcall schema missing - applying portal/ai-assistant/schema.sql"
    PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx \
        -f "$INSTALL_DIR/portal/ai-assistant/schema.sql" 2>&1 | tail -n 3 \
        || warn "could not apply the v_xcall schema (check the DB user/password)"
fi
chown -R www-data:www-data "$PBX_ROOT/webphone" "$PBX_ROOT/ai-assistant" "$PBX_ROOT/admin" 2>/dev/null || true

# ---------------- FreeSWITCH XCall overlay ---------------------------------- #
log "configuring FreeSWITCH (SIP-over-WebSocket / ESL / dialplan)"

# Detect the REAL FreeSWITCH config root. FusionPBX sometimes keeps the live
# config under /etc/freeswitch.orig (or a nested path) instead of /etc/freeswitch,
# which silently breaks the WebSocket / vars setup below.
FS_CONF=""
for c in /etc/freeswitch.orig/freeswitch /etc/freeswitch.orig /etc/freeswitch /usr/local/freeswitch/conf /usr/share/freeswitch/conf; do
    if [ -f "$c/sip_profiles/internal.xml" ] && [ -f "$c/vars.xml" ]; then
        FS_CONF="$c"; break
    fi
done
FS_CONF="${FS_CONF:-/etc/freeswitch}"
echo "  FreeSWITCH config root: $FS_CONF"
export FS_CONF
mkdir -p "$FS_CONF/tls" /var/spool/xcall/recordings /var/spool/xcall/tts

# ESL password (must match the AI agent config)
sed -i "s|<param name=\"password\" value=\".*\"/>|<param name=\"password\" value=\"$ESL_PASS\"/>|" \
    "$FS_CONF/autoload_configs/event_socket.conf.xml" 2>/dev/null || true

# add the XCall AI-agent context (new context - safe, does not touch FusionPBX dialplan)
if [ -f "$INSTALL_DIR/freeswitch/conf/dialplan/xcall_ai.xml" ]; then
    mkdir -p "$FS_CONF/dialplan"
    install -m 644 "$INSTALL_DIR/freeswitch/conf/dialplan/xcall_ai.xml" "$FS_CONF/dialplan/xcall_ai.xml"
fi

# XCall FreeSWITCH additions, applied to the FusionPBX-managed tree WITHOUT
# replacing their DB-managed files (all best-effort - never abort the install)
python3 - <<'PY'
import io, os

# 1. merge XCall vars into vars.xml (use the detected config root)
FC = os.environ.get("FS_CONF", "/etc/freeswitch")
v = FC + "/vars.xml"
try:
    s = io.open(v, encoding="utf-8").read()
except OSError:
    print("WARNING: vars.xml not found - skipping XCall var merge")
else:
    if "internal_ws_port" not in s:
        extra = ('\n    <!-- XCall: web softphone (SIP over WebSocket) + AI agent -->\n'
                 '    <X-PRE-PROCESS cmd="set" data="internal_ws_port=8081"/>\n'
                 '    <X-PRE-PROCESS cmd="set" data="internal_wss_port=8082"/>\n'
                 '    <X-PRE-PROCESS cmd="set" data="verto_port=8083"/>\n'
                 '    <X-PRE-PROCESS cmd="set" data="verto_port_secure=8084"/>\n'
                 '    <X-PRE-PROCESS cmd="set" data="xcall_recordings_dir=/var/spool/xcall/recordings"/>\n'
                 '    <X-PRE-PROCESS cmd="set" data="xcall_ai_extension=5000"/>\n'
                 '    <X-PRE-PROCESS cmd="set" data="xcall_ai_context=xcall_ai"/>\n'
                 '    <X-PRE-PROCESS cmd="set" data="xcall_specialist_extension=7000"/>\n'
                 '    <X-PRE-PROCESS cmd="set" data="xcall_tts_dir=/var/spool/xcall/tts"/>\n')
        s = s.replace("</include>", extra + "</include>")
        io.open(v, "w", encoding="utf-8").write(s)
        print("merged XCall vars into vars.xml")
    else:
        print("vars.xml already has the XCall vars")

# 2. if the internal profile is a static file, add ws-binding to it as well
i = FC + "/sip_profiles/internal.xml"
if os.path.exists(i):
    s = io.open(i, encoding="utf-8").read()
    if "ws-binding" not in s and "<settings>" in s:
        s = s.replace(
            "<settings>",
            '<settings>\n        <param name="ws-binding" value=":$${internal_ws_port}"/>\n'
            '        <param name="wss-binding" value=":$${internal_wss_port}"/>',
            1,
        )
        io.open(i, "w", encoding="utf-8").write(s)
        print("added ws-binding/wss-binding to the internal SIP profile")
    else:
        print("internal SIP profile already has ws-binding")
else:
    print("note: internal SIP profile is DB-managed (no static file) - the xcall_ws profile covers the softphone")

# 3. FusionPBX's verto.conf hardcodes 8081/8082 - move verto to 8083/8084 so
#    the SIP-over-WebSocket endpoint owns 8081/8082 without port conflicts
vc = FC + "/autoload_configs/verto.conf.xml"
if os.path.exists(vc):
    s = io.open(vc, encoding="utf-8").read()
    if "0.0.0.0:8081" in s or "0.0.0.0:8082" in s:
        s = s.replace("0.0.0.0:8081", "0.0.0.0:8083").replace("0.0.0.0:8082", "0.0.0.0:8084")
        io.open(vc, "w", encoding="utf-8").write(s)
        print("moved FusionPBX verto profile to 8083/8084")
PY

# 4. a dedicated SIP-over-WebSocket profile for the SIP.js softphone
cat > "$FS_CONF/sip_profiles/xcall_ws.xml" <<'XML'
<profile name="xcall_ws">
    <domains>
        <domain name="all" alias="true" parse="false"/>
    </domains>
    <gateways></gateways>
    <settings>
        <param name="debug" value="0"/>
        <param name="sip-trace" value="no"/>
        <param name="log-auth-failures" value="true"/>
        <param name="context" value="default"/>
        <param name="dialplan" value="XML"/>
        <param name="sip-port" value="5062"/>
        <param name="ws-binding" value=":$${internal_ws_port}"/>
        <param name="wss-binding" value=":$${internal_wss_port}"/>
        <param name="ssl-cert-dir" value="$${internal_ssl_dir}"/>
        <param name="rtp-ip" value="$${local_ip_v4}"/>
        <param name="rtp-timer-name" value="soft"/>
        <param name="inbound-codec-prefs" value="OPUS,G722,PCMU,PCMA,VP8"/>
        <param name="outbound-codec-prefs" value="OPUS,G722,PCMU,PCMA,VP8"/>
        <param name="rtp-protocols" value="udp,tcp,tls"/>
        <param name="dtls-srtp" value="optional"/>
        <param name="dtls-srtp-mode" value="srtp-aead-aes-256-gcm,srtp-aead-aes-128-gcm"/>
        <param name="ice" value="true"/>
        <param name="enable-3pcc" value="true"/>
        <param name="media-option" value="resume-media-on-hold"/>
        <param name="media-option" value="bypass-media-after-att-xfer"/>
        <param name="apply-nat-acl" value="wan.auto"/>
        <param name="apply-candidate-acl" value="wan.auto"/>
        <param name="auth-calls" value="true"/>
        <param name="hold-music" value="local_stream://moh"/>
        <param name="presence-proto-lookup" value="true"/>
        <param name="user-agent-string" value="XCall PBX"/>
        <param name="dial-string" value="{^^:sip_invite_domain=${dialed_domain}:presence_id=${dialed_user}@${dialed_domain}}${sofia_contact(*/${dialed_user}@${dialed_domain})}"/>
    </settings>
</profile>
XML
chmod 644 "$FS_CONF/sip_profiles/xcall_ws.xml"
log "added the xcall_ws SIP-over-WebSocket profile (softphone endpoint on 8081/8082)"

# 5. enable WebRTC in the FusionPBX database. FreeSWITCH serves the SIP profiles
#    from the database, so the softphone's ws-binding must live in v_sip_profile_settings
#    on the 'internal' profile AND the domain's WebRTC flag must be on. Do this via SQL
#    (idempotent) so it works on a fresh DB-managed install.
if command -v psql >/dev/null 2>&1; then
    log "enabling WebRTC (ws-binding on the internal SIP profile + domain web_rtc)"
    PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -q <<'SQL' 2>/dev/null || true
INSERT INTO v_sip_profile_settings
    (sip_profile_setting_uuid, sip_profile_uuid, sip_profile_setting_name, sip_profile_setting_value, sip_profile_setting_enabled, sip_profile_setting_description)
SELECT gen_random_uuid(), p.sip_profile_uuid, 'ws-binding', ':8081', true, 'XCall web softphone (SIP over WebSocket)'
  FROM v_sip_profiles p
 WHERE p.sip_profile_name = 'internal'
   AND NOT EXISTS (SELECT 1 FROM v_sip_profile_settings s WHERE s.sip_profile_uuid = p.sip_profile_uuid AND s.sip_profile_setting_name = 'ws-binding');

INSERT INTO v_sip_profile_settings
    (sip_profile_setting_uuid, sip_profile_uuid, sip_profile_setting_name, sip_profile_setting_value, sip_profile_setting_enabled, sip_profile_setting_description)
SELECT gen_random_uuid(), p.sip_profile_uuid, 'wss-binding', ':8082', true, 'XCall web softphone (SIP over WebSocket TLS)'
  FROM v_sip_profiles p
 WHERE p.sip_profile_name = 'internal'
   AND NOT EXISTS (SELECT 1 FROM v_sip_profile_settings s WHERE s.sip_profile_uuid = p.sip_profile_uuid AND s.sip_profile_setting_name = 'wss-binding');

-- the domain WebRTC flag (FusionPBX gates the WS transport on this)
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT gen_random_uuid(), 'domain', 'web_rtc_enabled', 'true'
 WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='domain' AND default_setting_subcategory='web_rtc_enabled');
SQL
fi

# comment out module loads whose .so was not built by this FreeSWITCH build
# (e.g. mod_verto/mod_avmd on the source build) so startup stays clean
python3 - <<'PY'
import io, re, os
p = "/etc/freeswitch/autoload_configs/modules.conf.xml"
try:
    s = io.open(p, encoding="utf-8").read()
except OSError:
    print("no modules.conf.xml found - skipping module prune")
else:
    moddir = "/usr/lib/freeswitch/mod"
    changed = False
    def repl(m):
        global changed
        mod = m.group(1)
        if not os.path.exists(os.path.join(moddir, mod + ".so")):
            changed = True
            return "<!-- {0} (module not built) -->".format(m.group(0))
        return m.group(0)
    s2 = re.sub(r'<load module="([^"]+)"/>', repl, s)
    # add modules XCall needs that FusionPBX's list omits (if the .so exists)
    for mod in ("mod_opus", "mod_g722", "mod_pgsql", "mod_curl", "mod_av", "mod_verto", "mod_avmd"):
        if os.path.exists(os.path.join(moddir, mod + ".so")) and ('module="%s"' % mod) not in s2:
            s2 = s2.replace("</modules>", '        <load module="%s"/>\n</modules>' % mod, 1)
            changed = True
    if changed:
        io.open(p, "w", encoding="utf-8").write(s2)
        print("pruned/updated modules.conf.xml (commented missing, added XCall-needed)")
    else:
        print("modules.conf.xml: all listed modules are present")
PY

# TLS for the direct wss endpoint - self-signed unless a real cert is used
if [ ! -f "$FS_CONF/tls/wss.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -keyout "$FS_CONF/tls/wss.key" \
        -out "$FS_CONF/tls/wss.pem" -days 825 -nodes \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName=DNS:$DOMAIN,DNS:localhost,IP:127.0.0.1"
    cat "$FS_CONF/tls/wss.pem" > "$FS_CONF/tls/wss-chain.pem"
fi
chown -R www-data:www-data "$FS_CONF/tls" /var/spool/xcall 2>/dev/null || true

log "restarting FreeSWITCH"
systemctl restart freeswitch 2>/dev/null || warn "freeswitch not running yet (check: systemctl status freeswitch)"

# ---------------- AI agent -------------------------------------------------- #
if [ "$SKIP_AI" -eq 0 ]; then
    log "installing AI agent (systemd)"
    # Debian keeps ensurepip/pip in a separate package; install it first
    # (espeak-ng gives the agent a working TTS voice out of the box)
    apt-get install -y -qq python3-venv python3-pip espeak-ng 2>&1 | tail -n 1
    AI_DIR="$INSTALL_DIR/ai-agent"
    cd "$AI_DIR"
    # remove any broken partial venv from an earlier failed run
    rm -rf .venv
    python3 -m venv .venv
    .venv/bin/pip install --upgrade pip -q
    .venv/bin/pip install -r requirements.txt -q

    # shared secret from the DB so the agent can fetch assistant configs
    AGENT_SECRET=$(PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -tAc \
        "select setting_value from v_xcall_settings where setting_name='agent_shared_secret';" 2>/dev/null)
    if [ -z "$AGENT_SECRET" ]; then
        warn "agent_shared_secret not found - generating a fresh one"
        AGENT_SECRET=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 32)
        PGPASSWORD="$DB_PASS_ACTUAL" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -c \
            "insert into v_xcall_settings (setting_name, setting_value) values('agent_shared_secret','$AGENT_SECRET') on conflict (setting_name) do nothing;" >/dev/null 2>&1 || true
    fi

    sed -e "s#host: .*#host: \"127.0.0.1\"#" \
        -e "s/password: .*/password: \"$ESL_PASS\"/" \
        -e "s/mode: .*/mode: \"assistant\"/" \
        -e "s#portal_url: .*#portal_url: \"https://$DOMAIN/ai-assistant/assistant_api.php\"#" \
        -e "s#portal_secret: .*#portal_secret: \"$AGENT_SECRET\"#" \
        -e 's#engine: "whisper"#engine: "stub"#' \
        -e 's#engine: "piper"#engine: "espeak"#' \
        config.example.yaml > config.yaml

    install -m 644 "$INSTALL_DIR/deploy/xcall-agent.service" /etc/systemd/system/xcall-agent.service
    systemctl daemon-reload
    systemctl enable --now xcall-agent.service
    log "AI agent service started"
fi

# ---------------- nginx ------------------------------------------------------ #
log "configuring nginx (TLS + /verto websocket proxy)"
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
cat > /etc/nginx/sites-available/xcall <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 80M;
    location / {
        return 301 https://\$host\$request_uri;
    }
}
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    client_max_body_size 80M;
    root $PBX_ROOT;
    index index.php index.html;

    ssl_certificate     /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    # web softphone WebSocket (SIP over WS via mod_sofia on 8081; TLS at nginx)
    location /verto {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php$PHP_VERSION-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_read_timeout 15m;
    }
    location = /core/upgrade/index.php {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php$PHP_VERSION-fpm.sock;
        fastcgi_read_timeout 15m;
    }
    location ~ /\\. { deny all; }
    location ~ \\.db\$ { deny all; }
}
EOF
ln -sf /etc/nginx/sites-available/xcall /etc/nginx/sites-enabled/xcall
rm -f /etc/nginx/sites-enabled/fusionpbx /etc/nginx/sites-enabled/default

if nginx -t 2>/dev/null; then
    systemctl restart nginx

    # Let's Encrypt (optional) - replaces the self-signed cert if an email is given
    if [ -n "$EMAIL" ]; then
        log "provisioning Let's Encrypt certificate for $DOMAIN"
        apt-get install -y -qq certbot python3-certbot-nginx 2>&1 | tail -n 1
        certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect \
            || warn "certbot failed (ensure DNS A record for $DOMAIN points at this server)"
        systemctl restart nginx
    fi
else
    warn "nginx config check failed - review /etc/nginx/sites-available/xcall (nginx -t)"
fi

# ---------------- firewall (iptables, on top of the installer's rules) ----- #
log "opening softphone/WebRTC ports in iptables"
for port in 8081 8082 8083 8084; do
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
done
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

# ---------------- done ------------------------------------------------------- #
IP_ADDR=$(hostname -I | awk '{print $1}')
echo
echo "======================================================================"
echo "  XCall installed successfully"
echo "======================================================================"
echo
echo "  Portal        : https://$DOMAIN/"
echo "  Admin panel   : https://$DOMAIN/admin/"
echo "  AI assistants : https://$DOMAIN/ai-assistant/assistants.php"
echo "  Softphone     : https://$DOMAIN/webphone/   (log in first)"
echo
echo "  Login         : admin / $ADMIN_PASS"
echo "  (if DNS does not point at this server yet, use"
echo "   https://$IP_ADDR/ and log in as admin@$DOMAIN)"
echo
echo "  AI agent      : systemctl status xcall-agent"
echo "  FreeSWITCH    : systemctl status freeswitch"
echo "  Credentials   : $INSTALL_DIR/.deploy-state"
echo
echo "  Next steps:"
echo "    1. Point your DNS A record  $DOMAIN  ->  $IP_ADDR"
echo "    2. Create extensions/agents in the portal (Accounts > Extensions)"
echo "       and enable WebRTC for them."
echo "    3. Open AI Assistants, create an assistant (API key or a local"
echo "       model via Ollama/LM Studio/vLLM/llama.cpp), then route inbound"
echo "       calls to it (Inbound Routes -> context xcall_ai)."
echo "    4. Admin panel: set your system name, company details, client"
echo "       directory, and softphone customizations."
echo
echo "  For a Let's Encrypt cert:  certbot --nginx -d $DOMAIN"
echo "======================================================================"