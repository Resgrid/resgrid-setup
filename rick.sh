#!/usr/bin/env bash
#
# Resgrid Incident Command Kit (RICK) node tool. Run on a kit node, from the
# configured checkout (same path on every node).
#
#   ./rick.sh role                     roles this node runs (matched by IP address)
#   ./rick.sh start [--profile P]      start this node's roles (data, infra, app, edge order)
#   ./rick.sh stop | restart | status | pull
#   ./rick.sh logs [service]           follow logs of this node's services
#   ./rick.sh health                   check every service of the whole kit
#   ./rick.sh sync                     copy this checkout to the other nodes (SSH)
#   ./rick.sh cluster <start|stop|status|pull|health>
#                                      run a command on every node, in order
#   ./rick.sh rollout                  copy the checkout to every node, pull images (when
#                                      online), start the kit in order, wait for the
#                                      database upgrade, offer new optional features
#   ./rick.sh features [--all]         turn optional features on or off for the whole kit
#   ./rick.sh upgrade                  git pull (when online), then ./setup.sh: adds new
#                                      settings to .env and runs the rollout
#   ./rick.sh backup                   database dump + .env + certs -> backups/ (data node)
#   ./rick.sh maps-import <url|file>   load an offline map region (infra node)
#   ./rick.sh cert                     get a publicly trusted certificate (DNS-01, online)
#   ./rick.sh bundle                   save all arm64 images to bundle/ (on an online machine)
#   ./rick.sh load [file]              load images from a bundle (offline nodes)
#
# Environment: RICK_ROLE=edge,app,...  override role detection
#              RICK_SSH_USER           SSH user for sync/cluster (default: $USER)
#              RESGRID_NO_PULL=1       rollout without pulling images (offline kit)
#              RESGRID_FEATURES        features to have on, without questions
#                                      (section names from features/catalog.ini,
#                                      "all" or "none")

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
ORDER=(data infra app edge)
REPO_URL="https://github.com/Resgrid/resgrid-setup"
BRANCH="rick"

info() { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,32p' "$0"; }

cmd="${1:-help}"; shift || true

# Before anything else: an upgrade works even when .env predates this script.
if [ "$cmd" = upgrade ]; then
  if [ -d .git ] && command -v git >/dev/null 2>&1; then
    saved=""
    # Kits configured before October 2026 tracked .env in git: keep it aside.
    if git ls-files --error-unmatch .env >/dev/null 2>&1; then
      saved="$(mktemp)"; cp .env "$saved"; git checkout -- .env 2>/dev/null || true
    fi
    info "Updating the setup files (git pull)..."
    git pull --ff-only || warn "git pull failed (offline, or local changes to tracked files?). Continuing with the files you have."
    if [ -n "$saved" ]; then cp "$saved" .env; rm -f "$saved"; chmod 600 .env; fi
  elif command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
    info "Updating the setup files (download)..."
    curl -fsSL "$REPO_URL/archive/refs/heads/$BRANCH.tar.gz" | tar -xz --strip-components=1 -C . ||
      warn "Download failed (offline?). Continuing with the files you have."
  fi
  exec ./setup.sh
fi

[ -f .env ] || die "No .env here. Run ./setup.sh once and copy the configured checkout to every node."
has_env() { grep -q "^$1=" .env; }
get_env() { grep "^$1=" .env 2>/dev/null | head -n 1 | cut -d= -f2- || true; }
sed_escape() { local v="$1"; v="${v//\\/\\\\}"; v="${v//&/\\&}"; v="${v//|/\\|}"; printf '%s' "$v"; }
set_env() { sed -i.sedbak "s|^$1=.*|$1=$(sed_escape "$2")|" .env && rm -f .env.sedbak; }
upsert_env() { if has_env "$1"; then set_env "$1" "$2"; else printf '%s=%s\n' "$1" "$2" >> .env; fi; }
prompt() {
  local q="$1" def="$2" ans=""
  if [ "${RESGRID_NONINTERACTIVE:-0}" != 1 ] && { : </dev/tty >/dev/tty; } 2>/dev/null; then
    printf '%s [%s]: ' "$q" "$def" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
  fi
  printf '%s' "${ans:-$def}"
}
host_of() { # host_of <role>
  case "$1" in
    edge) get_env RICK_EDGE_HOST ;; app) get_env RICK_APP_HOST ;;
    data) get_env RICK_DATA_HOST ;; infra) get_env RICK_INFRA_HOST ;;
  esac
}

