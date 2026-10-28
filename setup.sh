#!/usr/bin/env bash
#
# Resgrid on Kubernetes / k3s: generate configuration and deploy.
#
# Commands:
#   ./setup.sh                 first run: configure (deploy/generated/) and deploy.
#                              Every later run upgrades and repairs the install:
#                              keeps your settings and secrets, adds new settings,
#                              re-applies the manifests, rolls out new images,
#                              then offers the optional features.
#   ./setup.sh upgrade         git pull, then the same as above
#   ./setup.sh features        turn optional features (features/catalog.ini) on/off
#   ./setup.sh features --all  also list feature flags the catalog doesn't cover
#   ./setup.sh renew-cert      re-issue the ingress certificate from the local CA
#
# Non-interactive example:
#   RESGRID_WEB_HOST=dispatch.example.com RESGRID_API_HOST=dispatchapi.example.com \
#   RESGRID_EVENTS_HOST=dispatchevents.example.com RESGRID_INGRESS_CLASS=traefik \
#   RESGRID_POD_CIDR=10.42.0.0/16 RESGRID_TLS_CERT_FILE=/secure/fullchain.pem \
#   RESGRID_TLS_KEY_FILE=/secure/privkey.pem RESGRID_FEATURES=records,search \
#   RESGRID_APPLY=1 ./setup.sh
#
# Other variables:
#   RESGRID_INGRESS_IP   address the pods use to reach the ingress for the
#                        public hostnames (default: the ingress controller's
#                        ClusterIP, detected for Traefik and ingress-nginx)
#   RESGRID_FEATURES     optional features to have on (comma separated section
#                        names from features/catalog.ini, "all" or "none");
#                        sections not listed are switched off
#   RESGRID_NONINTERACTIVE=1  never ask; keep features as they are
#   RESGRID_NO_APPLY=1   generate files only, don't touch the cluster
#   RESGRID_APPLY=1      apply to a new kubectl context without asking
#   KUBECTL              kubectl command (default: kubectl, or "k3s kubectl")

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
COMMAND="${1:-install}"
SUBARG="${2:-}"
GEN="deploy/generated"
ENV_FILE="$GEN/resgrid.env"
REPO_URL="https://github.com/Resgrid/resgrid-setup"
BRANCH="multi"

info() { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required. $2"; }
interactive() { [ "${RESGRID_NONINTERACTIVE:-0}" != 1 ] && { : </dev/tty >/dev/tty; } 2>/dev/null; }
prompt() {
  local question="$1" default="$2" answer=""
  if interactive; then
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
has_env() { grep -q "^$1=" "$ENV_FILE"; }
get_env() { grep "^$1=" "$ENV_FILE" 2>/dev/null | head -n 1 | cut -d= -f2- || true; }
sed_escape() { local v="$1"; v="${v//\\/\\\\}"; v="${v//&/\\&}"; v="${v//|/\\|}"; printf '%s' "$v"; }
set_env() {
  has_env "$1" || die "Key '$1' is missing from $ENV_FILE."
  sed -i.sedbak "s|^$1=.*|$1=$(sed_escape "$2")|" "$ENV_FILE"
  rm -f "$ENV_FILE.sedbak"
}
upsert_env() { if has_env "$1"; then set_env "$1" "$2"; else printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"; fi; }
replace_in_env() {
  local from
  from="$(printf '%s' "$1" | sed 's/[.[\*^$|]/\\&/g')"
  sed -i.sedbak "s|${from}|$2|g" "$ENV_FILE"
  rm -f "$ENV_FILE.sedbak"
}
is_placeholder() { case "$1" in *[Cc][Hh][Aa][Nn][Gg][Ee][Mm][Ee]*|"") return 0 ;; *) return 1 ;; esac; }
strip_scheme() { printf '%s' "$1" | sed -e 's|^https://||' -e 's|^http://||' -e 's|/.*$||'; }
in_list() { case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

if [ -n "${KUBECTL:-}" ]; then
  read -r -a KC <<< "$KUBECTL"
elif command -v kubectl >/dev/null 2>&1; then
  KC=(kubectl)
elif command -v k3s >/dev/null 2>&1; then
  KC=(k3s kubectl)
else
  KC=()
fi
kc() { [ "${#KC[@]}" -gt 0 ] || die "kubectl is required (or run on a k3s server)."; "${KC[@]}" "$@"; }

# OpenIddict signing and encryption certificates: PKCS#12 with an empty
# password, base64 encoded (Core loads them without a password).
oidc_cert() { # oidc_cert <name> <key usage>
  local tmp out
  tmp="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$tmp/$1.key" -out "$tmp/$1.crt" \
    -subj "/CN=Resgrid OIDC Server $1 Certificate" -addext "keyUsage=$2" >/dev/null 2>&1
  openssl pkcs12 -export -out "$tmp/$1.pfx" -inkey "$tmp/$1.key" -in "$tmp/$1.crt" -passout pass: >/dev/null 2>&1
  out="$(openssl base64 -A -in "$tmp/$1.pfx")"
  rm -rf "$tmp"
  printf '%s' "$out"
}

# Resgrid's local certificate authority (kept when it exists).
make_ca() {
  [ -f "$GEN/ca.crt" ] && [ -f "$GEN/ca.key" ] && return 0
  info "Creating the Resgrid local certificate authority"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -days 3650 -nodes \
    -keyout "$GEN/ca.key" -out "$GEN/ca.crt" \
    -subj "/O=Resgrid self-hosted/CN=Resgrid Local CA $(get_env RESGRID_WEB_HOST)" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1 || die "Creating the local CA failed."
  chmod 600 "$GEN/ca.key"
}

# Issue the ingress certificate (all three hostnames) from the local CA.
issue_ingress_cert() {
  local web api events tmp
  web="$(get_env RESGRID_WEB_HOST)"; api="$(get_env RESGRID_API_HOST)"; events="$(get_env RESGRID_EVENTS_HOST)"
  tmp="$(mktemp -d)"
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$GEN/tls.key" -out "$tmp/tls.csr" -subj "/CN=$web" >/dev/null 2>&1
  printf 'subjectAltName=DNS:%s,DNS:%s,DNS:%s\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\nbasicConstraints=critical,CA:FALSE\n' \
    "$web" "$api" "$events" > "$tmp/ext.cnf"
  # 397 days: the longest lifetime every browser and iOS accepts.
  openssl x509 -req -in "$tmp/tls.csr" -CA "$GEN/ca.crt" -CAkey "$GEN/ca.key" -CAcreateserial \
    -days 397 -sha256 -extfile "$tmp/ext.cnf" -out "$tmp/leaf.crt" >/dev/null 2>&1 || die "Issuing the ingress certificate failed."
  cat "$tmp/leaf.crt" "$GEN/ca.crt" > "$GEN/tls.crt"
  rm -rf "$tmp" "$GEN/ca.srl"
  chmod 600 "$GEN/tls.key"
  info "Issued the ingress certificate for $web, $api, $events (valid 397 days; renew with ./setup.sh renew-cert)."
}

write_hosts_env() {
  cat > "$GEN/hosts.env" <<EOF
WEB_HOST=$(get_env RESGRID_WEB_HOST)
API_HOST=$(get_env RESGRID_API_HOST)
EVENTS_HOST=$(get_env RESGRID_EVENTS_HOST)
INGRESS_CLASS=$1
EOF
}

# Pods resolve the public hostnames to the ingress controller, so server-side
# calls (web -> API token endpoint, events -> API, MCP -> API) stay inside the
# cluster and work without internal DNS.
write_host_aliases() {
  local ip="${RESGRID_INGRESS_IP:-}"
  if [ -z "$ip" ] && [ "${#KC[@]}" -gt 0 ]; then
    ip="$(kc -n kube-system get svc traefik -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
    [ -n "$ip" ] || ip="$(kc -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  fi
  if [ -n "$ip" ]; then
    cat > "$GEN/host-aliases.yaml" <<EOF
- op: add
  path: /spec/template/spec/hostAliases
  value:
    - ip: "$ip"
      hostnames: ["$(get_env RESGRID_WEB_HOST)", "$(get_env RESGRID_API_HOST)", "$(get_env RESGRID_EVENTS_HOST)"]
EOF
    info "Pods will reach the public hostnames through the ingress at $ip."
  else
    printf -- '- op: add\n  path: /spec/template/spec/hostAliases\n  value: []\n' > "$GEN/host-aliases.yaml"
    warn "Ingress controller address not found: pods will use DNS for the public hostnames. Set RESGRID_INGRESS_IP if they don't resolve inside the cluster."
  fi
}

# ------------------------------------------------- feature engine hooks ---

# shellcheck disable=SC2034  # read by lib/features.sh
FEAT_PROFILE_KEY=RESGRID_OPTIONAL
feat_psql() { kc -n resgrid exec -i statefulset/db -c postgres -- psql -v ON_ERROR_STOP=1 -At -U "$(get_env POSTGRES_USER)" -d resgrid -c "$1"; }
# REDISCLI_AUTH is set in the redis pod.
feat_redis() { kc -n resgrid exec -i statefulset/redis -c redis -- redis-cli --no-auth-warning "$@"; }

# ------------------------------------------------- repository download ---

# Bring the checkout up to date without losing local files. Installs from
# before October 2026 tracked .env in git: keep it aside while pulling.
update_checkout() {
  if [ -d .git ] && command -v git >/dev/null 2>&1; then
    local saved=""
    if git ls-files --error-unmatch .env >/dev/null 2>&1; then
      saved="$(mktemp)"; cp .env "$saved"
      git checkout -- .env 2>/dev/null || true
    fi
    info "Updating the setup files (git pull)..."
    git pull --ff-only || warn "git pull failed (local changes to tracked files?). Continuing with the files you have."
    if [ -n "$saved" ]; then cp "$saved" .env; rm -f "$saved"; chmod 600 .env; fi
  elif command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
    info "Updating the setup files (download)..."
    # The archive has no deploy/generated/ files, so nothing of yours is overwritten.
    curl -fsSL "$REPO_URL/archive/refs/heads/$BRANCH.tar.gz" | tar -xz --strip-components=1 -C . ||
      warn "Download failed. Continuing with the files you have."
  fi
}

# --------------------------------------------- configuration: new install ---

configure_new() {
  local web api events ingress_class pod_cidr pod_network pod_prefix
  web="$(strip_scheme "${RESGRID_WEB_HOST:-${RESGRID_WEB_URL:-$(prompt 'Web hostname' 'rg.mylocal')}}")"
  api="$(strip_scheme "${RESGRID_API_HOST:-${RESGRID_API_URL:-$(prompt 'API hostname' 'rgapi.mylocal')}}")"
  events="$(strip_scheme "${RESGRID_EVENTS_HOST:-${RESGRID_EVENTS_URL:-$(prompt 'Events hostname' 'rgevents.mylocal')}}")"
  ingress_class="${RESGRID_INGRESS_CLASS:-$(prompt 'IngressClass name' 'traefik')}"
  pod_cidr="${RESGRID_POD_CIDR:-$(prompt 'Pod CIDR trusted for forwarded headers' '10.42.0.0/16')}"
  pod_network="${pod_cidr%/*}"
  pod_prefix="${pod_cidr#*/}"
  [ "$pod_network" != "$pod_prefix" ] || die "RESGRID_POD_CIDR must use CIDR notation, for example 10.42.0.0/16."

  info "Generating credentials, keys and certificates in $GEN"
  cp .env.example "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  local pg_pass redis_pass rabbit_pass rust_access rust_secret system_api_key section
  pg_pass="$(rand_alnum 32)"
  redis_pass="$(rand_alnum 32)"
  rabbit_pass="$(rand_alnum 32)"
  rust_access="$(rand_upper 20)"
  rust_secret="$(rand_upper 40)"
  system_api_key="$(rand_alnum 48)"
  pg_conn() {
    printf 'User ID=resgrid;Password=%s;Host=db;Port=5432;Database=%s;Pooling=true;Connection Lifetime=0;Include Error Detail=true;' "$pg_pass" "$1"
  }

  set_env RESGRID_WEB_HOST "$web"
  set_env RESGRID_API_HOST "$api"
  set_env RESGRID_EVENTS_HOST "$events"
  set_env POSTGRES_PASSWORD "$pg_pass"
  set_env REDIS_PASSWORD "$redis_pass"
  set_env RABBITMQ_PASSWORD "$rabbit_pass"
  set_env RUSTFS_ACCESS_KEY "$rust_access"
  set_env RUSTFS_SECRET_KEY "$rust_secret"
  set_env RESGRID__SystemBehaviorConfig__ResgridBaseUrl "https://$web"
  set_env RESGRID__SystemBehaviorConfig__ResgridApiBaseUrl "https://$api"
  set_env RESGRID__SystemBehaviorConfig__ResgridEventingBaseUrl "https://$events"
  set_env RESGRID__SystemBehaviorConfig__ExternalLinkUrlParamPassphrase "$(rand_alnum 24)"
  set_env RESGRID__SystemBehaviorConfig__ExternalAudioUrlParamPasshprase "$(rand_alnum 24)"
  set_env RESGRID__SystemBehaviorConfig__ApiTokenEncryptionPassphrase "$(rand_alnum 24)"
  set_env RESGRID__SystemBehaviorConfig__FullHealthCheckKey "$(rand_alnum 32)"
  set_env RESGRID__SecurityConfig__EncryptionKey "$(rand_alnum 32)"
  set_env RESGRID__SecurityConfig__EncryptionSaltValue "$(rand_alnum 24)"
  set_env RESGRID__SecurityConfig__SystemApiKey "$system_api_key"
  set_env RESGRID__SecurityConfig__DepartmentApiKeyPepper "$(rand_alnum 48)"
  set_env RESGRID__ApiConfig__BackendInternalApikey "$(rand_alnum 48)"
  set_env RESGRID__CacheConfig__RedisConnectionString "redis:6379,password=$redis_pass,allowAdmin=True"
  set_env RESGRID__DataConfig__ConnectionString "$(pg_conn resgrid)"
  set_env RESGRID__DataConfig__CoreConnectionString "$(pg_conn resgrid)"
  set_env RESGRID__DataConfig__DocumentConnectionString "$(pg_conn resgriddoc)"
  set_env RESGRID__OidcConfig__ConnectionString "$(pg_conn resgridoidc)"
  set_env RESGRID__WorkerConfig__WorkerDbConnectionString "$(pg_conn resgridworkers)"
  set_env RESGRID__JwtConfig__EventsClientSecret "$(rand_alnum 48)"
  set_env RESGRID__ServiceBusConfig__RabbbitPassword "$rabbit_pass"
  set_env RESGRID__WorkerConfig__PayloadKey "$(rand_alnum 96)"
  set_env RESGRID__WebConfig__IngressProxyNetwork "$pod_network"
  set_env RESGRID__WebConfig__IngressProxyNetworkCidr "$pod_prefix"
  set_env RESGRID__TtsConfig__PlaybackBaseUrl "https://$api"
  set_env RESGRID__TtsConfig__StaticPromptAdminKey "$(rand_alnum 32)"
  for section in TtsConfig ImportConfig; do
    set_env "RESGRID__${section}__S3AccessKey" "$rust_access"
    set_env "RESGRID__${section}__S3SecretKey" "$rust_secret"
  done
  set_env RESGRID__UnitTrackingConfig__CredentialPepper "$(rand_alnum 48)"
  set_env RESGRID__RELAY__Resgrid__SystemApiKey "$system_api_key"
  set_env RESGRID__RELAY__Resgrid__ClientSecret "$(rand_alnum 32)"
  set_env RESGRID__RELAY__Smtp__DepartmentAddressDomains__0 "dispatch.$web"
  set_env RESGRID__OidcConfig__EncryptionCert "$(oidc_cert Encryption keyEncipherment)"
  set_env RESGRID__OidcConfig__SigningCert "$(oidc_cert Signing digitalSignature)"

  make_ca
  if [ -n "${RESGRID_TLS_CERT_FILE:-}" ] || [ -n "${RESGRID_TLS_KEY_FILE:-}" ]; then
    [ -f "${RESGRID_TLS_CERT_FILE:-}" ] && [ -f "${RESGRID_TLS_KEY_FILE:-}" ] || die "Set both RESGRID_TLS_CERT_FILE and RESGRID_TLS_KEY_FILE to readable PEM files."
    cp "$RESGRID_TLS_CERT_FILE" "$GEN/tls.crt"
    cp "$RESGRID_TLS_KEY_FILE" "$GEN/tls.key"
    chmod 600 "$GEN/tls.key"
    set_env RESGRID_TLS files
    info "Using your certificate for the ingress."
  else
    issue_ingress_cert
  fi
  write_hosts_env "$ingress_class"
  write_host_aliases
  date > .setup-complete
}

# ------------------------------------------ configuration: existing install ---

# Bring resgrid.env up to date. Never replaces a value you set, never rotates
# a secret your data depends on; only renames old settings, fills in settings
# that are missing or empty, and fixes values known to break.
reconcile_env() {
  local backup line key value added=0
  backup="$ENV_FILE.backup-$(date +%Y%m%d-%H%M%S)"
  cp "$ENV_FILE" "$backup"; chmod 600 "$backup"
  info "Checking your configuration (backup: $backup)"

  # Settings renamed in October 2026 (NGINX_* -> RESGRID_*).
  if ! has_env RESGRID_WEB_HOST && has_env NGINX_RESGRID_WEB_URL; then
    info "Renaming NGINX_* settings to RESGRID_WEB_HOST / RESGRID_API_HOST / RESGRID_EVENTS_HOST / RESGRID_TLS"
    {
      printf '\n# Hostnames and TLS (renamed from NGINX_* by setup.sh)\n'
      printf 'RESGRID_WEB_HOST=%s\n' "$(get_env NGINX_RESGRID_WEB_URL)"
      printf 'RESGRID_API_HOST=%s\n' "$(get_env NGINX_RESGRID_API_URL)"
      printf 'RESGRID_EVENTS_HOST=%s\n' "$(get_env NGINX_RESGRID_EVENTS_URL)"
      printf 'RESGRID_TLS=%s\n' "$(get_env NGINX_LETSENCRYPT_EMAIL)"
    } >> "$ENV_FILE"
  fi
  if has_env ASPNETCORE_URLS && [ "$(get_env ASPNETCORE_URLS)" != "http://+:8080" ]; then set_env ASPNETCORE_URLS "http://+:8080"; fi
  if [ "$(get_env RESGRID__ApiConfig__BypassSslChecks)" = "true" ]; then set_env RESGRID__ApiConfig__BypassSslChecks false; fi
  replace_in_env "RESGRID__RELAY__Resgrid__BaseUrl=http://172.16.193.52" "RESGRID__RELAY__Resgrid__BaseUrl=http://api:8080"

  # Settings introduced since this install was created. New secrets get a
  # random value; everything else the template default. The department API
  # key pepper stays empty on existing installs: empty means "derived from the
  # encryption key", which is what existing department API keys were made with.
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    has_env "$key" && continue
    case "$key" in
      RESGRID__ApiConfig__BackendInternalApikey) value="$(rand_alnum 48)" ;;
      RESGRID__SystemBehaviorConfig__FullHealthCheckKey) value="$(rand_alnum 32)" ;;
      RESGRID__SecurityConfig__DepartmentApiKeyPepper) value="" ;;
      RESGRID__*Config__S3AccessKey) [ "${key#*Search}" = "$key" ] && value="$(get_env RUSTFS_ACCESS_KEY)" || value="" ;;
      RESGRID__*Config__S3SecretKey) [ "${key#*Search}" = "$key" ] && value="$(get_env RUSTFS_SECRET_KEY)" || value="" ;;
      *) value="${line#*=}" ;;
    esac
    [ "$added" -eq 0 ] && printf '\n# Added by setup.sh on %s\n' "$(date +%F)" >> "$ENV_FILE"
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    info "Added $key"
    added=$((added + 1))
  done < .env.example

  # Required values that are empty can be generated safely.
  [ -n "$(get_env RESGRID__ApiConfig__BackendInternalApikey)" ] || set_env RESGRID__ApiConfig__BackendInternalApikey "$(rand_alnum 48)"
  [ -n "$(get_env RESGRID__SecurityConfig__SystemApiKey)" ] || set_env RESGRID__SecurityConfig__SystemApiKey "$(rand_alnum 48)"
  [ -n "$(get_env RESGRID__RELAY__Resgrid__SystemApiKey)" ] || set_env RESGRID__RELAY__Resgrid__SystemApiKey "$(get_env RESGRID__SecurityConfig__SystemApiKey)"
  # Events tokens are short-lived, so a placeholder secret can be replaced.
  if is_placeholder "$(get_env RESGRID__JwtConfig__EventsClientSecret)" || [ "$(get_env RESGRID__JwtConfig__EventsClientSecret)" = "SecretKeyChangeMe1234!" ]; then
    set_env RESGRID__JwtConfig__EventsClientSecret "$(rand_alnum 48)"
  fi
  if [ -z "$(get_env RESGRID__OidcConfig__EncryptionCert)" ] || [ -z "$(get_env RESGRID__OidcConfig__SigningCert)" ]; then
    info "Creating the missing OpenID Connect certificates"
    set_env RESGRID__OidcConfig__EncryptionCert "$(oidc_cert Encryption keyEncipherment)"
    set_env RESGRID__OidcConfig__SigningCert "$(oidc_cert Signing digitalSignature)"
  fi

  # Placeholders that can't be changed without losing access to existing data.
  for key in POSTGRES_PASSWORD REDIS_PASSWORD RABBITMQ_PASSWORD RESGRID__SecurityConfig__EncryptionKey \
             RESGRID__SecurityConfig__EncryptionSaltValue RESGRID__WorkerConfig__PayloadKey; do
    if is_placeholder "$(get_env "$key")"; then
      warn "$key still has the public template value. Change it (and everything that depends on it) by hand, or reinstall."
    fi
  done
  chmod 600 "$ENV_FILE"

  # Generated files a manual cleanup may have removed.
  make_ca
  if [ ! -f "$GEN/tls.crt" ] || [ ! -f "$GEN/tls.key" ]; then
    [ "$(get_env RESGRID_TLS)" = files ] && die "$GEN/tls.crt or tls.key is missing. Put your certificate back (or set RESGRID_TLS=internal in $ENV_FILE to use the local CA)."
    issue_ingress_cert
  fi
  [ -f "$GEN/hosts.env" ] || write_hosts_env "${RESGRID_INGRESS_CLASS:-traefik}"
  [ -f "$GEN/host-aliases.yaml" ] || write_host_aliases
  date >> .setup-complete
}

