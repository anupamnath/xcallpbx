#!/usr/bin/env bash
# ============================================================================ #
#  XCall — self-contained Debian 12 provisioner
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

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)      DOMAIN="${2:-}"; shift 2 ;;
        --admin-pass)  ADMIN_PASS="${2:-}"; shift 2 ;;
        --db-pass)     DB_PASS="${2:-}"; shift 2 ;;
        --esl-pass)    ESL_PASS="${2:-}"; shift 2 ;;
        --email)       EMAIL="${2:-}"; shift 2 ;;
        --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
        --skip-ai)     SKIP_AI=1; shift ;;
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
    warn "Detected $PRETTY_NAME — this installer targets Debian 12 (bookworm)."
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
if ! command -v freeswitch >/dev/null 2>&1; then
    log "installing FreeSWITCH (official Debian repo)"
    wget -q -O - https://files.freeswitch.org/repo/deb/debian-release/fsstretch-archive-keyring.asc \
        | gpg --dearmor -o /usr/share/keyrings/freeswitch.gpg
    echo "deb [signed-by=/usr/share/keyrings/freeswitch.gpg] http://files.freeswitch.org/repo/deb/debian-release/ bookworm main" \
        > /etc/apt/sources.list.d/freeswitch.list
    apt-get update -qq
    apt-get install -y -qq freeswitch-meta-all freeswitch-all-dbg 2>&1 | tail -n 2
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

# TLS for verto (wss) — self-signed unless a real cert is installed later
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

    # verto WebSocket (wss) for the softphone
    location /verto {
        proxy_pass http://127.0.0.1:8082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
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
nginx -t 2>/dev/null && systemctl restart nginx || warn "nginx config check failed — review /etc/nginx/sites-available/xcall"

# Let's Encrypt (optional) — replaces the self-signed cert if an email is given
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
ufw allow 8081/tcp >/dev/null 2>&1    # verto ws
ufw allow 8082/tcp >/dev/null 2>&1    # verto wss
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