local_ips() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1
  else
    hostname -I 2>/dev/null | tr ' ' '\n'
  fi
}

# Roles of this node in start order.
my_roles() {
  if [ -n "${RICK_ROLE:-}" ]; then
    local r
    for r in "${ORDER[@]}"; do [[ ",$RICK_ROLE," == *",$r,"* ]] && printf '%s\n' "$r"; done
    return 0
  fi
  local ips r
  ips="$(local_ips)"
  for r in "${ORDER[@]}"; do
    grep -qx "$(host_of "$r")" <<<"$ips" && printf '%s\n' "$r"
  done
  return 0
}
has_role() { local r; for r in $(my_roles); do [ "$r" = "$1" ] && return 0; done; return 1; }

# Is <address> this node (by address, or a role RICK_ROLE gives this node)?
is_me() {
  local r
  for r in $(my_roles); do [ "$(host_of "$r")" = "$1" ] && return 0; done
  grep -qx "$1" <<<"$(local_ips)"
}

ssh_user() { printf '%s' "${RICK_SSH_USER:-$USER}"; }

# on_host <address> <rick.sh args...>: run rick.sh there (here, or over SSH).
on_host() {
  local h="$1"; shift
  if is_me "$h"; then
    "$ROOT/rick.sh" "$@"
  else
    ssh "$(ssh_user)@$h" "cd $(printf '%q' "$ROOT") && ./rick.sh $(printf '%q ' "$@")"
  fi
}
on_role() { local role="$1"; shift; on_host "$(host_of "$role")" "$@"; }

# Every node once, in start order (reverse for stop).
kit_hosts() { # kit_hosts [reverse]
  local order=("${ORDER[@]}") seen=" " r h
  [ "${1:-}" = reverse ] && order=(edge app infra data)
  for r in "${order[@]}"; do
    h="$(host_of "$r")"
    [[ "$seen" == *" $h "* ]] && continue
    seen="$seen$h "
    printf '%s\n' "$h"
  done
}

compose() { # compose <role> <args...>
  local role="$1"; shift
  docker compose --env-file "$ROOT/.env" -f "$ROOT/nodes/$role/docker-compose.yml" "$@"
}

