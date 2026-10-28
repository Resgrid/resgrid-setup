#!/usr/bin/env bash
#
# Load an OpenStreetMap extract into the offline tile server (profile "maps")
# and point the Resgrid web map at it.
#
# Usage (from the install directory, while you still have internet if you
# pass a URL):
#   ./maps/import.sh https://download.geofabrik.de/north-america/us/nevada-latest.osm.pbf
#   ./maps/import.sh /path/to/region.osm.pbf
#
# Extracts: https://download.geofabrik.de (pick the smallest area you need;
# a US state takes 10-60 minutes and several GB of disk to import).
# Re-running replaces the previous import.

set -euo pipefail

cd "$(dirname "$0")/.."
SOURCE="${1:-}"
[ -n "$SOURCE" ] || { sed -n '3,14p' "$0"; exit 2; }
[ -f .env ] || { echo "Run ./setup.sh first (.env not found)." >&2; exit 1; }

if docker compose version >/dev/null 2>&1; then COMPOSE="docker compose"; else COMPOSE="docker-compose"; fi
get_env() { grep "^$1=" .env | head -n 1 | cut -d= -f2-; }

$COMPOSE --profile maps rm -sf tileserver >/dev/null 2>&1 || true
# A fresh import needs empty volumes.
$COMPOSE --profile maps run --rm --no-deps --entrypoint sh tileserver -c 'rm -rf /data/database/* /data/tiles/*'

echo "==> Importing $SOURCE (this takes a while)..."
case "$SOURCE" in
  http://*|https://*)
    $COMPOSE --profile maps run --rm -e DOWNLOAD_PBF="$SOURCE" tileserver import ;;
  *)
    [ -f "$SOURCE" ] || { echo "File not found: $SOURCE" >&2; exit 1; }
    $COMPOSE --profile maps run --rm -v "$(cd "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE"):/data/region.osm.pbf:ro" tileserver import ;;
esac

echo "==> Starting the tile server..."
# Keep "maps" in COMPOSE_PROFILES so `docker compose up -d` and setup.sh keep it running.
profiles="$(get_env COMPOSE_PROFILES)"
case ",$profiles," in *",maps,"*) ;; *)
  profiles="${profiles:+$profiles,}maps"
  if grep -q '^COMPOSE_PROFILES=' .env; then
    sed -i.sedbak "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=$profiles|" .env && rm -f .env.sedbak
  else
    printf 'COMPOSE_PROFILES=%s\n' "$profiles" >> .env
  fi ;;
esac
$COMPOSE --profile maps up -d tileserver

port="$(get_env RESGRID_HTTPS_PORT)"
suffix=""
[ -z "$port" ] || [ "$port" = "443" ] || suffix=":$port"
tile_url="https://$(get_env RESGRID_WEB_HOST)${suffix}/tiles/{z}/{x}/{y}.png"
sed -i.sedbak "s|^RESGRID__MappingConfig__LeafletTileUrl=.*|RESGRID__MappingConfig__LeafletTileUrl=${tile_url}|" .env
rm -f .env.sedbak
echo "==> Web map now uses $tile_url"

$COMPOSE up -d web api >/dev/null
echo "==> Done. Tiles render on first view and are cached in the osm-tiles volume."
