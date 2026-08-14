# Resgrid Incident Command Kit (RICK)

This branch runs the current Resgrid Core stack across three small 64-bit Linux nodes, typically Raspberry Pi 5 systems on a private wired LAN:

| Node role | Services |
|---|---|
| `web` | Caddy, web app, API, events, worker/migrations, TTS, MCP; optional tracker gateway and email relay |
| `infra` | Redis, RabbitMQ, RustFS object storage; optional offline OSM tile server |
| `database` | PostgreSQL and the four Resgrid databases |

RICK separates failure and I/O domains but is not highly available: each role is still a single point of failure. It is designed for a portable incident LAN where low power use, clear recovery steps, and offline operation matter more than automatic failover.

## Hardware and network

- Three Raspberry Pi 5 (8 GB recommended) or equivalent `linux/arm64` computers.
- 64-bit Raspberry Pi OS Lite or Ubuntu Server; do not use a 32-bit image.
- High-endurance storage. An SSD is strongly recommended for the database node.
- A managed or unmanaged wired switch and fixed DHCP reservations/static addresses.
- Docker Engine with the Compose v2 plugin on every node.
- `qemu-user-static` and `binfmt-support` on the web node (see the architecture notice below).
- A separate encrypted USB/SSD for backups.

### Current application-image architecture

As of this branch update, the published Resgrid application images are `linux/amd64` only. The PostgreSQL, Redis, RabbitMQ, Caddy, RustFS, MinIO client, and tile-server images publish native ARM64 variants, but the application role does not.

RICK therefore pins application containers to `linux/amd64` and runs them through the kernel's x86_64 binfmt/QEMU handler on the web Pi. Install the persistent handler before starting that role:

```bash
sudo apt update
sudo apt install -y qemu-user-static binfmt-support
cat /proc/sys/fs/binfmt_misc/qemu-x86_64
```

The last command must begin with `enabled`. Reboot after installation if necessary. `rick.sh web start` refuses to continue on ARM64 when the handler is absent, preventing a misleading partial start.

Emulation reduces performance and increases CPU load; qualify the complete kit under realistic incident load. Native multi-architecture Resgrid images are the preferred long-term solution. Once those are published, change `RESGRID_APP_PLATFORM` in `.env` to `linux/arm64` and revalidate every application image before field use.

Example addressing used by the templates:

| Node | Address |
|---|---|
| Web/API | `192.168.50.11` |
| Infrastructure | `192.168.50.12` |
| Database | `192.168.50.13` |

The three Resgrid hostnames (`rg.rick.local`, `rgapi.rick.local`, and `rgevents.rick.local`) must all resolve to the web node. Use your router/DNS appliance or add hosts-file entries on every client.

## Prepare the kit

Clone once on an administration computer or one Pi:

```bash
git clone --branch rick https://github.com/Resgrid/resgrid-setup.git resgrid-rick
cd resgrid-rick
chmod +x setup.sh rick.sh database/db/*.sh
./setup.sh
```

`setup.sh` asks for the three public/LAN hostnames and the three node addresses. It generates unique database, Redis, RabbitMQ, RustFS, application encryption, JWT, relay, tracker, and OpenIddict credentials. Run it exactly once.

Securely copy the whole configured checkout to the same path on each node. The generated `.env` must be identical everywhere:

```bash
rsync -a --delete ./ pi@192.168.50.11:/opt/resgrid-rick/
rsync -a --delete ./ pi@192.168.50.12:/opt/resgrid-rick/
rsync -a --delete ./ pi@192.168.50.13:/opt/resgrid-rick/
```

Protect `.env`: it contains credentials, encryption keys, and OIDC private keys. Keep an offline backup; losing it can make existing data and tokens unrecoverable.

## Start in dependency order

On the database node:

```bash
cd /opt/resgrid-rick
./rick.sh database config
./rick.sh database start
./rick.sh database status
```

On the infrastructure node:

```bash
cd /opt/resgrid-rick
./rick.sh infra config
./rick.sh infra start
./rick.sh infra status
```

