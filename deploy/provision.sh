#!/usr/bin/env bash
# ============================================================================ #
#  XCall - self-contained Debian 12 provisioner
#
#  Installs the complete XCall system from a bare VPS:
#    FreeSWITCH + FusionPBX portal (rebranded "XCall") + admin panel
#    (system/company, clients, softphone customization) + AI assistant
#    (cloud API keys OR local models) + WebRTC softphone + AI voice agent.
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
#  Debian 12 (bookworm) is required. Tested on x86_64; arm64 uses the same path.
# ============================================================================ #
set -euo pipefail

# ---------------- logging helpers ------------------------------------------ #
log()  { echo -e "\e[1;36m[xcall]\e[0m $*"; }
warn() { echo -e "\e[1;33m[xcall!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[xcall!!]\e[0m $*" >&2; exit 1; }

# ---------------- args ----------------------------------------------------- #
DOMAIN=""
ADMIN_PASS=""
DB_PASS=""
ESL_PASS="ClueCon"
EMAIL=""
INSTALL_DIR="/opt/xcall"
SKIP_AI=0
SW_TOKEN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)      DOMAIN="${2:-}"; shift 2 ;;
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

# ---------------- preflight ------------------------------------------------ #
[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash $0"

# Debian 12 (bookworm) check
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
ADMIN_PASS="${ADMIN_PASS:-$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)}"
DB_PASS="${DB_PASS:-$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)}"

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
    build-essential python3 python3-pip python3-venv python3-setuptools \
    nginx postgresql postgresql-client php-fpm php-cli php-pgsql php-sqlite3 \
    php-curl php-mbstring php-gd php-xml php-intl php-bcmath php-zip php-ldap \
    php-pear php-dev libxml2-dev libpq-dev openssl ssl-cert ufw haveged \
    unzip nano vim ntp qrencode ffmpeg espeak-ng snmpd \
    2>&1 | tail -n 2

# ---------------- FreeSWITCH ----------------------------------------------- #
# FreeSWITCH no longer ships through a public anonymous apt repo:
#   - files.freeswitch.org   -> now requires a SignalWire login (HTTP 401)
#   - pkg.signalwire.com     -> public repo retired (HTTP 404)
# Install paths (first match wins):
#   1. --signalwire-token -> official SignalWire apt repo (fast; free token
#                            from https://signalwire.com)
#   2. build from source  -> fully self-contained (default, no auth needed)
install_freeswitch() {
    if [ -n "$SW_TOKEN" ]; then
        log "installing FreeSWITCH from the SignalWire apt repo (token)"
        wget -q --http-user=signalwire --http-password="$SW_TOKEN" \
            -O /usr/share/keyrings/signalwire-freeswitch-repo.gpg \
            https://freeswitch.signalwire.com/repo/deb/debian-release/signalwire-freeswitch-repo.gpg \
            || die "could not download the SignalWire FreeSWITCH keyring (is the token valid?)"
        echo "machine freeswitch.signalwire.com login signalwire password $SW_TOKEN" > /etc/apt/auth.conf
        chmod 600 /etc/apt/auth.conf
        echo "deb [signed-by=/usr/share/keyrings/signalwire-freeswitch-repo.gpg] https://freeswitch.signalwire.com/repo/deb/debian-release/ bookworm main" \
            > /etc/apt/sources.list.d/freeswitch.list
        apt-get update -qq
        apt-get install -y -qq freeswitch-meta-all 2>&1 | tail -n 2
        return 0
    fi

    # legacy public repo (if it ever returns, the key must verify as real PGP)
    if wget -q -O /tmp/xcall-fs-key.asc \
            https://files.freeswitch.org/repo/deb/debian-release/fsstretch-archive-keyring.asc \
        && gpg --dearmor --output /usr/share/keyrings/freeswitch.gpg /tmp/xcall-fs-key.asc 2>/dev/null; then
        echo "deb [signed-by=/usr/share/keyrings/freeswitch.gpg] http://files.freeswitch.org/repo/deb/debian-release/ bookworm main" \
            > /etc/apt/sources.list.d/freeswitch.list
        if apt-get update -qq 2>/dev/null && apt-get install -y -qq freeswitch-meta-all 2>&1 | tail -n 2; then
            return 0
        fi
        rm -f /etc/apt/sources.list.d/freeswitch.list /etc/apt/auth.conf
    fi

    warn "FreeSWITCH package repos are not anonymously reachable right now."
    warn "building FreeSWITCH 1.10.12 from source - no token needed, but it"
    warn "takes ~30-60 min on a 2 vCPU VPS. To use the fast official repo"
    warn "instead, create a free account at https://signalwire.com and pass"
    warn "--signalwire-token '<token>' to bootstrap.sh."
    build_freeswitch_from_source
}

build_freeswitch_from_source() {
    local JOBS
    # compiling FreeSWITCH is memory hungry; cap parallelism on small VPSes
    if [ "$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)" -lt 4000000 ]; then
        JOBS=1
        warn "under 4 GB RAM detected - building FreeSWITCH single-threaded (slower but safer)"
    else
        JOBS=$(nproc)
    fi
    log "FreeSWITCH source build ($JOBS parallel jobs)"

    # build dependencies (Debian 12 bookworm)
    apt-get install -y -qq \
        autoconf automake devscripts g++ libncurses-dev libtool libtool-bin make \
        libjpeg-dev pkg-config flac libgdbm-dev libdb-dev gettext equivs git dpkg-dev \
        libpq-dev liblua5.2-dev libtiff5-dev libperl-dev libcurl4-openssl-dev \
        libsqlite3-dev libspeexdsp-dev libspeex-dev libldns-dev libedit-dev libopus-dev \
        libmemcached-dev libshout3-dev libmpg123-dev libmp3lame-dev yasm nasm \
        libsndfile1-dev libuv1-dev libvpx-dev libavformat-dev libswscale-dev sox \
        libsox-fmt-all libssl-dev libsrtp2-dev libavcodec-dev \
        libavutil-dev 2>&1 | tail -n 1

    # mod_verto / mod_signalwire are NOT built from source (same as the FusionPBX
    # source recipe): they need libks, whose libks2 CMake build requires a
    # packaged release tarball and whose libks2.so / include/libks2 naming does
    # not match FreeSWITCH 1.10.12. The XCall web softphone does not need them:
    # it registers over SIP-over-WebSocket on the internal mod_sofia profile
    # (freeswitch/conf). For mod_verto (verto.js clients / FusionPBX's
    # communicator), install FreeSWITCH from the SignalWire apt repo with
    # --signalwire-token instead.

    # sofia-sip - SIP stack with WebSocket support (needed by mod_sofia).
    # FusionPBX's current default version - proven on Debian 12/gcc-12.
    if [ ! -d /usr/src/sofia-sip/.git ]; then
        log "building sofia-sip v1.13.18"
        git clone -q https://github.com/freeswitch/sofia-sip.git /usr/src/sofia-sip
        cd /usr/src/sofia-sip
        git checkout -q v1.13.18
        sh autogen.sh >/dev/null 2>&1
        ./configure --enable-debug >/dev/null 2>&1
        make -j "$JOBS" >/dev/null 2>&1
        make install >/dev/null 2>&1
        ldconfig
        cd /
    fi

    # spandsp - fax / tone DSP (FusionPBX's pinned commit)
    if [ ! -d /usr/src/spandsp/.git ]; then
        log "building spandsp"
        git clone -q https://github.com/freeswitch/spandsp.git /usr/src/spandsp
        cd /usr/src/spandsp
        git reset --hard 0d2e6ac65e0e8f53d652665a743015a88bf048d4 >/dev/null
        sh autogen.sh >/dev/null 2>&1
        ./configure --enable-debug >/dev/null 2>&1
        make -j "$JOBS" >/dev/null 2>&1
        make install >/dev/null 2>&1
        ldconfig
        cd /
    fi

    # FreeSWITCH itself - the fusionpbx fork is exactly what FusionPBX supports
    if [ ! -d /usr/src/freeswitch-1.10.12/.git ]; then
        log "cloning FreeSWITCH 1.10.12 (fusionpbx fork)"
        git clone -q https://github.com/fusionpbx/freeswitch.git /usr/src/freeswitch-1.10.12
        cd /usr/src/freeswitch-1.10.12
        git checkout -q v1.10.12
    fi
    cd /usr/src/freeswitch-1.10.12

    log "bootstrapping build system (bundled apr/srtp + autotools)"
    ./bootstrap.sh -j >/tmp/xcall-fs-bootstrap.log 2>&1 || {
        tail -n 40 /tmp/xcall-fs-bootstrap.log >&2
        die "FreeSWITCH bootstrap failed (log: /tmp/xcall-fs-bootstrap.log)"
    }

    # enable the modules FusionPBX + XCall need
    sed -i modules.conf \
        -e 's:#applications/mod_callcenter:applications/mod_callcenter:' \
        -e 's:#applications/mod_cidlookup:applications/mod_cidlookup:' \
        -e 's:#applications/mod_memcache:applications/mod_memcache:' \
        -e 's:#applications/mod_nibblebill:applications/mod_nibblebill:' \
        -e 's:#applications/mod_curl:applications/mod_curl:' \
        -e 's:#applications/mod_translate:applications/mod_translate:' \
        -e 's:#formats/mod_shout:formats/mod_shout:' \
        -e 's:#say/mod_say_es:say/mod_say_es:' \
        -e 's:#say/mod_say_fr:say/mod_say_fr:'
    # disable modules that need libks/libsignalwire-c, or that fail on modern
    # gcc - same set FusionPBX's own source build disables.
    sed -i modules.conf \
        -e 's:^applications/mod_signalwire:#applications/mod_signalwire:' \
        -e 's:^endpoints/mod_skinny:#endpoints/mod_skinny:' \
        -e 's:^endpoints/mod_verto:#endpoints/mod_verto:'

    log "configuring FreeSWITCH"
    ./configure -C --enable-portable-binary --disable-dependency-tracking --enable-debug \
        --prefix=/usr --localstatedir=/var --sysconfdir=/etc \
        --with-openssl --enable-core-pgsql-support >/tmp/xcall-fs-config.log 2>&1 || {
        tail -n 40 /tmp/xcall-fs-config.log >&2
        die "FreeSWITCH configure failed (log: /tmp/xcall-fs-config.log)"
    }

    log "compiling FreeSWITCH - this is the long step (~$JOBS jobs)"
    make -j "$JOBS" >/tmp/xcall-fs-make.log 2>&1 || {
        tail -n 60 /tmp/xcall-fs-make.log >&2
        die "FreeSWITCH make failed (log: /tmp/xcall-fs-make.log)"
    }
    make install >/tmp/xcall-fs-install.log 2>&1 || {
        tail -n 40 /tmp/xcall-fs-install.log >&2
        die "FreeSWITCH make install failed (log: /tmp/xcall-fs-install.log)"
    }
    mkdir -p /var/lib/freeswitch/storage/voicemail
    ldconfig

    # sounds (callie) + music-on-hold - still public on files.freeswitch.org
    log "installing FreeSWITCH sounds + music"
    mkdir -p /usr/share/freeswitch/sounds
    cd /usr/share/freeswitch/sounds
    for rate in 48000 32000 16000 8000; do
        wget -q "https://files.freeswitch.org/releases/sounds/freeswitch-sounds-en-us-callie-${rate}-1.0.53.tar.gz"
        tar xzf "freeswitch-sounds-en-us-callie-${rate}-1.0.53.tar.gz"
        rm -f "freeswitch-sounds-en-us-callie-${rate}-1.0.53.tar.gz"
    done
    mkdir -p music
    cd music
    for rate in 48000 32000 16000 8000; do
        wget -q "https://files.freeswitch.org/releases/sounds/freeswitch-sounds-music-${rate}-1.0.52.tar.gz"
        tar xzf "freeswitch-sounds-music-${rate}-1.0.52.tar.gz"
        rm -f "freeswitch-sounds-music-${rate}-1.0.52.tar.gz"
    done
    [ -d music ] && mv music default
    cd /

    # systemd unit (FusionPBX model: runs as www-data so the portal manages config)
    log "installing FreeSWITCH systemd unit"
    cat > /lib/systemd/system/freeswitch.service <<'UNIT'
[Unit]
Description=freeswitch (XCall)
Wants=network-online.target
Requires=network.target local-fs.target
After=network.target network-online.target local-fs.target postgresql.service

[Service]
Type=forking
PIDFile=/run/freeswitch/freeswitch.pid
Environment="DAEMON_OPTS=-nonat"
Environment="USER=www-data"
Environment="GROUP=www-data"
EnvironmentFile=-/etc/default/freeswitch
ExecStartPre=/bin/mkdir -p /var/run/freeswitch
ExecStartPre=/bin/chown -R ${USER}:${GROUP} /var/lib/freeswitch /var/log/freeswitch /etc/freeswitch /usr/share/freeswitch /var/run/freeswitch
ExecStartPre=/bin/sleep 10
ExecStart=/usr/bin/freeswitch -u ${USER} -g ${GROUP} -ncwait ${DAEMON_OPTS}
TimeoutSec=45s
Restart=always
LimitCORE=infinity
LimitNOFILE=100000
LimitNPROC=60000
LimitSTACK=250000
LimitRTPRIO=infinity
LimitRTTIME=infinity
IOSchedulingClass=realtime
IOSchedulingPriority=2
CPUSchedulingPolicy=rr
CPUSchedulingPriority=89
UMask=0007
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
UNIT
    echo 'DAEMON_OPTS="-nonat"' > /etc/default/freeswitch
    systemctl daemon-reload
    systemctl unmask freeswitch.service 2>/dev/null || true
    systemctl enable freeswitch >/dev/null 2>&1 || true

    # FusionPBX manages /etc/freeswitch from php-fpm (www-data)
    chown -R www-data:www-data /etc/freeswitch /var/lib/freeswitch \
        /usr/share/freeswitch /var/log/freeswitch /var/run/freeswitch 2>/dev/null || true

    log "FreeSWITCH 1.10.12 source build complete"
}

if ! command -v freeswitch >/dev/null 2>&1; then
    install_freeswitch
fi
log "FreeSWITCH: $(freeswitch -version 2>/dev/null | head -n1 || echo installed)"

# ---------------- PostgreSQL ------------------------------------------------ #
log "configuring PostgreSQL"
systemctl enable --now postgresql
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='fusionpbx'" | grep -q 1; then
    sudo -u postgres psql -c "CREATE ROLE fusionpbx WITH SUPERUSER LOGIN PASSWORD '$DB_PASS';" >/dev/null
fi
sudo -u postgres psql -c "ALTER ROLE fusionpbx WITH PASSWORD '$DB_PASS';" >/dev/null
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='fusionpbx'" | grep -q 1; then
    sudo -u postgres psql -c "CREATE DATABASE fusionpbx OWNER fusionpbx;" >/dev/null
fi

# ---------------- FusionPBX web app ----------------------------------------- #
PBX_ROOT="/var/www/fusionpbx"
if [ ! -d "$PBX_ROOT/.git" ]; then
    log "cloning FusionPBX -> $PBX_ROOT"
    git clone -q https://github.com/fusionpbx/fusionpbx.git "$PBX_ROOT"
fi
mkdir -p /var/cache/fusionpbx
chown -R www-data:www-data /var/cache/fusionpbx

# config.conf (FusionPBX reads DB creds from here)
log "writing /etc/fusionpbx/config.conf"
mkdir -p /etc/fusionpbx
cat > /etc/fusionpbx/config.conf <<EOF

#database system settings
database.0.type = pgsql
database.0.host = 127.0.0.1
database.0.port = 5432
database.0.sslmode = prefer
database.0.name = fusionpbx
database.0.username = fusionpbx
database.0.password = $DB_PASS

#database switch settings
database.1.type = sqlite
database.1.path = /var/lib/freeswitch/db
database.1.name = core.db

#general settings
document.root = $PBX_ROOT
project.path =
temp.dir = /tmp
php.dir = /usr/bin
php.bin = php

#session settings
session.cookie_httponly = true
session.cookie_secure = true
session.cookie_samesite = Lax

#cache settings
cache.method = file
cache.location = /var/cache/fusionpbx
cache.settings = true

#switch settings
switch.conf.dir = /etc/freeswitch
switch.sounds.dir = /usr/share/freeswitch/sounds
switch.database.dir = /var/lib/freeswitch/db
switch.recordings.dir = /var/lib/freeswitch/recordings
switch.storage.dir = /var/lib/freeswitch/storage
switch.voicemail.dir = /var/lib/freeswitch/storage/voicemail
switch.scripts.dir = /usr/share/freeswitch/scripts

#switch xml handler
xml_handler.fs_path = false
xml_handler.reg_as_number_alias = false
xml_handler.number_as_presence_id = true

#error reporting options: user,dev,all
error.reporting = user
EOF
chmod 664 /etc/fusionpbx/config.conf
chown -R www-data:www-data /etc/fusionpbx

log "creating FusionPBX database schema (this can take a minute)"
cd "$PBX_ROOT"
/usr/bin/php "$PBX_ROOT/core/upgrade/upgrade.php" --schema >/tmp/xcall-schema.log 2>&1 || {
    cat /tmp/xcall-schema.log | tail -n 30 >&2; die "schema upgrade failed"
}

# ---------------- domain + admin user (mirrors FusionPBX finish.sh) -------- #
DOMAIN_UUID=$(/usr/bin/php "$PBX_ROOT/resources/uuid.php")
if ! PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -tAc \
       "SELECT 1 FROM v_domains WHERE domain_name='$DOMAIN'" | grep -q 1; then
    log "adding domain: $DOMAIN"
    PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -c \
        "insert into v_domains (domain_uuid, domain_name, domain_enabled) values('$DOMAIN_UUID', '$DOMAIN', 'true');" >/dev/null
fi
DOMAIN_UUID=$(PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -tAc \
    "select domain_uuid from v_domains where domain_name='$DOMAIN';")

log "applying app defaults"
/usr/bin/php "$PBX_ROOT/core/upgrade/upgrade.php" --defaults >/tmp/xcall-defaults.log 2>&1 || true

log "adding admin user"
if ! PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -tAc \
       "SELECT 1 FROM v_users WHERE username='admin'" | grep -q 1; then
    USER_UUID=$(/usr/bin/php "$PBX_ROOT/resources/uuid.php")
    USER_SALT=$(/usr/bin/php "$PBX_ROOT/resources/uuid.php")
    PASSWORD_HASH=$(/usr/bin/php -r "echo md5('$USER_SALT$ADMIN_PASS');")
    PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -c \
        "insert into v_users (user_uuid, domain_uuid, username, password, salt, user_enabled) values('$USER_UUID', '$DOMAIN_UUID', 'admin', '$PASSWORD_HASH', '$USER_SALT', 'true');" >/dev/null
    GROUP_UUID=$(PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -qtAX -c \
        "select group_uuid from v_groups where group_name = 'superadmin';")
    USER_GROUP_UUID=$(/usr/bin/php "$PBX_ROOT/resources/uuid.php")
    PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -c \
        "insert into v_user_groups (user_group_uuid, domain_uuid, group_name, group_uuid, user_uuid) values('$USER_GROUP_UUID', '$DOMAIN_UUID', 'superadmin', '$GROUP_UUID', '$USER_UUID');" >/dev/null
fi

log "setting permissions + services"
/usr/bin/php "$PBX_ROOT/core/upgrade/upgrade.php" --permissions >/tmp/xcall-perms.log 2>&1 || true
mkdir -p /var/run/fusionpbx
chown -R www-data:www-data /var/run/fusionpbx
/usr/bin/php "$PBX_ROOT/core/upgrade/upgrade.php" --services >/tmp/xcall-services.log 2>&1 || true
chown -R www-data:www-data "$PBX_ROOT"

# save deployment state (used by the summary + agent config)
cat > "$INSTALL_DIR/.deploy-state" <<EOF
DOMAIN_UUID=$DOMAIN_UUID
DOMAIN=$DOMAIN
DB_PASS=$DB_PASS
ADMIN_PASS=$ADMIN_PASS
ESL_PASS=$ESL_PASS
EOF
chmod 600 "$INSTALL_DIR/.deploy-state"

log "FusionPBX core installed."


# ---------------- XCall portal overlay -------------------------------------- #
log "applying XCall branding + admin panel + webphone + AI assistant"
if [ -f "$INSTALL_DIR/portal/rebrand/install-rebrand.sh" ]; then
    bash "$INSTALL_DIR/portal/rebrand/install-rebrand.sh" "$PBX_ROOT" fusionpbx \
        || warn "rebrand script reported a warning"
fi

# make the portal know the system name from day one (branding SQL already ran,
# but also push it into v_default_settings for the current domain)
PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -q <<'SQL' 2>/dev/null || true
UPDATE v_default_settings SET default_setting_value = 'XCall'
 WHERE default_setting_category = 'theme'
   AND default_setting_subcategory IN ('menu_brand_text', 'product_name');
UPDATE v_default_settings SET default_setting_value = 'Powered by XCall'
 WHERE default_setting_category = 'theme'
   AND default_setting_subcategory = 'footer';
SQL

# ---------------- FreeSWITCH XCall overlay ---------------------------------- #
log "configuring FreeSWITCH (verto/ESL/dialplan)"
FS_CONF=/etc/freeswitch
mkdir -p "$FS_CONF/tls" /var/spool/xcall/recordings /var/spool/xcall/tts

# ESL password
sed -i "s|<param name=\"password\" value=\".*\"/>|<param name=\"password\" value=\"$ESL_PASS\"/>|" \
    "$FS_CONF/autoload_configs/event_socket.conf.xml" 2>/dev/null || true

# XCall dialplan + directory overlays (AI context, users, verto profile)
if [ -d "$INSTALL_DIR/freeswitch/conf" ]; then
    cp -R "$INSTALL_DIR/freeswitch/conf/." "$FS_CONF/"
fi

# TLS for verto (wss) - self-signed unless a real cert is installed later
if [ ! -f "$FS_CONF/tls/wss.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -keyout "$FS_CONF/tls/wss.key" \
        -out "$FS_CONF/tls/wss.pem" -days 825 -nodes \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName=DNS:$DOMAIN,DNS:localhost,IP:127.0.0.1"
    cat "$FS_CONF/tls/wss.pem" > "$FS_CONF/tls/wss-chain.pem"
fi
chown -R freeswitch:freeswitch "$FS_CONF/tls" /var/spool/xcall 2>/dev/null || true

# event socket must listen on localhost for the AI agent
grep -q "event_socket" "$FS_CONF/autoload_configs/event_socket.conf.xml" 2>/dev/null \
    || echo "event_socket.conf.xml managed by FusionPBX"

log "restarting FreeSWITCH"
systemctl restart freeswitch 2>/dev/null || warn "freeswitch not running yet (check: systemctl status freeswitch)"


# ---------------- AI agent -------------------------------------------------- #
if [ "$SKIP_AI" -eq 0 ]; then
    log "installing AI agent (systemd)"
    AI_DIR="$INSTALL_DIR/ai-agent"
    cd "$AI_DIR"
    python3 -m venv .venv
    .venv/bin/pip install --upgrade pip -q
    .venv/bin/pip install -r requirements.txt -q

    # shared secret from the DB so the agent can fetch assistant configs
    AGENT_SECRET=$(PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U fusionpbx -d fusionpbx -tAc \
        "select setting_value from v_xcall_settings where setting_name='agent_shared_secret';")

    sed -e "s#host: .*#host: \"127.0.0.1\"#" \
        -e "s/password: .*/password: \"$ESL_PASS\"/" \
        -e "s/mode: .*/mode: \"assistant\"/" \
        -e "s#portal_url: .*#portal_url: \"https://$DOMAIN/ai-assistant/assistant_api.php\"#" \
        -e "s#portal_secret: .*#portal_secret: \"$AGENT_SECRET\"#" \
        config.example.yaml > config.yaml

    install -m 644 "$INSTALL_DIR/deploy/xcall-agent.service" /etc/systemd/system/xcall-agent.service
    systemctl daemon-reload
    systemctl enable --now xcall-agent.service
    log "AI agent service started"
fi

# ---------------- nginx ------------------------------------------------------ #
log "configuring nginx"
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
    index index.php;

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
    location ~ /\. { deny all; }
    location ~ \.db\$ { deny all; }
}
EOF
ln -sf /etc/nginx/sites-available/xcall /etc/nginx/sites-enabled/xcall
rm -f /etc/nginx/sites-enabled/default

# nginx needs permission to send the verto socket upgrade headers
sed -i 's/# server_tokens off;/server_tokens off;/' /etc/nginx/nginx.conf 2>/dev/null || true

systemctl enable nginx
nginx -t 2>/dev/null && systemctl restart nginx || warn "nginx config check failed - review /etc/nginx/sites-available/xcall"

# Let's Encrypt (optional) - replaces the self-signed cert if an email is given
if [ -n "$EMAIL" ]; then
    log "provisioning Let's Encrypt certificate for $DOMAIN"
    apt-get install -y -qq certbot python3-certbot-nginx 2>&1 | tail -n 1
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect \
        || warn "certbot failed (ensure DNS A record for $DOMAIN points at this server)"
    systemctl restart nginx
fi

# ---------------- firewall --------------------------------------------------- #
log "configuring firewall (ufw)"
ufw allow 22/tcp >/dev/null 2>&1
ufw allow 80/tcp  >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1
ufw allow 5060/udp >/dev/null 2>&1
ufw allow 5060/tcp >/dev/null 2>&1
ufw allow 5080/udp >/dev/null 2>&1
ufw allow 5080/tcp >/dev/null 2>&1
ufw allow 8081/tcp >/dev/null 2>&1    # softphone ws (SIP over WebSocket)
ufw allow 8082/tcp >/dev/null 2>&1    # softphone wss (direct, self-signed)
ufw allow 8083/tcp >/dev/null 2>&1    # verto ws (verto.js clients, optional)
ufw allow 8084/tcp >/dev/null 2>&1    # verto wss (verto.js clients, optional)
ufw allow 16384:16484/udp >/dev/null 2>&1  # RTP media
ufw --force enable >/dev/null 2>&1 || true


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
echo "       calls to it."
echo "    4. Admin panel: set your system name, company details, client"
echo "       directory, and softphone customizations."
echo
echo "  For a Let's Encrypt cert:  certbot --nginx -d $DOMAIN"
echo "======================================================================"