# ------------------------------------------------------------ cluster ---

# The first apply to a kubectl context asks for confirmation (RESGRID_APPLY=1
# skips it); later runs against the same context don't.
confirm_context() {
  local context answer
  context="$(kc config current-context 2>/dev/null || true)"
  [ -n "$context" ] || die "kubectl has no current context."
  if [ "$(cat "$GEN/kube-context" 2>/dev/null || true)" != "$context" ] && [ "${RESGRID_APPLY:-0}" != 1 ]; then
    answer="$(prompt "Apply Resgrid to Kubernetes context '$context'? Type yes" 'no')"
    [ "$answer" = yes ] || die "Not applied. Re-run with RESGRID_APPLY=1 after checking the context."
  fi
  printf '%s\n' "$context" > "$GEN/kube-context"
  CONTEXT="$context"
}

# Optional services (deploy/optional/<name>.yaml) listed in RESGRID_OPTIONAL
# are applied on every run; the ones setup applied earlier and that are no
# longer listed are removed. Ones you applied by hand are left alone.
apply_optional() {
  local wanted applied name kept="" removed=""
  wanted="$(get_env RESGRID_OPTIONAL)"
  applied="$(cat "$GEN/optional-applied" 2>/dev/null || true)"
  for name in $(printf '%s' "$applied" | tr ',' ' ') ${FEAT_PROFILES_OFF:-}; do
    in_list "$name" "$wanted" || in_list "$name" "$removed" && continue
    [ -f "deploy/optional/$name.yaml" ] || continue
    removed="$removed,$name"
    info "Removing the optional service '$name'"
    kc delete -f "deploy/optional/$name.yaml" --ignore-not-found >/dev/null
  done
  for name in $(printf '%s' "$wanted" | tr ',' ' '); do
    if [ -f "deploy/optional/$name.yaml" ]; then
      kc apply -f "deploy/optional/$name.yaml"
      kept="${kept:+$kept,}$name"
    else
      warn "RESGRID_OPTIONAL lists '$name', but deploy/optional/$name.yaml doesn't exist."
    fi
  done
  printf '%s\n' "$kept" > "$GEN/optional-applied"
}

