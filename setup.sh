#!/usr/bin/env bash
# Configure one shared Resgrid Incident Command Kit checkout. Run once, then
# securely copy the configured checkout (including .env) to all three nodes.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

info() { printf '==> %s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required. $2"; }

prompt() {
  local question="$1" default="$2" answer=""
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '%s [%s]: ' "$question" "$default" >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
  fi
  printf '%s' "${answer:-$default}"
}

rand_alnum() {
  local length="$1" value=""
  while [ "${#value}" -lt "$length" ]; do
    value="${value}$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${value:0:length}"
}

rand_upper() {
  local length="$1" value=""
  while [ "${#value}" -lt "$length" ]; do
    value="${value}$(openssl rand -base64 48 | tr -dc 'A-Z0-9')"
  done
  printf '%s' "${value:0:length}"
}

set_env() {
  local key="$1" value="$2"
  value="${value//\\/\\\\}"
  value="${value//&/\\&}"
  grep -q "^${key}=" .env || die "Key '${key}' is missing from .env."
  sed -i.sedbak "s|^${key}=.*|${key}=${value}|" .env
  rm -f .env.sedbak
}

strip_scheme() { printf '%s' "$1" | sed -e 's|^https://||' -e 's|^http://||' -e 's|/.*$||'; }

need_cmd openssl "Install it with: sudo apt install openssl"
need_cmd sed "Install it with: sudo apt install sed"
[ -f .env ] || die "Run this script from a checkout of the rick branch."
[ ! -f .setup-complete ] || die "This kit is already configured. Preserve .env unless you intend to invalidate its credentials and encryption keys."

printf '\nResgrid Incident Command Kit configuration\n\n'
WEB_URL="${RESGRID_WEB_URL:-$(prompt 'Web hostname' 'rg.rick.local')}"
API_URL="${RESGRID_API_URL:-$(prompt 'API hostname' 'rgapi.rick.local')}"
EVENTS_URL="${RESGRID_EVENTS_URL:-$(prompt 'Events hostname' 'rgevents.rick.local')}"
LE_EMAIL="${RESGRID_LETSENCRYPT_EMAIL:-$(prompt "Let's Encrypt email ('internal' for an offline kit)" 'internal')}"
WEB_NODE="${RESGRID_RICK_WEB_HOST:-$(prompt 'Web/API node LAN address' '192.168.50.11')}"
INFRA_NODE="${RESGRID_RICK_INFRA_HOST:-$(prompt 'Infrastructure node LAN address' '192.168.50.12')}"
DATABASE_NODE="${RESGRID_RICK_DATABASE_HOST:-$(prompt 'Database node LAN address' '192.168.50.13')}"

WEB_URL="$(strip_scheme "$WEB_URL")"
API_URL="$(strip_scheme "$API_URL")"
EVENTS_URL="$(strip_scheme "$EVENTS_URL")"

info "Generating credentials and OpenIddict certificates"
PG_USER="resgrid"
PG_PASS="$(rand_alnum 32)"
REDIS_PASS="$(rand_alnum 32)"
RABBIT_USER="resgrid"
RABBIT_PASS="$(rand_alnum 32)"
RUST_ACCESS="$(rand_upper 20)"
RUST_SECRET="$(rand_upper 40)"
SYSTEM_API_KEY="$(rand_alnum 48)"

CERT_DIR="$(mktemp -d)"
trap 'rm -rf "$CERT_DIR"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$CERT_DIR/enc.key" -out "$CERT_DIR/enc.crt" \
  -subj '/CN=Resgrid OIDC Server Encryption Certificate' \
  -addext 'keyUsage=keyEncipherment' >/dev/null 2>&1
openssl pkcs12 -export -out "$CERT_DIR/enc.pfx" -inkey "$CERT_DIR/enc.key" -in "$CERT_DIR/enc.crt" -passout pass:
OIDC_ENC_CERT="$(openssl base64 -A -in "$CERT_DIR/enc.pfx")"

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$CERT_DIR/sig.key" -out "$CERT_DIR/sig.crt" \
  -subj '/CN=Resgrid OIDC Server Signing Certificate' \
  -addext 'keyUsage=digitalSignature' >/dev/null 2>&1
openssl pkcs12 -export -out "$CERT_DIR/sig.pfx" -inkey "$CERT_DIR/sig.key" -in "$CERT_DIR/sig.crt" -passout pass:
OIDC_SIGN_CERT="$(openssl base64 -A -in "$CERT_DIR/sig.pfx")"

pg_conn() {
  printf 'User ID=%s;Password=%s;Host=%s;Port=5432;Database=%s;Pooling=true;Connection Lifetime=0;Include Error Detail=true;' \
    "$PG_USER" "$PG_PASS" "$DATABASE_NODE" "$1"
}

set_env RICK_WEB_HOST "$WEB_NODE"
set_env RICK_INFRA_HOST "$INFRA_NODE"
set_env RICK_DATABASE_HOST "$DATABASE_NODE"
set_env NGINX_RESGRID_WEB_URL "$WEB_URL"
set_env NGINX_RESGRID_API_URL "$API_URL"
set_env NGINX_RESGRID_EVENTS_URL "$EVENTS_URL"
set_env NGINX_LETSENCRYPT_EMAIL "$LE_EMAIL"
set_env POSTGRES_USER "$PG_USER"
set_env POSTGRES_PASSWORD "$PG_PASS"
set_env REDIS_PASSWORD "$REDIS_PASS"
set_env RABBITMQ_USER "$RABBIT_USER"
set_env RABBITMQ_PASSWORD "$RABBIT_PASS"
set_env RUSTFS_ACCESS_KEY "$RUST_ACCESS"
set_env RUSTFS_SECRET_KEY "$RUST_SECRET"
set_env RESGRID__SystemBehaviorConfig__ResgridBaseUrl "https://$WEB_URL"
set_env RESGRID__SystemBehaviorConfig__ResgridApiBaseUrl "https://$API_URL"
set_env RESGRID__SystemBehaviorConfig__ResgridEventingBaseUrl "https://$EVENTS_URL"
set_env RESGRID__SystemBehaviorConfig__ExternalLinkUrlParamPassphrase "$(rand_alnum 24)"
set_env RESGRID__SystemBehaviorConfig__ExternalAudioUrlParamPasshprase "$(rand_alnum 24)"
set_env RESGRID__SystemBehaviorConfig__ApiTokenEncryptionPassphrase "$(rand_alnum 24)"
set_env RESGRID__SystemBehaviorConfig__FullHealthCheckKey "$(rand_alnum 32)"
set_env RESGRID__SecurityConfig__EncryptionKey "$(rand_alnum 32)"
set_env RESGRID__SecurityConfig__EncryptionSaltValue "$(rand_alnum 24)"
set_env RESGRID__SecurityConfig__SystemApiKey "$SYSTEM_API_KEY"
set_env RESGRID__CacheConfig__RedisConnectionString "$INFRA_NODE:6379,Password=$REDIS_PASS,allowAdmin=True"
set_env RESGRID__DataConfig__ConnectionString "$(pg_conn resgrid)"
set_env RESGRID__DataConfig__CoreConnectionString "$(pg_conn resgrid)"
set_env RESGRID__DataConfig__DocumentConnectionString "$(pg_conn resgriddoc)"
set_env RESGRID__OidcConfig__ConnectionString "$(pg_conn resgridoidc)"
set_env RESGRID__OidcConfig__EncryptionCert "$OIDC_ENC_CERT"
set_env RESGRID__OidcConfig__SigningCert "$OIDC_SIGN_CERT"
set_env RESGRID__JwtConfig__EventsClientSecret "$(rand_alnum 48)"
set_env RESGRID__ApiConfig__BypassSslChecks "$([ "$LE_EMAIL" = internal ] && printf true || printf false)"
set_env RESGRID__ServiceBusConfig__RabbitHostname "$INFRA_NODE"
set_env RESGRID__ServiceBusConfig__RabbitUsername "$RABBIT_USER"
set_env RESGRID__ServiceBusConfig__RabbbitPassword "$RABBIT_PASS"
set_env RESGRID__WorkerConfig__WorkerDbConnectionString "$(pg_conn resgridworkers)"
set_env RESGRID__WorkerConfig__PayloadKey "$(rand_alnum 96)"
set_env RESGRID__TtsConfig__ServiceBaseUrl 'http://tts:8080'
set_env RESGRID__TtsConfig__PlaybackBaseUrl "https://$API_URL"
set_env RESGRID__TtsConfig__StaticPromptAdminKey "$(rand_alnum 32)"
set_env RESGRID__TtsConfig__S3Endpoint "http://$INFRA_NODE:9000"
set_env RESGRID__TtsConfig__S3AccessKey "$RUST_ACCESS"
set_env RESGRID__TtsConfig__S3SecretKey "$RUST_SECRET"
set_env RESGRID__UnitTrackingConfig__CredentialPepper "$(rand_alnum 48)"
set_env RESGRID__RELAY__Resgrid__BaseUrl 'http://api:80'
set_env RESGRID__RELAY__Resgrid__SystemApiKey "$SYSTEM_API_KEY"
set_env RESGRID__RELAY__Resgrid__ClientSecret "$(rand_alnum 32)"
set_env RESGRID__RELAY__Smtp__DepartmentAddressDomains__0 "dispatch.$WEB_URL"

chmod 600 .env
mkdir -p docker-data/postgres docker-data/redis docker-data/rustfs docker-data/osm docker-data/caddy/data docker-data/caddy/config
date > .setup-complete

cat <<EOF

Configuration complete.

1. Securely copy this entire checkout to all three nodes. The .env file must
   be identical on every node and must be protected as a secret.
2. On the database node ($DATABASE_NODE):  ./rick.sh database start
3. On the infra node ($INFRA_NODE):        ./rick.sh infra start
4. After those are healthy, on the web node ($WEB_NODE): ./rick.sh web start
5. Follow first-run migrations on the web node: ./rick.sh web logs worker

Clients must resolve these names to $WEB_NODE:
  $WEB_URL $API_URL $EVENTS_URL
EOF
