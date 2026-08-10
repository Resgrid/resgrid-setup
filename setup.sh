#!/usr/bin/env bash
#
# Resgrid self-hosted installer
#
# One line install:
#   curl -fsSL https://raw.githubusercontent.com/Resgrid/resgrid-setup/master/setup.sh | bash
#
# Non-interactive / scripted install (all optional, defaults shown):
#   RESGRID_WEB_URL=rg.mylocal \
#   RESGRID_API_URL=rgapi.mylocal \
#   RESGRID_EVENTS_URL=rgevents.mylocal \
#   RESGRID_LETSENCRYPT_EMAIL=internal \
#   RESGRID_INSTALL_DIR=$HOME/resgrid \
#   RESGRID_NO_START=1 \
#   bash setup.sh
#
# The script:
#   1. Checks prerequisites (docker, docker compose, openssl, git or curl)
#   2. Downloads this repository (skipped when run from inside a checkout)
#   3. Asks for your three Resgrid URLs and a Let's Encrypt email
#   4. Generates random passwords, passphrases and encryption keys
#   5. Generates fresh OpenIddict (OIDC) signing and encryption certificates
#   6. Writes everything into .env and starts the stack with docker compose

set -euo pipefail

REPO_URL="${RESGRID_REPO_URL:-https://github.com/Resgrid/resgrid-setup}"
BRANCH="${RESGRID_BRANCH:-master}"
INSTALL_DIR="${RESGRID_INSTALL_DIR:-$HOME/resgrid}"

# ---------------------------------------------------------------- helpers ---