apply_stack() {
  info "Validating manifests"
  kc kustomize deploy >/dev/null
  if [ "${RESGRID_NO_APPLY:-0}" = 1 ]; then
    info "RESGRID_NO_APPLY=1: files generated in $GEN, cluster not changed."
    exit 0
  fi
  confirm_context
  if grep -q '^  - path: base/patches/amd64-only.yaml' deploy/kustomization.yaml &&
     ! kc get nodes -l kubernetes.io/arch=amd64 -o name | grep -q .; then
    die "No amd64 node found. The published Resgrid images are amd64-only; add an amd64 node (see README.md)."
  fi
  info "Applying to context $CONTEXT"
  # A Job's pod template can't be changed in place; the bucket job is
  # idempotent, so delete it and let it run again (new buckets, new versions).
  kc -n resgrid delete job rustfs-init --ignore-not-found >/dev/null 2>&1 || true
  kc apply -k deploy
  apply_optional
  heal_statefulsets
}

# A StatefulSet never replaces a pod that isn't ready (Kubernetes issue
# 67250), so a fix in a new definition wouldn't reach a crashing pod.
# Delete such pods; they start again from the current definition.
heal_statefulsets() {
  local sts gen observed rev pod_rev ready
  for sts in db redis rabbitmq rustfs; do
    for _ in $(seq 1 15); do
      gen="$(kc -n resgrid get statefulset "$sts" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)"
      observed="$(kc -n resgrid get statefulset "$sts" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)"
      [ "$gen" = "$observed" ] && break
      sleep 2
    done
    rev="$(kc -n resgrid get statefulset "$sts" -o jsonpath='{.status.updateRevision}' 2>/dev/null || true)"
    pod_rev="$(kc -n resgrid get pod "$sts-0" -o jsonpath='{.metadata.labels.controller-revision-hash}' 2>/dev/null || true)"
    ready="$(kc -n resgrid get pod "$sts-0" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
    if [ -n "$rev" ] && [ -n "$pod_rev" ] && [ "$pod_rev" != "$rev" ] && [ "$ready" != true ]; then
      info "Restarting $sts-0 with its updated definition"
      kc -n resgrid delete pod "$sts-0" --wait=false >/dev/null
    fi
  done
}

