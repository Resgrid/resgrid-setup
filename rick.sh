#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE="${1:-}"
ACTION="${2:-}"
shift "$(( $# > 0 ? 1 : 0 ))"
shift "$(( $# > 0 ? 1 : 0 ))"

usage() {
  cat <<'EOF'
Usage: ./rick.sh <database|infra|web> <start|stop|restart|pull|status|logs|config> [service]

Examples:
  ./rick.sh database start
  ./rick.sh infra status
  ./rick.sh web logs worker
  ./rick.sh web restart

Add --profile maps, tracking, or relay after the action when required, e.g.:
  ./rick.sh infra start --profile maps
EOF
}

case "$ROLE" in database|infra|web) ;; *) usage; exit 2 ;; esac
case "$ACTION" in start|stop|restart|pull|status|logs|config) ;; *) usage; exit 2 ;; esac

[ -f "$ROOT/.setup-complete" ] || { echo "Run ./setup.sh once and distribute the configured checkout first." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "Docker is required." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is not running or this user cannot access it." >&2; exit 1; }

if [ "$ROLE" = web ] && { [ "$ACTION" = start ] || [ "$ACTION" = restart ]; }; then
  case "$(uname -m)" in
    aarch64|arm64)
      if [ ! -r /proc/sys/fs/binfmt_misc/qemu-x86_64 ] || ! grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-x86_64; then
        cat >&2 <<'EOF'
The published Resgrid application images are currently linux/amd64 only.
This ARM64 web node needs persistent qemu-x86_64 binfmt registration.

On Raspberry Pi OS/Ubuntu, install and verify it with:
  sudo apt update
  sudo apt install -y qemu-user-static binfmt-support
  cat /proc/sys/fs/binfmt_misc/qemu-x86_64

Reboot if the handler is not enabled, then retry. Native multi-arch Resgrid
images are preferred when they become available; set RESGRID_APP_PLATFORM in
.env to their platform at that time.
EOF
        exit 1
      fi
      ;;
  esac
fi

compose=(docker compose --env-file "$ROOT/.env" --project-name "resgrid-rick-$ROLE" --file "$ROOT/$ROLE/docker-compose.yml")

compose_options=()
action_args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --profile ]; then
    [ "$#" -ge 2 ] || { echo "--profile requires a value." >&2; exit 2; }
    compose_options+=(--profile "$2")
    shift 2
  else
    action_args+=("$1")
    shift
  fi
done
compose+=("${compose_options[@]}")

case "$ACTION" in
  start)   "${compose[@]}" up -d "${action_args[@]}" ;;
  stop)    "${compose[@]}" down "${action_args[@]}" ;;
  restart) "${compose[@]}" up -d --force-recreate "${action_args[@]}" ;;
  pull)    "${compose[@]}" pull "${action_args[@]}" ;;
  status)  "${compose[@]}" ps "${action_args[@]}" ;;
  logs)    "${compose[@]}" logs -f "${action_args[@]}" ;;
  config)  "${compose[@]}" config --quiet "${action_args[@]}" && echo "$ROLE configuration is valid." ;;
esac