for_my_roles() { # for_my_roles <reverse:0|1> <compose args...>
  local reverse="$1"; shift
  local roles=()
  mapfile -t roles < <(my_roles)
  [ "${#roles[@]}" -gt 0 ] || die "This node's addresses ($(local_ips | tr '\n' ' ')) match none of RICK_*_HOST in .env. Fix the address or set RICK_ROLE."
  if [ "$reverse" = 1 ]; then
    local i; for ((i=${#roles[@]}-1; i>=0; i--)); do info "${roles[$i]}"; compose "${roles[$i]}" "$@"; done
  else
    local r; for r in "${roles[@]}"; do info "$r"; compose "$r" "$@"; done
  fi
}

# Split "--profile X" options from the other arguments.
PROFILES=(); ARGS=()
parse_args() {
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --profile ]; then
      [ "$#" -ge 2 ] || die "--profile needs a value."
      PROFILES+=(--profile "$2"); shift 2
    else
      ARGS+=("$1"); shift
    fi
  done
}

check() { # check <label> <command...>
  if "${@:2}" >/dev/null 2>&1; then printf '  %-34s ok\n' "$1"; else printf '  %-34s FAILED\n' "$1"; HEALTH_OK=0; fi
}
tcp() { timeout 3 bash -c "</dev/tcp/$1/$2"; }

# Wait until the edge answers for the API (after a start or restart).
wait_for_kit() {
  local edge api port
  edge="$(host_of edge)"; api="$(get_env RESGRID_API_HOST)"; port="$(get_env RESGRID_HTTPS_PORT)"; port="${port:-443}"
  info "Waiting for Resgrid to answer (a first start creates the database: 10-20 minutes on a Raspberry Pi)..."
  for _ in $(seq 1 240); do
    curl -fsS -k -m 5 --resolve "$api:$port:$edge" "https://$api:$port/health" >/dev/null 2>&1 && return 0
    sleep 5
  done
  warn "Resgrid didn't answer within 20 minutes (./rick.sh health)."
  return 1
}

# The worker (app node) creates/migrates the schema and seeds the feature
# flags after every start of a new image; wait for it before touching flags.
wait_for_migrations() {
  info "Waiting for the database migration to finish..."
  for _ in $(seq 1 240); do
    on_role app migrated >/dev/null 2>&1 && return 0
    sleep 5
  done
  warn "The worker hasn't reported a finished migration after 20 minutes (on rick2: ./rick.sh logs worker)."
  return 1
}

# Feature engine (lib/features.sh): SQL runs on the data node, redis-cli on
# the infra node; COMPOSE_PROFILES in .env selects the optional services.
load_features() {
  FEAT_CATALOG="$ROOT/features/catalog.ini"
  # shellcheck source=lib/features.sh
  . "$ROOT/lib/features.sh"
}
feat_psql() { printf '%s\n' "$1" | on_role data psql; }
feat_redis() { on_role infra redis-cli "$@"; }

# After the feature questions: new settings reach every node, services of
# profiles switched off are removed, and the flag cache is cleared.
apply_feature_changes() {
  local h p
  if [ "$FEAT_ENV_CHANGED" = 1 ]; then
    info "Copying the new settings to every node and restarting what changed..."
    "$ROOT/rick.sh" sync
    for p in $FEAT_PROFILES_OFF; do
      for h in $(kit_hosts reverse); do on_host "$h" profile-off "$p"; done
    done
    for h in $(kit_hosts); do on_host "$h" start; done
    wait_for_kit || true
  fi
  [ "$FEAT_FLAGS_CHANGED" = 1 ] && feat_clear_cache
  return 0
}

# Kits configured before October 2026 ran Compose projects resgrid-rick-<role>
# from this checkout, and PostgreSQL kept its data inside the database
# container. Copy that database into the data node once (the old container
# is stopped, not removed).
LEGACY_PROJECTS="resgrid-rick-database resgrid-rick-infra resgrid-rick-web"
legacy_containers() { # legacy_containers [service]
  local p
  for p in $LEGACY_PROJECTS; do
    docker ps -aq --filter "label=com.docker.compose.project=$p" ${1:+--filter "label=com.docker.compose.service=$1"}
  done
}
migrate_legacy_db() {
  local cid tables user dump ok=0 image="dhi.io/postgres:18-alpine3.22"
  [ -f .legacy-db-migrated ] && return 0
  cid="$(legacy_containers db | head -n 1)"
  [ -n "$cid" ] || return 0
  user="$(get_env POSTGRES_USER)"
  # The old container publishes port 5432 too: stop it (kept, restart off).
  docker update --restart=no "$cid" >/dev/null 2>&1 || true
  docker stop "$cid" >/dev/null 2>&1 || true
  compose data up -d db >/dev/null
  for _ in $(seq 1 60); do compose data exec -T db pg_isready -q 2>/dev/null && break; sleep 2; done
  compose data up -d db-init >/dev/null 2>&1 || true
  tables="$(compose data exec -T db psql -At -U "$user" -d resgrid -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo 0)"
  if [ "${tables:-0}" != 0 ]; then
    warn "Found the database container of the three-node kit, but the current database already has data. Not copying it."
    date > .legacy-db-migrated
    return 0
  fi
  if [ "${RESGRID_MIGRATE_LEGACY_DB:-0}" != 1 ]; then
    case "$(prompt "Found the database of the three-node kit (container $cid). Copy it into this kit? (y/n)" y)" in
      y|Y|yes|Yes) ;; *) return 0 ;;
    esac
  fi
  mkdir -p backups
  dump="backups/legacy-db-$(date +%Y%m%d-%H%M%S).sql.gz"
  info "Copying the old database (the old container is kept, stopped)..."
  docker rm -f rick-legacy-db >/dev/null 2>&1 || true
  docker volume rm rick-legacy-db >/dev/null 2>&1 || true
  # The data directory, with its owner and modes, into a scratch volume.
  if docker cp "$cid:/var/lib/postgresql/18/data" - |
     docker run -i --rm --user 0 --entrypoint sh -v rick-legacy-db:/var/lib/postgresql/18 "$image" -c 'tar -x -C /var/lib/postgresql/18'; then
    docker run -d --name rick-legacy-db -e POSTGRES_PASSWORD=unused -v rick-legacy-db:/var/lib/postgresql/18 "$image" >/dev/null
    for _ in $(seq 1 60); do docker exec rick-legacy-db pg_isready -q -U "$user" 2>/dev/null && break; sleep 2; done
    docker exec rick-legacy-db pg_dumpall -U "$user" --clean --if-exists | gzip > "$dump" && ok=1
    docker rm -f rick-legacy-db >/dev/null
    docker volume rm rick-legacy-db >/dev/null
  fi
  [ "$ok" = 1 ] || { warn "Copying the old database failed; the old container $cid is untouched (stopped). Nothing was loaded."; return 1; }
  info "Loading it into the data node (a copy of the dump is in $dump)..."
  gunzip -c "$dump" | compose data exec -T db psql -q -U "$user" -d postgres >/dev/null 2>"$dump.log" || true
  date > .legacy-db-migrated
  info "Old database copied. The worker upgrades its schema when the kit starts."
}