# Pods read resgrid.env at start; restart them to pick up changes and pull
# the newest images (imagePullPolicy: Always).
restart_apps() {
  info "Restarting the Resgrid deployments"
  kc -n resgrid rollout restart deployment -l 'app!=clamav'
}

wait_for_rollout() {
  info "Waiting for the database migration and the web app (first install: 5-15 minutes)"
  kc -n resgrid rollout status statefulset/db --timeout=10m
  kc -n resgrid rollout status deployment/worker --timeout=15m
  kc -n resgrid rollout status deployment/api --timeout=15m
  kc -n resgrid rollout status deployment/web --timeout=15m
  kc -n resgrid rollout status deployment/events --timeout=10m
}

# The worker creates/migrates the schema (and seeds the feature flags) after
# every start of a new image; wait for it before touching feature flags.
wait_for_migrations() {
  info "Waiting for the database migration to finish..."
  local logs
  for _ in $(seq 1 180); do
    logs="$(kc -n resgrid logs deployment/worker -c worker --tail=-1 2>/dev/null || true)"
    case "$logs" in *"Completed updating the core Resgrid databases"*) return 0 ;; esac
    sleep 5
  done
  warn "The worker hasn't reported a finished migration after 15 minutes (kubectl -n resgrid logs deployment/worker)."
  return 1
}

