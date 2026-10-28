#!/usr/bin/env bash
#
# Resgrid self-hosted installer (single server, Docker Compose)
#
# One line install, and the same line upgrades an existing install:
#   curl -fsSL https://raw.githubusercontent.com/Resgrid/resgrid-setup/master/setup.sh | bash
#
# Commands (run from the install directory, ~/resgrid by default):
#   ./setup.sh                 first run: configure and start Resgrid.
#                              Every later run upgrades and repairs the install:
#                              keeps your settings, secrets and data, adds new
#                              settings and services, pulls new images, restarts,
#                              then offers the optional features.
#   ./setup.sh upgrade         git pull, then the same as above
#   ./setup.sh features        turn optional features (features/catalog.ini) on/off
#   ./setup.sh features --all  also list feature flags the catalog doesn't cover
#
# Every question can be answered with a variable (unattended install):
#   RESGRID_WEB_HOST=dispatch.example.com \
#   RESGRID_API_HOST=dispatchapi.example.com \
#   RESGRID_EVENTS_HOST=dispatchevents.example.com \
#   RESGRID_TLS=admin@example.com \
#   RESGRID_FEATURES=records,search \
#   bash setup.sh
#
# Other variables:
#   RESGRID_INSTALL_DIR   where to download the stack (default ~/resgrid)
#   RESGRID_BRANCH        repository branch to download (default master)
#   RESGRID_TLS_CERT_FILE / RESGRID_TLS_KEY_FILE
#                         PEM certificate + key to use instead of Let's Encrypt
#                         or the local CA (copied to certs/site/)
#   RESGRID_FEATURES      optional features to have on (comma separated section
#                         names from features/catalog.ini, "all" or "none");
#                         sections not listed are switched off
#   RESGRID_NONINTERACTIVE=1  never ask; keep features as they are
#   RESGRID_NO_PULL=1     don't pull images (offline re-run)
#   RESGRID_NO_START=1    configure only, don't pull or start containers
#   RESGRID_MIGRATE_LEGACY_DB=1|0  copy the data of a previous version into
#                         this install without asking / never (default: ask,
#                         and copy when there is no terminal: the database of
#                         this version is empty then, so nothing is overwritten)

set -euo pipefail

REPO_URL="${RESGRID_REPO_URL:-https://github.com/Resgrid/resgrid-setup}"
BRANCH="${RESGRID_BRANCH:-master}"
INSTALL_DIR="${RESGRID_INSTALL_DIR:-$HOME/resgrid}"
COMMAND="${1:-install}"
SUBARG="${2:-}"

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

interactive() { [ "${RESGRID_NONINTERACTIVE:-0}" != 1 ] && { : </dev/tty >/dev/tty; } 2>/dev/null; }

# Ask a question on the controlling terminal (works when piped through bash).
prompt() { # prompt <question> <default>
  local q="$1" def="$2" ans=""
  if interactive; then
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

has_env() { grep -q "^$1=" .env; }
get_env() { grep "^$1=" .env 2>/dev/null | head -n 1 | cut -d= -f2- || true; }

sed_escape() { local v="$1"; v="${v//\\/\\\\}"; v="${v//&/\\&}"; v="${v//|/\\|}"; printf '%s' "$v"; }

# Replace the value of KEY=... in .env (the key must exist).
set_env() { # set_env <key> <value>
  has_env "$1" || die "Key '$1' not found in .env."
  sed -i.sedbak "s|^$1=.*|$1=$(sed_escape "$2")|" .env
  rm -f .env.sedbak
}

# Replace KEY=... or append it.
upsert_env() { # upsert_env <key> <value>
  if has_env "$1"; then set_env "$1" "$2"; else printf '%s=%s\n' "$1" "$2" >> .env; fi
}

# Replace a literal string everywhere in .env.
replace_in_env() { # replace_in_env <from> <to>
  local from="$1" to="$2"
  from="$(printf '%s' "$from" | sed 's/[.[\*^$|]/\\&/g')"
  sed -i.sedbak "s|${from}|${to}|g" .env
  rm -f .env.sedbak
}

strip_scheme() { printf '%s' "$1" | sed -e 's|^https://||' -e 's|^http://||' -e 's|/.*$||'; }

pg_conn() { # pg_conn <database>
  printf 'User ID=%s;Password=%s;Host=db;Port=5432;Database=%s;Pooling=true;Connection Lifetime=0;Include Error Detail=true;' \
    "$(get_env POSTGRES_USER)" "$(get_env POSTGRES_PASSWORD)" "$1"
}

# Value of <key>= in a connection string (; or , separated, key case-insensitive).
conn_value() { # conn_value <connection string> <key>
  # shellcheck disable=SC2020  # two separators, each becomes a newline
  printf '%s\n' "$1" | tr ';,' '\n\n' |
    awk -v k="$2" '{ n = index($0, "="); if (n && tolower(substr($0, 1, n - 1)) == tolower(k)) { print substr($0, n + 1); exit } }'
}

is_placeholder() { case "$1" in *[Cc][Hh][Aa][Nn][Gg][Ee][Mm][Ee]*|"") return 0 ;; *) return 1 ;; esac; }