if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'; C_BLU=$'\033[0;34m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_OFF=""
fi

info()  { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()    { printf '%s==>%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn()  { printf '%sWarning:%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
die()   { printf '%sError:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but was not found. $2"
}

# Ask a question on the controlling terminal (works when piped through bash).
prompt() { # prompt <question> <default>
  local q="$1" def="$2" ans=""
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '%s [%s]: ' "$q" "$def" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
  fi
  printf '%s' "${ans:-$def}"
}

# Random alphanumeric string of length $1. Alphanumeric only so the values are
# safe inside connection strings, YAML, sed replacements and shell commands.
rand_alnum() {
  local n="$1" s=""
  while [ "${#s}" -lt "$n" ]; do
    s="${s}$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${s:0:$n}"
}

# Random uppercase+digits string of length $1 (RustFS credential format).
rand_upper() {
  local n="$1" s=""
  while [ "${#s}" -lt "$n" ]; do
    s="${s}$(openssl rand -base64 48 | tr -dc 'A-Z0-9')"
  done
  printf '%s' "${s:0:$n}"
}

# Replace the value of KEY=... in .env (matches on key, not on value).
set_env() { # set_env <key> <value>
  local key="$1" value="$2"
  value="${value//\\/\\\\}"
  value="${value//&/\\&}"
  grep -q "^${key}=" .env || die "Key '${key}' not found in .env template."
  sed -i.sedbak "s|^${key}=.*|${key}=${value}|" .env
  rm -f .env.sedbak
}

# ----------------------------------------------------------- prerequisites ---

printf '\n'
printf '%s\n' '  ____                      _     _ '
printf '%s\n' ' |  _ \ ___  ___  __ _ _ __(_) __| |'
printf '%s\n' ' | |_) / _ \/ __|/ _` | '\''__| |/ _` |'
printf '%s\n' ' |  _ <  __/\__ \ (_| | |  | | (_| |'
printf '%s\n' ' |_| \_\___||___/\__, |_|  |_|\__,_|'
printf '%s\n' '                 |___/  self-hosted installer'
printf '\n'

case "$(uname -s)" in
  Linux|Darwin) ;;
  MINGW*|MSYS*|CYGWIN*)
    die "Please run this installer inside WSL2 (Windows Subsystem for Linux), not Git Bash." ;;
  *) warn "Untested operating system '$(uname -s)', continuing anyway." ;;
esac

info "Checking prerequisites..."
need_cmd docker  "Install Docker first: https://docs.docker.com/engine/install/"
need_cmd openssl "Install openssl with your package manager."

docker info >/dev/null 2>&1 || die "The Docker daemon is not running (or you lack permission to use it). Start Docker and re-run."

if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  die "Docker Compose was not found. Install the compose plugin: https://docs.docker.com/compose/install/"
fi
ok "Docker and Compose found ($($COMPOSE version --short 2>/dev/null || echo unknown))."

# ------------------------------------------------------- get the repository ---

# If we're already inside a checkout (setup.sh next to docker-compose.yml),
# configure in place. Otherwise clone/download into INSTALL_DIR.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || pwd)"
if [ -f "$SCRIPT_DIR/docker-compose.yml" ] && [ -f "$SCRIPT_DIR/db/create-databases.sh" ]; then
  INSTALL_DIR="$SCRIPT_DIR"
  info "Running from an existing checkout: $INSTALL_DIR"
else
  info "Downloading Resgrid setup into $INSTALL_DIR ..."
  if [ -e "$INSTALL_DIR" ] && [ ! -f "$INSTALL_DIR/docker-compose.yml" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
    die "$INSTALL_DIR exists and is not a Resgrid setup directory. Set RESGRID_INSTALL_DIR to another path."
  fi
  if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    info "Using existing download at $INSTALL_DIR."
  elif command -v git >/dev/null 2>&1; then
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
  else
    need_cmd curl "Install git or curl."
    need_cmd tar  "Install tar."
    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$REPO_URL/archive/refs/heads/$BRANCH.tar.gz" | tar -xz --strip-components=1 -C "$INSTALL_DIR"
  fi
fi
cd "$INSTALL_DIR"

if [ -f .setup-complete ]; then
  die "This install was already configured ($(cat .setup-complete)).
To upgrade:   cd $INSTALL_DIR && git pull && $COMPOSE pull && $COMPOSE up -d
To reconfigure from scratch, delete the .setup-complete file (and optionally
reset .env with git) and re-run. Your generated secrets live in .env — losing
them makes existing encrypted data and logins unrecoverable."
fi

# --------------------------------------------------------------- questions ---

printf '\n'
info "Configuration (press Enter to accept the defaults)."
printf '%s\n' "    Use hostnames that resolve to this machine. For LAN-only installs the"
printf '%s\n' "    built-in *.mylocal defaults work with hosts-file entries; for internet"
printf '%s\n' "    installs use real DNS names and provide an email for Let's Encrypt."
printf '\n'

WEB_URL="${RESGRID_WEB_URL:-$(prompt 'Web app hostname' 'rg.mylocal')}"
API_URL="${RESGRID_API_URL:-$(prompt 'API hostname' 'rgapi.mylocal')}"
EVENTS_URL="${RESGRID_EVENTS_URL:-$(prompt 'Events hub hostname' 'rgevents.mylocal')}"
LE_EMAIL="${RESGRID_LETSENCRYPT_EMAIL:-$(prompt "Let's Encrypt email ('internal' = self-signed certs)" 'internal')}"

# Strip any scheme the user may have pasted; Caddy and the env need bare hosts.
strip_scheme() { printf '%s' "$1" | sed -e 's|^https://||' -e 's|^http://||' -e 's|/.*$||'; }
WEB_URL="$(strip_scheme "$WEB_URL")"
API_URL="$(strip_scheme "$API_URL")"
EVENTS_URL="$(strip_scheme "$EVENTS_URL")"

printf '\n'
info "Using:"
printf '    Web:    https://%s\n' "$WEB_URL"
printf '    API:    https://%s\n' "$API_URL"
printf '    Events: https://%s\n' "$EVENTS_URL"
printf '    SSL:    %s\n' "$LE_EMAIL"
printf '\n'

# ---------------------------------------------------------- generate secrets ---

info "Generating random passwords and keys..."

PG_USER="resgrid"
PG_PASS="$(rand_alnum 32)"
REDIS_PASS="$(rand_alnum 32)"
RABBIT_USER="resgrid"
RABBIT_PASS="$(rand_alnum 32)"
LINK_PASSPHRASE="$(rand_alnum 24)"
AUDIO_PASSPHRASE="$(rand_alnum 24)"
APITOKEN_PASSPHRASE="$(rand_alnum 24)"
JWT_EVENTS_SECRET="$(rand_alnum 48)"
PAYLOAD_KEY="$(rand_alnum 96)"
ENCRYPTION_KEY="$(rand_alnum 32)"   # must be exactly 32 characters
ENCRYPTION_SALT="$(rand_alnum 24)"
RUSTFS_ACCESS="$(rand_upper 20)"
RUSTFS_SECRET="$(rand_upper 40)"
TTS_ADMIN_KEY="$(rand_alnum 32)"
FULL_HEALTH_KEY="$(rand_alnum 32)"
SYSTEM_API_KEY="$(rand_alnum 48)"
TRACKER_PEPPER="$(rand_alnum 48)"
RELAY_CLIENT_SECRET="$(rand_alnum 32)"

info "Generating OIDC signing and encryption certificates (10 year validity)..."

CERT_TMP="$(mktemp -d)"
trap 'rm -rf "$CERT_TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$CERT_TMP/enc.key" -out "$CERT_TMP/enc.crt" \
  -subj "/CN=Resgrid OIDC Server Encryption Certificate" \
  -addext "keyUsage=keyEncipherment" >/dev/null 2>&1
openssl pkcs12 -export -out "$CERT_TMP/enc.pfx" \
  -inkey "$CERT_TMP/enc.key" -in "$CERT_TMP/enc.crt" -passout pass:
OIDC_ENC_CERT="$(openssl base64 -A -in "$CERT_TMP/enc.pfx")"

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$CERT_TMP/sig.key" -out "$CERT_TMP/sig.crt" \
  -subj "/CN=Resgrid OIDC Server Signing Certificate" \
  -addext "keyUsage=digitalSignature" >/dev/null 2>&1
openssl pkcs12 -export -out "$CERT_TMP/sig.pfx" \
  -inkey "$CERT_TMP/sig.key" -in "$CERT_TMP/sig.crt" -passout pass:
OIDC_SIGN_CERT="$(openssl base64 -A -in "$CERT_TMP/sig.pfx")"

[ -n "$OIDC_ENC_CERT" ] && [ -n "$OIDC_SIGN_CERT" ] || die "OIDC certificate generation failed."

# ----------------------------------------------------------------- write env ---

info "Writing .env ..."

pg_conn() { # pg_conn <database>
  printf 'User ID=%s;Password=%s;Host=172.16.193.55;Port=5432;Database=%s;Pooling=true;Connection Lifetime=0;Include Error Detail=true;' \
    "$PG_USER" "$PG_PASS" "$1"
}

set_env NGINX_RESGRID_WEB_URL    "$WEB_URL"
set_env NGINX_RESGRID_API_URL    "$API_URL"
set_env NGINX_RESGRID_EVENTS_URL "$EVENTS_URL"
set_env NGINX_LETSENCRYPT_EMAIL  "$LE_EMAIL"

set_env POSTGRES_USER     "$PG_USER"
set_env POSTGRES_PASSWORD "$PG_PASS"
set_env REDIS_PASSWORD    "$REDIS_PASS"
set_env RABBITMQ_USER     "$RABBIT_USER"
set_env RABBITMQ_PASSWORD "$RABBIT_PASS"

set_env RESGRID__SystemBehaviorConfig__ResgridBaseUrl         "https://$WEB_URL"
set_env RESGRID__SystemBehaviorConfig__ResgridApiBaseUrl      "https://$API_URL"
set_env RESGRID__SystemBehaviorConfig__ResgridEventingBaseUrl "https://$EVENTS_URL"

set_env RESGRID__SystemBehaviorConfig__ExternalLinkUrlParamPassphrase  "$LINK_PASSPHRASE"
set_env RESGRID__SystemBehaviorConfig__ExternalAudioUrlParamPasshprase "$AUDIO_PASSPHRASE"
set_env RESGRID__SystemBehaviorConfig__ApiTokenEncryptionPassphrase    "$APITOKEN_PASSPHRASE"

set_env RESGRID__SecurityConfig__EncryptionKey       "$ENCRYPTION_KEY"
set_env RESGRID__SecurityConfig__EncryptionSaltValue "$ENCRYPTION_SALT"

set_env RESGRID__CacheConfig__RedisConnectionString "172.16.193.56:6379,Password=${REDIS_PASS},allowAdmin=True"

set_env RESGRID__DataConfig__ConnectionString         "$(pg_conn resgrid)"
set_env RESGRID__DataConfig__CoreConnectionString     "$(pg_conn resgrid)"
set_env RESGRID__DataConfig__DocumentConnectionString "$(pg_conn resgriddoc)"
set_env RESGRID__OidcConfig__ConnectionString         "$(pg_conn resgridoidc)"
set_env RESGRID__WorkerConfig__WorkerDbConnectionString "$(pg_conn resgridworkers)"

set_env RESGRID__OidcConfig__EncryptionCert "$OIDC_ENC_CERT"
set_env RESGRID__OidcConfig__SigningCert    "$OIDC_SIGN_CERT"

set_env RESGRID__JwtConfig__EventsClientSecret "$JWT_EVENTS_SECRET"

set_env RESGRID__ServiceBusConfig__RabbitUsername  "$RABBIT_USER"
set_env RESGRID__ServiceBusConfig__RabbbitPassword "$RABBIT_PASS"

set_env RESGRID__WorkerConfig__PayloadKey "$PAYLOAD_KEY"

set_env RUSTFS_ACCESS_KEY "$RUSTFS_ACCESS"
set_env RUSTFS_SECRET_KEY "$RUSTFS_SECRET"
set_env RESGRID__TtsConfig__S3AccessKey "$RUSTFS_ACCESS"
set_env RESGRID__TtsConfig__S3SecretKey "$RUSTFS_SECRET"
set_env RESGRID__TtsConfig__StaticPromptAdminKey "$TTS_ADMIN_KEY"
set_env RESGRID__TtsConfig__PlaybackBaseUrl "https://$API_URL"

set_env RESGRID__SystemBehaviorConfig__FullHealthCheckKey "$FULL_HEALTH_KEY"

set_env RESGRID__SecurityConfig__SystemApiKey "$SYSTEM_API_KEY"
set_env RESGRID__RELAY__Resgrid__SystemApiKey "$SYSTEM_API_KEY"
set_env RESGRID__RELAY__Resgrid__ClientSecret "$RELAY_CLIENT_SECRET"
set_env RESGRID__RELAY__Smtp__DepartmentAddressDomains__0 "dispatch.$WEB_URL"

set_env RESGRID__UnitTrackingConfig__CredentialPepper "$TRACKER_PEPPER"

# Self-signed certs internally -> the containers must bypass SSL validation.
if [ "$LE_EMAIL" = "internal" ]; then
  set_env RESGRID__ApiConfig__BypassSslChecks "true"
else
  set_env RESGRID__ApiConfig__BypassSslChecks "false"
fi

chmod 600 .env 2>/dev/null || true

# ------------------------------------------------------------------- start ---

mkdir -p docker-data/sql docker-data/redis/data docker-data/caddy/data docker-data/caddy/config docker-data/rustfs

date > .setup-complete
ok "Configuration written to $INSTALL_DIR/.env (this file now holds all your secrets — back it up, keep it private)."

if [ "${RESGRID_NO_START:-0}" = "1" ]; then
  warn "RESGRID_NO_START=1 set, skipping container startup."
  printf 'Start later with:  cd %s && %s up -d\n' "$INSTALL_DIR" "$COMPOSE"
  exit 0
fi

info "Pulling container images (first run downloads several GB)..."
$COMPOSE pull

info "Starting Resgrid..."
$COMPOSE up -d

# ----------------------------------------------------------------- summary ---

printf '\n'
ok "Resgrid is starting."
cat <<EOF

  First start takes several minutes: the worker container creates and
  migrates the databases before the web app and API become usable.
  Watch progress with:

      cd $INSTALL_DIR && $COMPOSE logs -f worker

  Once it settles, open:

      Web app:   https://$WEB_URL
      API:       https://$API_URL/api/health/getcurrent
      Events:    https://$EVENTS_URL

  Then create your first account and department via 'Sign Up' on the web app.
EOF

case "$WEB_URL" in
  *.mylocal)
    cat <<EOF

  NOTE: You are using .mylocal hostnames. Add entries to the hosts file of
  every machine that will access Resgrid (replace SERVER_IP):

      SERVER_IP  $WEB_URL $API_URL $EVENTS_URL
EOF
    ;;
esac

if [ "$LE_EMAIL" = "internal" ]; then
  cat <<'EOF'

  NOTE: Internal mode uses self-signed certificates, browsers will show a
  certificate warning. Accept the warning for all three hostnames (web, api
  and events) or the web app cannot reach the API.
EOF
fi

cat <<EOF

  Optional add-ons (configure their sections in .env first, see README):

      $COMPOSE --profile tracking up -d   # GPS tracker gateway (ports 5004/5023/5027)
      $COMPOSE --profile relay up -d      # inbound-email dispatch relay (port 25)

  Manage the stack:

      cd $INSTALL_DIR
      $COMPOSE ps               # status
      $COMPOSE logs -f          # logs
      $COMPOSE down             # stop
      $COMPOSE pull && $COMPOSE up -d   # upgrade

EOF
