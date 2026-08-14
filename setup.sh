#!/usr/bin/env bash
# Generate Kubernetes secrets/ingress inputs and optionally deploy Resgrid.

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
  while [ "${#value}" -lt "$length" ]; do value="${value}$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"; done
  printf '%s' "${value:0:length}"
}
rand_upper() {
  local length="$1" value=""
  while [ "${#value}" -lt "$length" ]; do value="${value}$(openssl rand -base64 48 | tr -dc 'A-Z0-9')"; done
  printf '%s' "${value:0:length}"
}
set_env() {
  local path="$1" key="$2" value="$3"
  value="${value//\\/\\\\}"
  value="${value//&/\\&}"
  grep -q "^${key}=" "$path" || die "Key '${key}' is missing from $path."
  sed -i.sedbak "s|^${key}=.*|${key}=${value}|" "$path"
  rm -f "$path.sedbak"
}
strip_scheme() { printf '%s' "$1" | sed -e 's|^https://||' -e 's|^http://||' -e 's|/.*$||'; }

need_cmd openssl "Install OpenSSL with your operating system package manager."
need_cmd sed "Install sed with your operating system package manager."
[ -f .env ] || die "Run this script from a checkout of the multi branch."
[ ! -f .setup-complete ] || die "This checkout is already configured. Preserve deploy/generated/resgrid.env before rotating any secrets."

WEB_URL="${RESGRID_WEB_URL:-$(prompt 'Web hostname' 'rg.mylocal')}"
API_URL="${RESGRID_API_URL:-$(prompt 'API hostname' 'rgapi.mylocal')}"
EVENTS_URL="${RESGRID_EVENTS_URL:-$(prompt 'Events hostname' 'rgevents.mylocal')}"
INGRESS_CLASS="${RESGRID_INGRESS_CLASS:-$(prompt 'IngressClass name' 'traefik')}"
POD_CIDR="${RESGRID_POD_CIDR:-$(prompt 'Pod CIDR trusted for forwarded headers' '10.42.0.0/16')}"

WEB_URL="$(strip_scheme "$WEB_URL")"
API_URL="$(strip_scheme "$API_URL")"
EVENTS_URL="$(strip_scheme "$EVENTS_URL")"
POD_NETWORK="${POD_CIDR%/*}"
POD_PREFIX="${POD_CIDR#*/}"
[ "$POD_NETWORK" != "$POD_PREFIX" ] || die "RESGRID_POD_CIDR must use CIDR notation, for example 10.42.0.0/16."

mkdir -p deploy/generated
SECRET_ENV="deploy/generated/resgrid.env"
cp .env "$SECRET_ENV"

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

if [ -n "${RESGRID_TLS_CERT_FILE:-}" ] || [ -n "${RESGRID_TLS_KEY_FILE:-}" ]; then
  [ -f "${RESGRID_TLS_CERT_FILE:-}" ] && [ -f "${RESGRID_TLS_KEY_FILE:-}" ] || die "Set both RESGRID_TLS_CERT_FILE and RESGRID_TLS_KEY_FILE to readable PEM files."
  cp "$RESGRID_TLS_CERT_FILE" deploy/generated/tls.crt
  cp "$RESGRID_TLS_KEY_FILE" deploy/generated/tls.key
  BYPASS_SSL=false
else
  info "Generating a self-signed ingress certificate"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
    -keyout deploy/generated/tls.key -out deploy/generated/tls.crt \
    -subj "/CN=$WEB_URL" \
    -addext "subjectAltName=DNS:$WEB_URL,DNS:$API_URL,DNS:$EVENTS_URL" >/dev/null 2>&1
  BYPASS_SSL=true
fi

cat > deploy/generated/hosts.env <<EOF
WEB_HOST=$WEB_URL
API_HOST=$API_URL
EVENTS_HOST=$EVENTS_URL
INGRESS_CLASS=$INGRESS_CLASS
EOF

pg_conn() {
  printf 'User ID=%s;Password=%s;Host=postgres;Port=5432;Database=%s;Pooling=true;Connection Lifetime=0;Include Error Detail=true;' "$PG_USER" "$PG_PASS" "$1"
}