# Stop the three-node kit's containers on this node so their ports are free
# (they are kept, with restart disabled, until you remove them).
retire_legacy() {
  local cid
  for cid in $(legacy_containers); do
    docker update --restart=no "$cid" >/dev/null 2>&1 || true
    docker stop "$cid" >/dev/null 2>&1 || true
  done
}

case "$cmd" in
  role)
    my_roles | tr '\n' ' '; printf '\n' ;;

  start)
    parse_args "$@"
    for_my_roles 0 "${PROFILES[@]}" up -d --remove-orphans "${ARGS[@]}" ;;

  stop)
    parse_args "$@"
    for_my_roles 1 --profile dns --profile maps --profile tracking --profile relay --profile clamav stop "${ARGS[@]}" ;;

  restart)
    parse_args "$@"
    for_my_roles 0 "${PROFILES[@]}" restart "${ARGS[@]}" ;;

  status)
    for_my_roles 0 --profile dns --profile maps --profile tracking --profile relay --profile clamav ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}' ;;

  pull)
    parse_args "$@"
    for_my_roles 0 "${PROFILES[@]}" pull "${ARGS[@]}" ;;

  logs)
    roles=(); mapfile -t roles < <(my_roles)
    [ "${#roles[@]}" -gt 0 ] || die "No role matches this node."
    if [ "$#" -gt 0 ]; then
      for r in "${roles[@]}"; do
        services="$(compose "$r" --profile maps --profile tracking --profile relay --profile dns --profile clamav config --services)"
        if grep -qx "$1" <<<"$services"; then
          compose "$r" logs -f --tail 200 "$@"; exit 0
        fi
      done
      die "No service '$1' on this node."
    fi
    compose "${roles[-1]}" logs -f --tail 100 ;;

  health)
    HEALTH_OK=1
    edge="$(host_of edge)"; app="$(host_of app)"; data="$(host_of data)"; infra="$(host_of infra)"
    port="$(get_env RESGRID_HTTPS_PORT)"; port="${port:-443}"
    web="$(get_env RESGRID_WEB_HOST)"; api="$(get_env RESGRID_API_HOST)"; events="$(get_env RESGRID_EVENTS_HOST)"
    echo "Kit health (from $(hostname)):"
    check "rick3 data   PostgreSQL $data:5432" tcp "$data" 5432
    check "rick4 infra  Redis $infra:6379" tcp "$infra" 6379
    check "rick4 infra  RabbitMQ $infra:5672" tcp "$infra" 5672
    check "rick4 infra  RustFS $infra:9000" tcp "$infra" 9000
    check "rick2 app    API $app:5152" curl -fsS -m 5 "http://$app:5152/health"
    check "rick2 app    TTS $app:5154" curl -fsS -m 5 "http://$app:5154/health"
    check "rick1 edge   web https://$web" curl -fsS -k -m 10 --resolve "$web:$port:$edge" "https://$web:$port/Health/GetCurrent"
    check "rick1 edge   API https://$api" curl -fsS -k -m 10 --resolve "$api:$port:$edge" "https://$api:$port/health"
    check "rick1 edge   events https://$events" curl -fsS -k -m 10 --resolve "$events:$port:$edge" "https://$events:$port/health/GetCurrent"
    if curl -fsS -m 3 -o /dev/null "http://$infra:5156/tile/0/0/0.png" 2>/dev/null; then
      printf '  %-34s ok\n' "rick4 infra  map tiles $infra:5156"
    else
      printf '  %-34s not running (optional)\n' "rick4 infra  map tiles $infra:5156"
    fi
    case ",$(get_env COMPOSE_PROFILES)," in
      *,clamav,*) check "rick4 infra  ClamAV $infra:3310" tcp "$infra" 3310 ;;
    esac
    [ "$HEALTH_OK" = 1 ] ;;

  sync)
    user="$(ssh_user)"
    for h in $(kit_hosts); do
      is_me "$h" && continue
      info "Copying to $user@$h:$ROOT"
      ssh "$user@$h" "mkdir -p '$ROOT'"
      # Runtime folders on the nodes (and data of the three-node kit) are never touched.
      rsync -a --delete --exclude backups/ --exclude bundle/ --exclude docker-data/ \
        --exclude .legacy-db-migrated "$ROOT/" "$user@$h:$ROOT/"
    done ;;

  cluster)
    sub="${1:-}"; shift || true
    case "$sub" in start|stop|status|pull|health) ;; *) die "Usage: ./rick.sh cluster <start|stop|status|pull|health>" ;; esac
    direction=""; [ "$sub" = stop ] && direction=reverse
    for h in $(kit_hosts $direction); do
      info "$h: $sub"
      on_host "$h" "$sub" "$@" || warn "$h: '$sub' failed"
      [ "$sub" = health ] && break
    done ;;

  rollout)
    load_features
    "$ROOT/rick.sh" sync
    on_role data migrate-legacy-db || true
    for h in $(kit_hosts); do on_host "$h" retire-legacy; done
    if [ "${RESGRID_NO_PULL:-0}" != 1 ]; then
      info "Pulling images (images you can't reach while offline are skipped; RESGRID_NO_PULL=1 skips all)"
      for h in $(kit_hosts); do
        on_host "$h" pull --ignore-pull-failures || warn "$h: pull failed (offline?). Using the images already on the node."
      done
    fi
    for h in $(kit_hosts); do info "$h: start"; on_host "$h" start; done
    # Caddy doesn't watch its bind-mounted Caddyfile; restart it to pick up changes.
    on_role edge restart-caddy
    if wait_for_kit && wait_for_migrations; then
      features_run --new
      apply_feature_changes
    fi
    "$ROOT/rick.sh" health || true
    info "Optional features on: $(get_env RESGRID_FEATURES | sed 's/,/, /g')" ;;

  features)
    load_features
    features_run "$@"
    apply_feature_changes
    info "Optional features on: $(get_env RESGRID_FEATURES | sed 's/,/, /g')" ;;

  # ---- used by the commands above, on the node that has the role ----
  psql)            # SQL on stdin, run on the resgrid database (data node)
    compose data exec -T db psql -v ON_ERROR_STOP=1 -At -U "$(get_env POSTGRES_USER)" -d resgrid ;;
  redis-cli)       # redis-cli against the kit's Redis (infra node)
    compose infra exec -T redis redis-cli --no-auth-warning -a "$(get_env REDIS_PASSWORD)" "$@" ;;
  migrated)        # exit 0 once the worker finished its migration (app node)
    logs="$(compose app logs --no-color worker 2>/dev/null || true)"
    case "$logs" in *"Completed updating the core Resgrid databases"*) exit 0 ;; *) exit 1 ;; esac ;;
  profile-off)     # remove this node's services of a profile that was switched off
    p="${1:?profile}"
    for r in $(my_roles); do
      base=" $(compose "$r" config --services 2>/dev/null | tr '\n' ' ') "
      for svc in $(compose "$r" --profile "$p" config --services 2>/dev/null); do
        case "$base" in *" $svc "*) ;; *) compose "$r" --profile "$p" rm -sf "$svc" >/dev/null 2>&1 || true ;; esac
      done
    done ;;
  restart-caddy)
    compose edge restart caddy >/dev/null ;;
  migrate-legacy-db)
    migrate_legacy_db ;;
  retire-legacy)
    retire_legacy ;;

  backup)
    has_role data || die "Run backup on the data node ($(host_of data))."
    stamp="$(date +%Y%m%d-%H%M%S)"
    dir="backups/resgrid-$stamp"; mkdir -p "$dir"
    info "Dumping the database"
    # shellcheck disable=SC2016  # expanded inside the container
    compose data exec -T db sh -c 'pg_dumpall -U "$POSTGRES_USER" --clean --if-exists' | gzip > "$dir/resgrid.sql.gz"
    cp .env "$dir/env"; cp -r certs "$dir/certs"
    tar -czf "$dir.tar.gz" -C backups "resgrid-$stamp" && rm -rf "$dir"
    chmod 600 "$dir.tar.gz"
    info "Backup: $ROOT/$dir.tar.gz (contains every secret: keep it encrypted and off the kit)" ;;

  maps-import)
    src="${1:-}"
    [ -n "$src" ] || die "Usage: ./rick.sh maps-import <https://download.geofabrik.de/...osm.pbf | /path/region.osm.pbf>"
    has_role infra || die "Run maps-import on the infra node ($(host_of infra))."
    compose infra --profile maps rm -sf tileserver >/dev/null 2>&1 || true
    compose infra --profile maps run --rm --no-deps --entrypoint sh tileserver -c 'rm -rf /data/database/* /data/tiles/*'
    info "Importing $src (a US state takes 1-3 hours on a Raspberry Pi 5; import on a PC and copy the volumes to save time)"
    case "$src" in
      http://*|https://*) compose infra --profile maps run --rm -e DOWNLOAD_PBF="$src" tileserver import ;;
      *) [ -f "$src" ] || die "File not found: $src"
         compose infra --profile maps run --rm -v "$(cd "$(dirname "$src")" && pwd)/$(basename "$src"):/data/region.osm.pbf:ro" tileserver import ;;
    esac
    # Keep "maps" in COMPOSE_PROFILES so start/rollout keep the tile server running.
    profiles="$(get_env COMPOSE_PROFILES)"
    case ",$profiles," in *,maps,*) ;; *) upsert_env COMPOSE_PROFILES "${profiles:+$profiles,}maps" ;; esac
    compose infra up -d tileserver
    info "Map tiles ready. The web map uses $(get_env RESGRID__MappingConfig__LeafletTileUrl)"
    info "COMPOSE_PROFILES in .env now includes maps: copy it to the other nodes with ./rick.sh sync." ;;

  cert)
    # Publicly trusted certificate through a DNS-01 challenge (needs internet
    # and API access to the DNS provider of the kit domain). See README.md.
    # The DNS provider's credentials live in certs/acme/dns.env, in lego's
    # variable names (https://go-acme.github.io/lego/dns/), e.g.
    #   CF_DNS_API_TOKEN=...
    provider="${RICK_DNS_PROVIDER:-}"; email="${RICK_ACME_EMAIL:-}"; dns_env="certs/acme/dns.env"
    [ -n "$provider" ] && [ -n "$email" ] && [ -f "$dns_env" ] || die "Put the DNS provider credentials in $dns_env, then run: RICK_DNS_PROVIDER=<lego provider code, e.g. cloudflare> RICK_ACME_EMAIL=you@example.org ./rick.sh cert"
    web="$(get_env RESGRID_WEB_HOST)"; api="$(get_env RESGRID_API_HOST)"; events="$(get_env RESGRID_EVENTS_HOST)"
    case "${RICK_ACCEPT_LE_TOS:-}" in yes) ;; *)
      printf "Let's Encrypt Subscriber Agreement: https://letsencrypt.org/repository/  Accept? [yes/no]: "
      read -r ans; [ "$ans" = yes ] || die "Not accepted." ;;
    esac
    chmod 600 "$dns_env"
    action=run; [ -f "certs/acme/certificates/$web.crt" ] && action="renew --days 45"
    # shellcheck disable=SC2086
    docker run --rm --env-file "$dns_env" -v "$ROOT/certs/acme:/data" goacme/lego:latest \
      --accept-tos --email "$email" --dns "$provider" --path /data \
      --domains "$web" --domains "$api" --domains "$events" $action
    cp "certs/acme/certificates/$web.crt" certs/site/fullchain.pem
    cp "certs/acme/certificates/$web.key" certs/site/privkey.pem
    chmod 644 certs/site/fullchain.pem certs/site/privkey.pem
    set_env RESGRID_TLS "/certs/site/fullchain.pem /certs/site/privkey.pem"
    info "Certificate installed in certs/site (expires $(openssl x509 -enddate -noout -in certs/site/fullchain.pem | cut -d= -f2))."
    info "Copy it to rick1 (./rick.sh sync) and run ./rick.sh start && ./rick.sh restart caddy there to load it. Renew within 60 days, while online." ;;

  bundle)
    repo="$(get_env RESGRID_IMAGE_REPO)"; tag="$(get_env RESGRID_IMAGE_TAG)"
    images=()
    for r in "${ORDER[@]}"; do
      while read -r img; do images+=("$img"); done < <(compose "$r" --profile maps --profile dns --profile tracking --profile relay --profile clamav config --images)
    done
    mapfile -t images < <(printf '%s\n' "${images[@]}" | sort -u)
    mkdir -p bundle
    for img in "${images[@]}"; do info "Pulling $img (linux/arm64)"; docker pull --platform linux/arm64 "$img"; done
    out="bundle/rick-images-arm64-$(date +%Y%m%d).tar"
    info "Saving ${#images[@]} images to $out"
    docker save --platform linux/arm64 -o "$out" "${images[@]}"
    info "Copy $out to each node and run ./rick.sh load $out (repo $repo, tag $tag)." ;;

  load)
    file="${1:-$(find bundle -maxdepth 1 -name 'rick-images-arm64-*.tar' 2>/dev/null | sort | tail -n 1 || true)}"
    [ -f "$file" ] || die "No bundle found. Usage: ./rick.sh load <bundle.tar>"
    docker load -i "$file" ;;

  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