# OpenIddict signing and encryption certificates: PKCS#12 with an empty
# password, base64 encoded (Core loads them without a password).
oidc_cert() { # oidc_cert <name> <key usage>
  local tmp; tmp="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$tmp/c.key" -out "$tmp/c.crt" \
    -subj "/CN=Resgrid OIDC Server $1 Certificate" \
    -addext "keyUsage=$2" >/dev/null 2>&1
  openssl pkcs12 -export -out "$tmp/c.pfx" -inkey "$tmp/c.key" -in "$tmp/c.crt" -passout pass: >/dev/null 2>&1
  openssl base64 -A -in "$tmp/c.pfx"
  rm -rf "$tmp"
}

# Resgrid's local certificate authority. Caddy issues the site certificates
# from it when RESGRID_TLS=internal; the containers trust it (SSL_CERT_DIR);
# clients install certs/ca/resgrid-root-ca.crt to trust the site.
make_ca() { # make_ca <common name suffix>
  mkdir -p certs/ca certs/private certs/site
  if [ -f certs/ca/resgrid-root-ca.crt ] && [ -f certs/private/resgrid-root-ca.key ]; then
    return
  fi
  info "Creating the Resgrid local certificate authority (10 year validity)..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -days 3650 -nodes \
    -keyout certs/private/resgrid-root-ca.key -out certs/ca/resgrid-root-ca.crt \
    -subj "/O=Resgrid self-hosted/CN=Resgrid Local CA $1" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1 || die "Creating the local CA failed."
  chmod 600 certs/private/resgrid-root-ca.key
  chmod 644 certs/ca/resgrid-root-ca.crt
}

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
  else
    die "Docker Compose was not found. Install the compose plugin: https://docs.docker.com/compose/install/"
  fi
}

# Wait until the API and web app answer through Caddy.
wait_for_stack() {
  command -v curl >/dev/null 2>&1 || return 0
  local api_host web_host port
  api_host="$(get_env RESGRID_API_HOST)"
  web_host="$(get_env RESGRID_WEB_HOST)"
  port="$(get_env RESGRID_HTTPS_PORT)"
  port="${port:-443}"
  info "Waiting for Resgrid to answer (a first start creates the database: 5-10 minutes)..."
  for _ in $(seq 1 120); do
    if curl -ksf -o /dev/null --max-time 5 --resolve "$api_host:$port:127.0.0.1" "https://$api_host:$port/health" &&
       curl -ksf -o /dev/null --max-time 10 --resolve "$web_host:$port:127.0.0.1" "https://$web_host:$port/Health/GetCurrent"; then
      ok "Resgrid is up."
      return 0
    fi
    printf '.'
    sleep 5
  done
  printf '\n'
  warn "Resgrid did not answer within 10 minutes. Check: $COMPOSE logs -f worker api web"
  return 1
}

# The worker creates/migrates the schema (and seeds the feature flags) after
# every start of a new image; wait for it before touching feature flags.
wait_for_migrations() {
  info "Waiting for the database migration to finish..."
  local logs
  for _ in $(seq 1 180); do
    logs="$($COMPOSE logs --no-color worker 2>/dev/null || true)"
    case "$logs" in *"Completed updating the core Resgrid databases"*) return 0 ;; esac
    sleep 5
  done
  warn "The worker hasn't reported a finished migration after 15 minutes ($COMPOSE logs worker)."
  return 1
}

print_ca_help() {
  cat <<EOF

  CERTIFICATES: this install uses Resgrid's local certificate authority.
  Browsers and phones will show a certificate warning until you install the
  CA certificate on them (one file, valid for all three hostnames):

      $INSTALL_DIR/certs/ca/resgrid-root-ca.crt

    Windows:  double-click it > Install Certificate > Local Machine >
              "Trusted Root Certification Authorities"
    macOS:    double-click it, then in Keychain Access set it to "Always Trust"
    iPhone:   AirDrop/email it, install the profile, then enable it under
              Settings > General > About > Certificate Trust Settings
    Android:  Settings > Security > Encryption & credentials > Install a
              certificate > CA certificate (browsers only: the Resgrid
              Responder and Unit apps need a publicly trusted certificate)
    Linux:    copy to /usr/local/share/ca-certificates/ and run
              sudo update-ca-certificates

  Never share certs/private/resgrid-root-ca.key.
EOF
}