set_env "$SECRET_ENV" NGINX_RESGRID_WEB_URL "$WEB_URL"
set_env "$SECRET_ENV" NGINX_RESGRID_API_URL "$API_URL"
set_env "$SECRET_ENV" NGINX_RESGRID_EVENTS_URL "$EVENTS_URL"
set_env "$SECRET_ENV" POSTGRES_USER "$PG_USER"
set_env "$SECRET_ENV" POSTGRES_PASSWORD "$PG_PASS"
set_env "$SECRET_ENV" REDIS_PASSWORD "$REDIS_PASS"
set_env "$SECRET_ENV" RABBITMQ_USER "$RABBIT_USER"
set_env "$SECRET_ENV" RABBITMQ_PASSWORD "$RABBIT_PASS"
set_env "$SECRET_ENV" RUSTFS_ACCESS_KEY "$RUST_ACCESS"
set_env "$SECRET_ENV" RUSTFS_SECRET_KEY "$RUST_SECRET"
set_env "$SECRET_ENV" RESGRID__SystemBehaviorConfig__ResgridBaseUrl "https://$WEB_URL"
set_env "$SECRET_ENV" RESGRID__SystemBehaviorConfig__ResgridApiBaseUrl "https://$API_URL"
set_env "$SECRET_ENV" RESGRID__SystemBehaviorConfig__ResgridEventingBaseUrl "https://$EVENTS_URL"
set_env "$SECRET_ENV" RESGRID__SystemBehaviorConfig__ExternalLinkUrlParamPassphrase "$(rand_alnum 24)"
set_env "$SECRET_ENV" RESGRID__SystemBehaviorConfig__ExternalAudioUrlParamPasshprase "$(rand_alnum 24)"
set_env "$SECRET_ENV" RESGRID__SystemBehaviorConfig__ApiTokenEncryptionPassphrase "$(rand_alnum 24)"
set_env "$SECRET_ENV" RESGRID__SystemBehaviorConfig__FullHealthCheckKey "$(rand_alnum 32)"
set_env "$SECRET_ENV" RESGRID__SecurityConfig__EncryptionKey "$(rand_alnum 32)"
set_env "$SECRET_ENV" RESGRID__SecurityConfig__EncryptionSaltValue "$(rand_alnum 24)"
set_env "$SECRET_ENV" RESGRID__SecurityConfig__SystemApiKey "$SYSTEM_API_KEY"
set_env "$SECRET_ENV" RESGRID__CacheConfig__RedisConnectionString "redis:6379,Password=$REDIS_PASS,allowAdmin=True"
set_env "$SECRET_ENV" RESGRID__DataConfig__ConnectionString "$(pg_conn resgrid)"
set_env "$SECRET_ENV" RESGRID__DataConfig__CoreConnectionString "$(pg_conn resgrid)"
set_env "$SECRET_ENV" RESGRID__DataConfig__DocumentConnectionString "$(pg_conn resgriddoc)"
set_env "$SECRET_ENV" RESGRID__OidcConfig__ConnectionString "$(pg_conn resgridoidc)"
set_env "$SECRET_ENV" RESGRID__OidcConfig__EncryptionCert "$OIDC_ENC_CERT"
set_env "$SECRET_ENV" RESGRID__OidcConfig__SigningCert "$OIDC_SIGN_CERT"
set_env "$SECRET_ENV" RESGRID__JwtConfig__EventsClientSecret "$(rand_alnum 48)"
set_env "$SECRET_ENV" RESGRID__ApiConfig__BypassSslChecks "$BYPASS_SSL"
set_env "$SECRET_ENV" RESGRID__ServiceBusConfig__RabbitHostname rabbitmq
set_env "$SECRET_ENV" RESGRID__ServiceBusConfig__RabbitUsername "$RABBIT_USER"
set_env "$SECRET_ENV" RESGRID__ServiceBusConfig__RabbbitPassword "$RABBIT_PASS"
set_env "$SECRET_ENV" RESGRID__WorkerConfig__WorkerDbConnectionString "$(pg_conn resgridworkers)"
set_env "$SECRET_ENV" RESGRID__WorkerConfig__PayloadKey "$(rand_alnum 96)"
set_env "$SECRET_ENV" RESGRID__WebConfig__IngressProxyNetwork "$POD_NETWORK"
set_env "$SECRET_ENV" RESGRID__WebConfig__IngressProxyNetworkCidr "$POD_PREFIX"
set_env "$SECRET_ENV" RESGRID__TtsConfig__ServiceBaseUrl 'http://tts:8080'
set_env "$SECRET_ENV" RESGRID__TtsConfig__PlaybackBaseUrl "https://$API_URL"
set_env "$SECRET_ENV" RESGRID__TtsConfig__StaticPromptAdminKey "$(rand_alnum 32)"
set_env "$SECRET_ENV" RESGRID__TtsConfig__S3Endpoint 'http://rustfs:9000'
set_env "$SECRET_ENV" RESGRID__TtsConfig__S3AccessKey "$RUST_ACCESS"
set_env "$SECRET_ENV" RESGRID__TtsConfig__S3SecretKey "$RUST_SECRET"
set_env "$SECRET_ENV" RESGRID__UnitTrackingConfig__CredentialPepper "$(rand_alnum 48)"
set_env "$SECRET_ENV" RESGRID__RELAY__Resgrid__BaseUrl 'http://api:80'
set_env "$SECRET_ENV" RESGRID__RELAY__Resgrid__SystemApiKey "$SYSTEM_API_KEY"
set_env "$SECRET_ENV" RESGRID__RELAY__Resgrid__ClientSecret "$(rand_alnum 32)"
set_env "$SECRET_ENV" RESGRID__RELAY__Smtp__DepartmentAddressDomains__0 "dispatch.$WEB_URL"

chmod 600 "$SECRET_ENV" deploy/generated/tls.key
need_cmd kubectl "Install kubectl or use 'k3s kubectl'."
info "Validating generated manifests"
kubectl kustomize deploy >/dev/null
date > .setup-complete

if [ "${RESGRID_NO_APPLY:-0}" = 1 ]; then
  info "Generated deploy inputs; RESGRID_NO_APPLY=1, so the cluster was not changed."
  exit 0
fi

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
[ -n "$CURRENT_CONTEXT" ] || die "kubectl has no current context."

if [ "${RESGRID_APPLY:-0}" != 1 ]; then
  answer="$(prompt "Apply Resgrid to Kubernetes context '$CURRENT_CONTEXT'? Type yes" 'no')"
  [ "$answer" = yes ] || die "Not applied. Re-run with RESGRID_APPLY=1 after verifying the context."
fi

if ! kubectl get nodes -l kubernetes.io/arch=amd64 -o name | grep -q .; then
  die "No Ready/registered amd64 node was found. Current Resgrid application images are amd64-only; add an amd64 worker before applying."
fi

info "Applying Resgrid to context $CURRENT_CONTEXT"
kubectl apply -k deploy

cat <<EOF

Resgrid resources were applied to namespace resgrid.

Watch infrastructure and migrations:
  kubectl -n resgrid get pods -w
  kubectl -n resgrid logs -f deployment/worker

The ingress hosts are:
  https://$WEB_URL
  https://$API_URL
  https://$EVENTS_URL

If a self-signed certificate was generated, distribute and trust
deploy/generated/tls.crt on client devices.
EOF