# Apply feature changes: new settings reach the pods through the secret and a
# restart; optional services switched on/off are applied/removed.
apply_feature_changes() {
  if [ "$FEAT_ENV_CHANGED" = 1 ]; then
    info "Applying the changed settings..."
    apply_stack
    restart_apps
    wait_for_rollout
  fi
  # Pods cache flags in Redis; clear it again after any restart.
  [ "$FEAT_FLAGS_CHANGED" = 1 ] && feat_clear_cache
  return 0
}

# ============================================================== main ===

need_cmd openssl "Install OpenSSL with your operating system package manager."
[ -f .env.example ] || die "Run this script from a checkout of the multi branch."
mkdir -p "$GEN"

case "$COMMAND" in
  install|features) ;;
  upgrade)
    if [ "${RESGRID_UPDATED:-0}" != 1 ]; then
      before="$(cksum < setup.sh)"
      update_checkout
      if [ "$(cksum < setup.sh)" != "$before" ]; then
        info "setup.sh changed; running the new version."
        RESGRID_UPDATED=1 exec bash ./setup.sh "$COMMAND" "$SUBARG"
      fi
    fi ;;
  renew-cert)
    [ -f "$ENV_FILE" ] && [ -f "$GEN/ca.key" ] || die "No local CA in $GEN (certificate files supplied by you are renewed by replacing $GEN/tls.crt/tls.key)."
    issue_ingress_cert
    apply_stack
    exit 0 ;;
  -h|--help|help) sed -n '2,33p' "$0"; exit 0 ;;
  *) die "Unknown command '$COMMAND'. Use: setup.sh [install|upgrade|features|renew-cert]" ;;