On the web node, after PostgreSQL, Redis, RabbitMQ, and RustFS report healthy:

```bash
cd /opt/resgrid-rick
./rick.sh web config
./rick.sh web start
./rick.sh web logs worker
```

The worker creates and migrates `resgrid`, `resgridoidc`, `resgridworkers`, and `resgriddoc`. When migration activity settles, open the three HTTPS URLs once and accept Caddy's internal certificate on every client, then use **Sign Up** to create the first account and department.

## Firewall boundaries

Permit only the required traffic on the incident LAN:

| Source | Destination | Ports |
|---|---|---|
| Clients | Web node | TCP 80, 443 |
| Web node | Database node | TCP 5432 |
| Web node | Infra node | TCP 5672, 6379, 9000 |
| Administrators | Infra node | TCP 15672 (RabbitMQ UI) |

PostgreSQL, Redis, RabbitMQ, and RustFS are authenticated but are not meant to be exposed outside the isolated kit LAN. MCP is bound only to loopback on the web node. Optional tracker ports and SMTP port 25 should be opened only when those profiles are deliberately enabled.

## Optional offline maps

The infra Compose file preserves the kit's optional local OSM tile service. Import a regional `.osm.pbf` before starting it; imports are storage- and CPU-intensive, so prepare them before deployment:

```bash
mkdir -p docker-data/osm
docker run --rm \
  -v /path/to/region.osm.pbf:/data/region.osm.pbf:ro \
  -v "$PWD/docker-data/osm:/data/database/" \
  overv/openstreetmap-tile-server:latest import
./rick.sh infra start --profile maps
```

Then set `RESGRID__MappingConfig__LeafletTileUrl` in the shared `.env` to `http://192.168.50.12:5156/tile/{z}/{x}/{y}.png`, redistribute `.env`, and recreate the web role. Verify the tile image supports your Pi's architecture before field deployment.

## Optional Core services

Tracker ingest on the web node:

```bash
./rick.sh web start --profile tracking
```

Enable the required `RESGRID__UnitTrackingConfig__*` settings first. The profile publishes Queclink, GT06, and Teltonika TCP/UDP ports.

Inbound-email dispatch:

```bash
./rick.sh web start --profile relay
```

Configure the relay department/domain settings first. The listener has no SMTP authentication or TLS; use it only behind a firewall or filtering MTA.

## Offline image preparation

Before leaving internet access, run `./rick.sh <role> pull` on each node. For a truly air-gapped spare, export the exact images listed by `docker compose config --images`:

```bash
docker save IMAGE_1 IMAGE_2 ... | gzip > rick-images-arm64.tar.gz
```

Restore with `gunzip -c rick-images-arm64.tar.gz | docker load`. Test the archive and a complete cold start before deployment.

## Backup, upgrade, and rollback

Stop application writes or schedule a maintenance window, then dump PostgreSQL on the database node:

```bash
docker compose --env-file .env -p resgrid-rick-database -f database/docker-compose.yml \
  exec -T db pg_dumpall -U resgrid | gzip > "resgrid-$(date +%F).sql.gz"
```

Back up that dump, `.env`, `docker-data/rustfs`, and Caddy data off-kit. Redis can be rebuilt, but its dump is useful for faster recovery.

Upgrade roles in this order: database/infra images, worker, then the remaining web services. In practice, pull and recreate `infra`, then `database`, then `web`, while watching worker migrations.

Rollback requires the previous image digests/tags and a pre-upgrade database dump. Application rollback alone is unsafe after an incompatible schema migration. Restore the database dump, restore the matching `.env`, select the previous images, and start roles again in database → infra → web order.

## Troubleshooting

- `WAIT_HOSTS` timeouts usually mean the node addresses in `.env`, routing, or firewall rules are wrong.
- Login failures with internal TLS commonly mean the browser has not accepted the API/events certificates.
- If containers cannot reach node hostnames, use fixed IP addresses in `.env`; container DNS does not reliably inherit custom entries from the Pi's `/etc/hosts`.
- Do not independently re-run `setup.sh` on each node. Different secrets make the cluster unusable.