banner() {
  printf '\n'
  printf '%s\n' '  ____                      _     _ '
  printf '%s\n' ' |  _ \ ___  ___  __ _ _ __(_) __| |'
  printf '%s\n' ' | |_) / _ \/ __|/ _` | '\''__| |/ _` |'
  printf '%s\n' ' |  _ <  __/\__ \ (_| | |  | | (_| |'
  printf '%s\n' ' |_| \_\___||___/\__, |_|  |_|\__,_|'
  printf '%s\n' '                 |___/  self-hosted installer'
  printf '\n'
}

# ------------------------------------------------- feature engine hooks ---

feat_psql() {
  $COMPOSE exec -T db psql -v ON_ERROR_STOP=1 -At -U "$(get_env POSTGRES_USER)" -d resgrid -c "$1"
}
feat_redis() {
  $COMPOSE exec -T redis redis-cli --no-auth-warning -a "$(get_env REDIS_PASSWORD)" "$@"
}

# ------------------------------------------------- repository download ---

# Bring an existing checkout up to date without losing local files. Installs
# from before October 2026 tracked .env in git: keep it aside while pulling.
update_checkout() {
  if [ -d .git ] && command -v git >/dev/null 2>&1; then
    local saved=""
    if git ls-files --error-unmatch .env >/dev/null 2>&1; then
      saved="$(mktemp)"; cp .env "$saved"
      git checkout -- .env 2>/dev/null || true
    fi
    info "Updating the setup files (git pull)..."
    if ! git pull --ff-only; then
      warn "git pull failed (local changes to tracked files?). Continuing with the files you have."
    fi
    if [ -n "$saved" ]; then cp "$saved" .env; rm -f "$saved"; chmod 600 .env; fi
  elif command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
    info "Updating the setup files (download)..."
    # The archive has no .env, certs or data, so nothing of yours is overwritten.
    curl -fsSL "$REPO_URL/archive/refs/heads/$BRANCH.tar.gz" | tar -xz --strip-components=1 -C . ||
      warn "Download failed. Continuing with the files you have."
  fi
}

# --------------------------------------------- configuration: new install ---

configure_new() {
  printf '\n'
  info "Configuration (press Enter to accept the defaults)."
  printf '%s\n' "    Resgrid needs three hostnames that resolve to this server. For a LAN-only" \
                "    install the *.mylocal defaults work with hosts-file entries; for an internet" \
                "    install use real DNS names and give an email address for Let's Encrypt."
  printf '\n'

  local web api events tls http_port https_port suffix
  web="$(strip_scheme "${RESGRID_WEB_HOST:-${RESGRID_WEB_URL:-$(prompt 'Web app hostname' 'rg.mylocal')}}")"
  api="$(strip_scheme "${RESGRID_API_HOST:-${RESGRID_API_URL:-$(prompt 'API hostname' 'rgapi.mylocal')}}")"
  events="$(strip_scheme "${RESGRID_EVENTS_HOST:-${RESGRID_EVENTS_URL:-$(prompt 'Events hostname' 'rgevents.mylocal')}}")"
  http_port="${RESGRID_HTTP_PORT:-80}"
  https_port="${RESGRID_HTTPS_PORT:-443}"
  suffix=""; [ "$https_port" = "443" ] || suffix=":$https_port"

  mkdir -p certs/ca certs/private certs/site
  if [ -n "${RESGRID_TLS_CERT_FILE:-}" ] || [ -n "${RESGRID_TLS_KEY_FILE:-}" ]; then
    [ -f "${RESGRID_TLS_CERT_FILE:-}" ] && [ -f "${RESGRID_TLS_KEY_FILE:-}" ] || die "Set RESGRID_TLS_CERT_FILE and RESGRID_TLS_KEY_FILE to readable PEM files."
    cp "$RESGRID_TLS_CERT_FILE" certs/site/fullchain.pem
    cp "$RESGRID_TLS_KEY_FILE" certs/site/privkey.pem
    chmod 644 certs/site/fullchain.pem certs/site/privkey.pem
    tls="/certs/site/fullchain.pem /certs/site/privkey.pem"
  else
    tls="${RESGRID_TLS:-${RESGRID_LETSENCRYPT_EMAIL:-$(prompt "Let's Encrypt email ('internal' = local CA, for LAN/offline)" 'internal')}}"
  fi

  printf '\n'
  info "Using:"
  printf '    Web:    https://%s%s\n    API:    https://%s%s\n    Events: https://%s%s\n    TLS:    %s\n\n' \
    "$web" "$suffix" "$api" "$suffix" "$events" "$suffix" "$tls"
  if [ -n "$suffix" ] && [ "$tls" != "internal" ] && [ "${tls#/}" = "$tls" ]; then
    die "Let's Encrypt needs HTTPS on port 443. Use RESGRID_TLS=internal or your own certificate files with port $https_port."
  fi

  info "Generating passwords, keys and certificates..."
  cp .env.example .env
  chmod 600 .env

  local rustfs_access rustfs_secret system_api_key section
  rustfs_access="$(rand_upper 20)"
  rustfs_secret="$(rand_upper 40)"
  system_api_key="$(rand_alnum 48)"

  set_env RESGRID_WEB_HOST    "$web"
  set_env RESGRID_API_HOST    "$api"
  set_env RESGRID_EVENTS_HOST "$events"
  set_env RESGRID_TLS         "$tls"
  set_env RESGRID_HTTP_PORT   "$http_port"
  set_env RESGRID_HTTPS_PORT  "$https_port"

  set_env POSTGRES_USER     resgrid
  set_env POSTGRES_PASSWORD "$(rand_alnum 32)"
  set_env REDIS_PASSWORD    "$(rand_alnum 32)"
  set_env RABBITMQ_USER     resgrid
  set_env RABBITMQ_PASSWORD "$(rand_alnum 32)"
  set_env RUSTFS_ACCESS_KEY "$rustfs_access"
  set_env RUSTFS_SECRET_KEY "$rustfs_secret"

  set_env RESGRID__SystemBehaviorConfig__ResgridBaseUrl         "https://$web$suffix"
  set_env RESGRID__SystemBehaviorConfig__ResgridApiBaseUrl      "https://$api$suffix"
  set_env RESGRID__SystemBehaviorConfig__ResgridEventingBaseUrl "https://$events$suffix"
  set_env RESGRID__SystemBehaviorConfig__ExternalLinkUrlParamPassphrase  "$(rand_alnum 24)"
  set_env RESGRID__SystemBehaviorConfig__ExternalAudioUrlParamPasshprase "$(rand_alnum 24)"
  set_env RESGRID__SystemBehaviorConfig__ApiTokenEncryptionPassphrase    "$(rand_alnum 24)"
  set_env RESGRID__SystemBehaviorConfig__FullHealthCheckKey              "$(rand_alnum 32)"

  set_env RESGRID__SecurityConfig__EncryptionKey          "$(rand_alnum 32)"   # exactly 32 characters
  set_env RESGRID__SecurityConfig__EncryptionSaltValue    "$(rand_alnum 24)"
  set_env RESGRID__SecurityConfig__SystemApiKey           "$system_api_key"
  set_env RESGRID__SecurityConfig__DepartmentApiKeyPepper "$(rand_alnum 48)"
  set_env RESGRID__ApiConfig__BackendInternalApikey       "$(rand_alnum 48)"

  set_env RESGRID__CacheConfig__RedisConnectionString "redis:6379,password=$(get_env REDIS_PASSWORD),allowAdmin=True"
  set_env RESGRID__DataConfig__ConnectionString           "$(pg_conn resgrid)"
  set_env RESGRID__DataConfig__CoreConnectionString       "$(pg_conn resgrid)"
  set_env RESGRID__DataConfig__DocumentConnectionString   "$(pg_conn resgriddoc)"
  set_env RESGRID__OidcConfig__ConnectionString           "$(pg_conn resgridoidc)"
  set_env RESGRID__WorkerConfig__WorkerDbConnectionString "$(pg_conn resgridworkers)"

  set_env RESGRID__JwtConfig__EventsClientSecret     "$(rand_alnum 48)"
  set_env RESGRID__ServiceBusConfig__RabbitUsername  resgrid
  set_env RESGRID__ServiceBusConfig__RabbbitPassword "$(get_env RABBITMQ_PASSWORD)"
  set_env RESGRID__WorkerConfig__PayloadKey          "$(rand_alnum 96)"

  set_env RESGRID__TtsConfig__PlaybackBaseUrl      "https://$api$suffix"
  set_env RESGRID__TtsConfig__StaticPromptAdminKey "$(rand_alnum 32)"
  for section in TtsConfig ImportConfig; do
    set_env "RESGRID__${section}__S3AccessKey" "$rustfs_access"
    set_env "RESGRID__${section}__S3SecretKey" "$rustfs_secret"
  done

  set_env RESGRID__UnitTrackingConfig__CredentialPepper "$(rand_alnum 48)"
  set_env RESGRID__RELAY__Resgrid__SystemApiKey "$system_api_key"
  set_env RESGRID__RELAY__Resgrid__ClientSecret "$(rand_alnum 32)"
  set_env RESGRID__RELAY__Smtp__DepartmentAddressDomains__0 "dispatch.$web"

  set_env RESGRID__OidcConfig__EncryptionCert "$(oidc_cert Encryption keyEncipherment)"
  set_env RESGRID__OidcConfig__SigningCert    "$(oidc_cert Signing digitalSignature)"
  [ -n "$(get_env RESGRID__OidcConfig__EncryptionCert)" ] && [ -n "$(get_env RESGRID__OidcConfig__SigningCert)" ] || die "OIDC certificate generation failed."

  date > .setup-complete
  ok "Configuration written to $INSTALL_DIR/.env (it holds all your secrets: back it up and keep it private)."
}

# ------------------------------------------ configuration: existing install ---

# Bring an existing .env up to date. Never replaces a value you set, never
# rotates a secret your data depends on; only renames old settings, fills in
# settings that are missing or empty, and fixes values known to break.
reconcile_env() {
  local backup line key value added=0
  backup=".env.backup-$(date +%Y%m%d-%H%M%S)"
  cp .env "$backup"; chmod 600 "$backup"
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
    } >> .env
  fi

  # Containers reach each other by service name, listen on 8080 and trust the
  # local CA instead of bypassing certificate checks.
  replace_in_env "Host=172.16.193.55;" "Host=db;"
  replace_in_env "172.16.193.56:6379" "redis:6379"
  replace_in_env "RabbitHostname=172.16.193.57" "RabbitHostname=rabbitmq"
  replace_in_env "http://172.16.193.58:8080" "http://tts:8080"
  replace_in_env "http://172.16.193.61:9000" "http://rustfs:9000"
  replace_in_env "RESGRID__RELAY__Resgrid__BaseUrl=http://172.16.193.52" "RESGRID__RELAY__Resgrid__BaseUrl=http://api:8080"
  if has_env ASPNETCORE_URLS && [ "$(get_env ASPNETCORE_URLS)" != "http://+:8080" ]; then set_env ASPNETCORE_URLS "http://+:8080"; fi
  if [ "$(get_env RESGRID__ApiConfig__BypassSslChecks)" = "true" ]; then set_env RESGRID__ApiConfig__BypassSslChecks false; fi

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
      RESGRID_HTTP_PORT) value="${RESGRID_HTTP_PORT:-${line#*=}}" ;;
      RESGRID_HTTPS_PORT) value="${RESGRID_HTTPS_PORT:-${line#*=}}" ;;
      # Installs before October 2026 set these in docker-compose.yml; the
      # Resgrid connection settings in .env hold the values in use.
      POSTGRES_PASSWORD) value="$(conn_value "$(get_env RESGRID__DataConfig__ConnectionString)" Password)"; [ -n "$value" ] || value="${line#*=}" ;;
      REDIS_PASSWORD) value="$(conn_value "$(get_env RESGRID__CacheConfig__RedisConnectionString)" password)"; [ -n "$value" ] || value="${line#*=}" ;;
      RABBITMQ_USER) value="$(get_env RESGRID__ServiceBusConfig__RabbitUsername)"; [ -n "$value" ] || value="${line#*=}" ;;
      RABBITMQ_PASSWORD) value="$(get_env RESGRID__ServiceBusConfig__RabbbitPassword)"; [ -n "$value" ] || value="${line#*=}" ;;
      RESGRID__*Config__S3AccessKey) [ "${key#*Search}" = "$key" ] && value="$(get_env RUSTFS_ACCESS_KEY)" || value="" ;;
      RESGRID__*Config__S3SecretKey) [ "${key#*Search}" = "$key" ] && value="$(get_env RUSTFS_SECRET_KEY)" || value="" ;;
      *) value="${line#*=}" ;;
    esac
    [ "$added" -eq 0 ] && printf '\n# Added by setup.sh on %s\n' "$(date +%F)" >> .env
    printf '%s=%s\n' "$key" "$value" >> .env
    info "Added $key"
    added=$((added + 1))
  done < .env.example

  # Required values that are empty can be generated safely.
  [ -n "$(get_env RESGRID__ApiConfig__BackendInternalApikey)" ] || set_env RESGRID__ApiConfig__BackendInternalApikey "$(rand_alnum 48)"
  if [ -z "$(get_env RESGRID__SecurityConfig__SystemApiKey)" ]; then
    set_env RESGRID__SecurityConfig__SystemApiKey "$(rand_alnum 48)"
  fi
  [ -n "$(get_env RESGRID__RELAY__Resgrid__SystemApiKey)" ] || set_env RESGRID__RELAY__Resgrid__SystemApiKey "$(get_env RESGRID__SecurityConfig__SystemApiKey)"
  # Events tokens are short-lived, so a placeholder secret can be replaced.
  if is_placeholder "$(get_env RESGRID__JwtConfig__EventsClientSecret)" || [ "$(get_env RESGRID__JwtConfig__EventsClientSecret)" = "SecretKeyChangeMe1234!" ]; then
    set_env RESGRID__JwtConfig__EventsClientSecret "$(rand_alnum 48)"
  fi
  if [ -z "$(get_env RESGRID__OidcConfig__EncryptionCert)" ] || [ -z "$(get_env RESGRID__OidcConfig__SigningCert)" ]; then
    info "Creating the missing OpenID Connect certificates"
    set_env RESGRID__OidcConfig__EncryptionCert "$(oidc_cert Encryption keyEncipherment)"
    set_env RESGRID__OidcConfig__SigningCert    "$(oidc_cert Signing digitalSignature)"
  fi

  # Redis takes its password from REDIS_PASSWORD at every start: keep it equal
  # to the one Resgrid connects with. PostgreSQL and RabbitMQ store theirs when
  # their data is first created, so a difference there can only be reported.
  value="$(conn_value "$(get_env RESGRID__CacheConfig__RedisConnectionString)" password)"
  if [ -n "$value" ] && [ "$value" != "$(get_env REDIS_PASSWORD)" ]; then
    set_env REDIS_PASSWORD "$value"
    info "REDIS_PASSWORD now matches RESGRID__CacheConfig__RedisConnectionString"
  fi
  value="$(conn_value "$(get_env RESGRID__DataConfig__ConnectionString)" Password)"
  if [ -n "$value" ] && [ "$value" != "$(get_env POSTGRES_PASSWORD)" ]; then
    warn "POSTGRES_PASSWORD differs from the password in RESGRID__DataConfig__ConnectionString. Resgrid connects only with the password the database was created with."
  fi
  if [ "$(get_env RESGRID__ServiceBusConfig__RabbbitPassword)" != "$(get_env RABBITMQ_PASSWORD)" ]; then
    warn "RABBITMQ_PASSWORD differs from RESGRID__ServiceBusConfig__RabbbitPassword. Resgrid connects only with the password RabbitMQ was created with."
  fi

  # Placeholders that can't be changed without losing access to existing data.
  for key in POSTGRES_PASSWORD REDIS_PASSWORD RABBITMQ_PASSWORD RESGRID__SecurityConfig__EncryptionKey \
             RESGRID__SecurityConfig__EncryptionSaltValue RESGRID__WorkerConfig__PayloadKey; do
    if is_placeholder "$(get_env "$key")"; then
      warn "$key still has the public template value. Change it (and everything that depends on it) by hand, or reinstall."
    fi
  done
  chmod 600 .env
  date >> .setup-complete
}

# ------------------------------------------ database from an old install ---

# Earlier versions kept PostgreSQL data where this version doesn't look:
#  - docker-data/sql (official postgres image, before May 2026);
#  - inside the db container itself (May-October 2026: the hardened image
#    keeps its data in /var/lib/postgresql/18/data, which the docker-data/sql
#    mount missed). Recreating that container would delete the data, so
#    keep_legacy_containers saves it to backups/ before anything else runs.
LEGACY_PGDATA_PATHS="/var/lib/postgresql/18/data /var/lib/postgresql/18/docker /var/lib/postgresql/data"

# Containers that earlier versions started from this folder.
legacy_containers() { # legacy_containers [service]
  {
    # shellcheck disable=SC2086
    docker ps -aq --filter "label=com.docker.compose.project.working_dir=$INSTALL_DIR" ${1:+--filter label=com.docker.compose.service=$1}
    # shellcheck disable=SC2086
    docker ps -aq --filter "label=com.docker.compose.project=resgrid" ${1:+--filter label=com.docker.compose.service=$1}
  } 2>/dev/null | sort -u
}

keep_legacy_containers() {
  local cid mounts project p snap
  for cid in $(legacy_containers db); do
    mounts="$(docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "$cid" 2>/dev/null || true)"
    case "$mounts" in *postgres-data*) continue ;; esac   # this version's database
    snap="backups/legacy-pgdata-${cid:0:12}.tar"
    [ -s "$snap" ] && continue
    for p in $LEGACY_PGDATA_PATHS; do
      docker cp "$cid:$p/PG_VERSION" - >/dev/null 2>&1 || continue
      info "Saving the database of the previous version (container ${cid:0:12}) to $snap ..."
      docker update --restart=no "$cid" >/dev/null 2>&1 || true
      docker stop "$cid" >/dev/null 2>&1 || true
      mkdir -p backups
      if ! docker cp "$cid:$p" - > "$snap.part"; then
        rm -f "$snap.part"
        die "Saving the database from container ${cid:0:12} failed (disk full?). Nothing else was changed; the container is only stopped (docker start ${cid:0:12})."
      fi
      mv "$snap.part" "$snap"
      printf 'image=%s\npath=%s\n' "$(docker inspect -f '{{.Config.Image}}' "$cid")" "$p" > "${snap%.tar}.info"
      chmod 600 "$snap" "${snap%.tar}.info"
      docker rename "$cid" "resgrid-legacy-db-${cid:0:12}" >/dev/null 2>&1 || true
      break
    done
  done
  # Containers of an earlier project name hold the ports this version needs.
  for cid in $(docker ps -q --filter "label=com.docker.compose.project.working_dir=$INSTALL_DIR"); do
    project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$cid" 2>/dev/null || true)"
    [ "$project" = resgrid ] && continue
    docker update --restart=no "$cid" >/dev/null 2>&1 || true
    docker stop "$cid" >/dev/null 2>&1 &&
      info "Stopped container ${cid:0:12} of the previous version (project $project). It is kept; remove it once you no longer need it."
  done
  return 0
}

# PostgreSQL version of the data in docker-data/sql, if any. The folder
# belongs to the old database user (mode 700), so look through a container.
legacy_folder_version() {
  local image
  image="$($COMPOSE config --images 2>/dev/null | grep -m1 postgres || true)"
  [ -n "$image" ] || return 0
  # shellcheck disable=SC2016  # expanded inside the container
  docker run --rm --user 0 --entrypoint sh -v "$PWD/docker-data/sql:/src:ro" "$image" \
    -c '[ -f /src/PG_VERSION ] && tr -d "[:space:]" < /src/PG_VERSION' 2>/dev/null || true
}

# Copy the old database into this version's (empty) database, once.
migrate_legacy_db() {
  local snap image path ver tables olduser answer dump vol=resgrid-legacy-db
  [ -f .legacy-db-migrated ] && return 0
  snap="$(find backups -maxdepth 1 -name 'legacy-pgdata-*.tar' 2>/dev/null | head -n 1 || true)"
  if [ -n "$snap" ]; then
    image="$(sed -n 's/^image=//p' "${snap%.tar}.info")"
    path="$(sed -n 's/^path=//p' "${snap%.tar}.info")"
  elif [ -d docker-data/sql ] && ver="$(legacy_folder_version)" && [ -n "$ver" ]; then
    image="postgres:$ver-alpine"
    path=/var/lib/postgresql/data
  else
    return 0
  fi
  olduser="$(get_env POSTGRES_USER)"
  $COMPOSE up -d db >/dev/null
  for _ in $(seq 1 60); do $COMPOSE exec -T db pg_isready -q 2>/dev/null && break; sleep 2; done
  $COMPOSE up -d db-init >/dev/null 2>&1 || true
  tables="$($COMPOSE exec -T db psql -At -U "$olduser" -d resgrid -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo 0)"
  if [ "${tables:-0}" != 0 ]; then
    warn "Found the database of a previous version (${snap:-docker-data/sql}), but the current database already has data. Not copying it; it stays where it is."
    date > .legacy-db-migrated
    return 0
  fi
  # The current database is empty, so copying never overwrites anything.
  case "${RESGRID_MIGRATE_LEGACY_DB:-ask}" in
    0|no) warn "Not copying the database of the previous version (RESGRID_MIGRATE_LEGACY_DB=0)."; return 0 ;;
    ask)
      answer="$(prompt "Copy your data from the previous version (${snap:-docker-data/sql}) into this install? (y/n)" y)"
      case "$answer" in y|Y|yes|Yes) ;; *) return 0 ;; esac ;;
  esac
  mkdir -p backups
  dump="backups/legacy-db-$(date +%Y%m%d-%H%M%S).sql.gz"
  info "Copying the database of the previous version (the original is not changed)..."
  docker rm -f resgrid-legacy-db >/dev/null 2>&1 || true
  docker volume rm -f "$vol" >/dev/null 2>&1 || true
  # shellcheck disable=SC2016  # expanded inside the container
  if [ -n "$snap" ]; then
    docker run --rm -i --user 0 --entrypoint sh -v "$vol:/dst" "$image" \
      -c 'tar -x --strip-components=1 -C /dst && chown "$(stat -c %u:%g /dst/PG_VERSION)" /dst && chmod 700 /dst' < "$snap"
  else
    docker run --rm --user 0 --entrypoint sh -v "$PWD/docker-data/sql:/src:ro" -v "$vol:/dst" "$image" \
      -c 'cp -a /src/. /dst/ && chown "$(stat -c %u:%g /dst/PG_VERSION)" /dst && chmod 700 /dst'
  fi
  docker run -d --name resgrid-legacy-db -e POSTGRES_PASSWORD=unused -v "$vol:$path" "$image" >/dev/null
  for _ in $(seq 1 60); do docker exec resgrid-legacy-db pg_isready -q -U "$olduser" 2>/dev/null && break; sleep 2; done
  if ! docker exec resgrid-legacy-db pg_dumpall -U "$olduser" --clean --if-exists | gzip > "$dump"; then
    docker rm -f resgrid-legacy-db >/dev/null 2>&1
    die "Reading the database of the previous version failed (docker logs of resgrid-legacy-db above). The original is unchanged (${snap:-docker-data/sql})."
  fi
  docker rm -f resgrid-legacy-db >/dev/null
  docker volume rm "$vol" >/dev/null
  info "Loading it into the current database (a copy of the dump is in $dump)..."
  gunzip -c "$dump" | $COMPOSE exec -T db psql -q -U "$olduser" -d postgres >/dev/null 2>"$dump.log" || true
  date > .legacy-db-migrated
  ok "Data of the previous version copied. The worker upgrades its schema when Resgrid starts."
}

# ---------------------------------------------------------------- start ---

start_stack() { # start_stack <first run 0|1>
  if [ "${RESGRID_NO_PULL:-0}" != 1 ]; then
    info "Pulling container images (the first run downloads several GB)..."
    if [ "$1" = 1 ]; then
      $COMPOSE pull
    elif ! $COMPOSE pull --ignore-pull-failures; then
      warn "Some images could not be pulled (offline?). Using the images already on this computer."
    fi
  fi
  info "Starting Resgrid..."
  $COMPOSE up -d --remove-orphans
  # Caddy doesn't watch its bind-mounted Caddyfile; restart to pick up changes.
  [ "$1" = 1 ] || $COMPOSE restart caddy >/dev/null
}

# Apply feature changes: restart the containers whose settings changed, start
# the profiles switched on, remove the services of profiles switched off.
apply_feature_changes() {
  local p svc base
  if [ "$FEAT_ENV_CHANGED" = 1 ]; then
    info "Restarting the services whose settings changed..."
    base=" $($COMPOSE config --services 2>/dev/null | tr '\n' ' ') "
    for p in $FEAT_PROFILES_OFF; do
      for svc in $($COMPOSE --profile "$p" config --services 2>/dev/null); do
        case "$base" in *" $svc "*) ;; *) $COMPOSE --profile "$p" rm -sf "$svc" >/dev/null 2>&1 || true ;; esac
      done
    done
    $COMPOSE up -d --remove-orphans
    wait_for_stack || true
  fi
  # Containers cache flags in Redis; clear it again after any restart.
  [ "$FEAT_FLAGS_CHANGED" = 1 ] && feat_clear_cache
  return 0
}

# ============================================================== main ===

banner

case "$COMMAND" in
  install|upgrade|features) ;;
  -h|--help|help) sed -n '2,40p' "$0" 2>/dev/null || true; exit 0 ;;
  *) die "Unknown command '$COMMAND'. Use: setup.sh [install|upgrade|features]" ;;
esac

case "$(uname -s)" in
  Linux|Darwin) ;;
  MINGW*|MSYS*|CYGWIN*)
    die "Run this installer inside WSL2 (Windows Subsystem for Linux), not Git Bash. For a Windows laptop install use the 'laptop' branch and setup.ps1." ;;
  *) warn "Untested operating system '$(uname -s)', continuing anyway." ;;
esac

info "Checking prerequisites..."
need_cmd docker  "Install Docker first: https://docs.docker.com/engine/install/"
need_cmd openssl "Install openssl with your package manager."
docker info >/dev/null 2>&1 || die "The Docker daemon is not running (or you lack permission to use it). Start Docker and re-run."
detect_compose

# Find (or download) the install directory. Run from a checkout: use it.
# Piped through bash: download, or update an existing install, then run the
# setup.sh that came with it so script and files always match.
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
[ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ] && SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/docker-compose.yml" ] && [ -f "$SCRIPT_DIR/.env.example" ]; then
  INSTALL_DIR="$SCRIPT_DIR"
  cd "$INSTALL_DIR"
  if [ "$COMMAND" = upgrade ] && [ "${RESGRID_UPDATED:-0}" != 1 ]; then
    before="$(cksum < setup.sh)"
    update_checkout
    if [ "$(cksum < setup.sh)" != "$before" ]; then
      info "setup.sh changed; running the new version."
      RESGRID_UPDATED=1 exec bash ./setup.sh "$COMMAND" "$SUBARG"
    fi
  fi
else
  if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    info "Updating the existing install in $INSTALL_DIR"
    cd "$INSTALL_DIR"
    update_checkout
  else
    info "Downloading Resgrid setup into $INSTALL_DIR ..."
    if [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
      die "$INSTALL_DIR exists and is not a Resgrid setup directory. Set RESGRID_INSTALL_DIR to another path."
    fi
    if command -v git >/dev/null 2>&1; then
      git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    else
      need_cmd curl "Install git or curl."
      need_cmd tar  "Install tar."
      mkdir -p "$INSTALL_DIR"
      curl -fsSL "$REPO_URL/archive/refs/heads/$BRANCH.tar.gz" | tar -xz --strip-components=1 -C "$INSTALL_DIR"
    fi
    cd "$INSTALL_DIR"
  fi
  [ -f setup.sh ] || die "$INSTALL_DIR has no setup.sh. Check RESGRID_BRANCH."
  RESGRID_UPDATED=1 exec bash ./setup.sh "$COMMAND" "$SUBARG" </dev/null
fi

[ -f .env.example ] || die "$INSTALL_DIR has no .env.example. Update the checkout with git pull."
FEAT_CATALOG="$INSTALL_DIR/features/catalog.ini"
# shellcheck source=lib/features.sh
. "$INSTALL_DIR/lib/features.sh"

if [ "$COMMAND" = features ]; then
  [ -f .env ] || die "Resgrid isn't configured here yet. Run ./setup.sh first."
  keep_legacy_containers
  features_run "$SUBARG"
  apply_feature_changes
  ok "Done."
  exit 0
fi

FIRST_RUN=0
if [ -f .env ]; then
  ok "Existing install found in $INSTALL_DIR: upgrading and repairing it (your settings and data are kept)."
  reconcile_env
else
  FIRST_RUN=1
  configure_new
fi
make_ca "$(get_env RESGRID_WEB_HOST)"
chmod 600 .env

if [ "${RESGRID_NO_START:-0}" = "1" ]; then
  warn "RESGRID_NO_START=1 set, not starting containers."
  printf 'Start later with:  cd %s && %s up -d\n' "$INSTALL_DIR" "$COMPOSE"
  exit 0
fi

keep_legacy_containers
migrate_legacy_db
start_stack "$FIRST_RUN"
STACK_UP=0
wait_for_stack && STACK_UP=1

if [ "$STACK_UP" = 1 ] && wait_for_migrations; then
  features_run --new
  apply_feature_changes
fi

# ----------------------------------------------------------------- summary ---

WEB_HOST="$(get_env RESGRID_WEB_HOST)"; API_HOST="$(get_env RESGRID_API_HOST)"; EVENTS_HOST="$(get_env RESGRID_EVENTS_HOST)"
PORT_SUFFIX=""; [ "$(get_env RESGRID_HTTPS_PORT)" = "443" ] || [ -z "$(get_env RESGRID_HTTPS_PORT)" ] || PORT_SUFFIX=":$(get_env RESGRID_HTTPS_PORT)"

cat <<EOF

  Open:   https://$WEB_HOST$PORT_SUFFIX
EOF
[ "$FIRST_RUN" = 1 ] && printf '          then choose "Sign Up" to create the first account and department.\n'
cat <<EOF

  API:    https://$API_HOST$PORT_SUFFIX/health
  Events: https://$EVENTS_HOST$PORT_SUFFIX
  Optional features on: $(get_env RESGRID_FEATURES | tr ',' ' ')

EOF

if [ "$FIRST_RUN" = 1 ]; then
  case "$WEB_HOST" in
    *.mylocal|*.lan|*.internal|*.home.arpa|*.localhost)
      cat <<EOF
  HOSTNAMES: add this line to the hosts file of every computer that uses
  Resgrid (replace SERVER_IP with this server's address), or create the three
  records on your router/DNS server:

      SERVER_IP  $WEB_HOST $API_HOST $EVENTS_HOST
EOF
      ;;
  esac
  [ "$(get_env RESGRID_TLS)" = "internal" ] && print_ca_help
fi

cat <<EOF

  Manage the stack from $INSTALL_DIR:

      $COMPOSE ps                 # status
      $COMPOSE logs -f worker     # logs (web, api, events, worker, caddy, ...)
      $COMPOSE down               # stop (data is kept in Docker volumes)
      ./setup.sh features         # turn optional features on or off
      git pull && ./setup.sh      # upgrade (re-running is always safe)

EOF