esac

FEAT_CATALOG="$ROOT/features/catalog.ini"
# shellcheck source=lib/features.sh
. "$ROOT/lib/features.sh"

if [ "$COMMAND" = features ]; then
  [ -f "$ENV_FILE" ] || die "Resgrid isn't configured here yet. Run ./setup.sh first."
  features_run "$SUBARG"
  apply_feature_changes
  info "Done. Optional features on: $(get_env RESGRID_FEATURES | sed 's/,/, /g')"
  exit 0
fi

FIRST_RUN=0
if [ -f "$ENV_FILE" ]; then
  info "Existing install found in $GEN: upgrading and repairing it (your settings and secrets are kept)."
  reconcile_env
else
  FIRST_RUN=1
  configure_new
fi

apply_stack
[ "$FIRST_RUN" = 1 ] || restart_apps
wait_for_rollout
if wait_for_migrations; then
  features_run --new
  apply_feature_changes
fi

WEB_HOST="$(get_env RESGRID_WEB_HOST)"; API_HOST="$(get_env RESGRID_API_HOST)"; EVENTS_HOST="$(get_env RESGRID_EVENTS_HOST)"
cat <<EOF

Resgrid is running in namespace 'resgrid':
  https://$WEB_HOST
EOF
[ "$FIRST_RUN" = 1 ] && printf '    (choose "Sign Up" to create the first account and department)\n'
cat <<EOF
  https://$API_HOST/health
  https://$EVENTS_HOST
  Optional features on: $(get_env RESGRID_FEATURES | sed 's/,/, /g')

  kubectl -n resgrid get pods
  kubectl -n resgrid logs -f deployment/worker
  ./setup.sh features         # turn optional features on or off
  git pull && ./setup.sh      # upgrade (re-running is always safe)

EOF
if [ "$FIRST_RUN" = 1 ] && [ "$(get_env RESGRID_TLS)" != files ]; then
  cat <<EOF
The ingress certificate comes from the Resgrid local CA. Install
$GEN/ca.crt as a trusted root on every client (browsers, iPhones).
Android Resgrid apps need a publicly trusted certificate instead.
Keep $GEN/ca.key and resgrid.env secret and backed up.
EOF
fi
