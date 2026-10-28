# Resgrid Incident Command Kit (RICK)

RICK is a portable Resgrid server for a base camp, staging area or command vehicle: four Raspberry Pi 5 computers in a 1U rack, a network switch and a WiFi hotspot router, all running on battery, **with no internet at all**.

- Responders join the kit's WiFi and use the **Resgrid Responder** and **Resgrid Unit** apps on their phones and tablets, connected to the kit instead of resgrid.com.
- The incident commander or dispatcher uses the **Resgrid web app** in a browser on a laptop connected to the kit (WiFi or cable).
- Everything (database, messaging, maps, text-to-speech) runs on the four Pis. When the kit is powered on it starts by itself.

Guide with diagrams and photos: <https://docs.resgrid.com/self-hosted/rick>.

```
  Responder / Unit apps          Command laptop (browser)
        )))  WiFi  (((                 │ WiFi or cable
   ┌──────────────────────────────────┴──────────┐
   │  Hotspot router  192.168.50.1  DHCP + DNS   │  rg / rgapi / rgevents.<kit domain> → rick1
   └──────────────┬──────────────────────────────┘
                  │ Gigabit (PoE+) switch
   ┌──────────────┼───────────────┬───────────────┬───────────────┐
   │ rick1 edge   │ rick2 app     │ rick3 data    │ rick4 infra   │
   │ .11          │ .12           │ .13           │ .14           │
   │ Caddy :443   │ API     :5152 │ PostgreSQL    │ Redis  :6379  │
   │ web          │ worker        │        :5432  │ RabbitMQ:5672 │
   │ events       │ TTS     :5154 │               │ RustFS :9000  │
   │ (kit DNS)    │ MCP (local)   │               │ map tiles:5156│
   └──────────────┴───────────────┴───────────────┴───────────────┘
```

Every client talks only to **rick1** over HTTPS (443). rick1 proxies the API and text-to-speech to rick2 and map tiles to rick4; rick2 and rick1 use the database on rick3 and Redis/RabbitMQ/RustFS on rick4. Splitting the roles spreads memory, CPU and disk I/O over four boards and keeps the database alone on its NVMe SSD.

## Hardware

| Item | Notes |
|---|---|
| 4 × Raspberry Pi 5, **8 GB** (16 GB optional) | 64-bit Raspberry Pi OS Lite (Bookworm or newer) |
| [UCTRONICS Pi 5 Rack Pro](https://www.uctronics.com/) 1U rack | 4 slots, an M.2 NVMe base and a status LCD per Pi |
| 4 × M.2 2230/2242 NVMe SSD, 128 GB+ | Boot each Pi from its SSD (much more reliable than microSD) |
| 4 × Raspberry Pi RTC battery | Keeps the clock through power-off; at least rick1 needs one (see [Time](#time-without-internet)) |
| Gigabit switch, 5+ ports | A PoE+ (802.3at) switch with ~120 W budget plus a PoE+ HAT per Pi removes four power supplies; otherwise 4 × official 27 W USB-C supplies |
| WiFi travel router (e.g. GL.iNet Beryl AX / Slate AX) | DHCP, DNS overrides, WPA2/WPA3; no internet uplink needed |
| Power | A 12 V / 230 V power station (≥500 Wh) or vehicle power. The kit draws about 25–45 W (4 Pis, switch, router): roughly 10–15 hours per 500 Wh. Add a UPS if it runs off vehicle power. |

Plan for 16 GB+ of free space per node; the data node's SSD holds the database and rick4's holds the map data (a US state is 5–20 GB).

## Images for Raspberry Pi

RICK needs `linux/arm64` images. The infrastructure images (PostgreSQL, Redis, RabbitMQ, Caddy, RustFS, rclone, tile server) are multi-architecture. The Resgrid application images (`resgridllc/*`) are published for `linux/amd64` only today; Resgrid Core has the Dockerfile changes to build them for arm64 as well.

Until multi-architecture images are on Docker Hub, build them once on any computer with Docker and a [Resgrid Core](https://github.com/Resgrid/Core) checkout that includes the multi-architecture Dockerfiles, push them to a registry your kit can reach during preparation (or use `./rick.sh bundle`), and set in `.env`:

```bash
RESGRID_IMAGE_REPO=registry.example.org/resgrid   # where your arm64 images are
RESGRID_IMAGE_TAG=latest
```

Example build (from the Core checkout):

```bash
for p in Web/Resgrid.Web:resgridwebcore Web/Resgrid.Web.Services:resgridwebservices \
         Web/Resgrid.Web.Eventing:resgridwebevents Web/Resgrid.Web.Tts:resgridwebtts \
         Web/Resgrid.Web.Mcp:resgridwebmcp Workers/Resgrid.Workers.Console:resgridworkersconsole \
         Workers/Resgrid.TrackerGateway:resgridtrackergateway; do
  docker buildx build --platform linux/arm64 -f "${p%%:*}/Dockerfile" \
    -t "registry.example.org/resgrid/${p##*:}:latest" --push .
done
```

Once `resgridllc/*` is multi-architecture, keep `RESGRID_IMAGE_REPO=resgridllc`.

## 1. Prepare the network

On the hotspot router:

1. Set the LAN to `192.168.50.1/24` (or adjust every address in this guide), DHCP range e.g. `192.168.50.100–200`.
2. Reserve (or keep free) `192.168.50.11–14` for rick1–rick4.
3. Set the WiFi name and a strong WPA2/WPA3 password. Responders will join this network.
4. Add DNS records (GL.iNet: *Network > DNS > Edit Hosts*, OpenWrt: *Network > DHCP and DNS > Hostnames*) pointing the three Resgrid hostnames at rick1:

   ```text
   192.168.50.11  rg.rick.internal
   192.168.50.11  rgapi.rick.internal
   192.168.50.11  rgevents.rick.internal
   ```

   If the router can't do that, use the kit's own DNS server on rick1 (`./rick.sh start --profile dns` on rick1) and set the router's DHCP DNS server option to `192.168.50.11`.

Connect the router's LAN port and the four Pis to the switch. Leave the router's WAN port unplugged in the field; plug it in only when you want the kit online (updates, certificates).

Don't use `.local` hostnames: iPhones and Macs only look those up with multicast DNS, so router DNS records for them are ignored. `rick.internal` (reserved for private networks) or a subdomain you own both work.

## 2. Prepare each Pi (once, with internet)

Flash 64-bit Raspberry Pi OS Lite to each SSD with Raspberry Pi Imager (set a user, SSH, and hostnames `rick1`–`rick4`), boot each Pi from its SSD, then on each one:

```bash
git clone --branch rick https://github.com/Resgrid/resgrid-setup.git /opt/resgrid-rick   # sudo chown $USER first if needed
cd /opt/resgrid-rick
sudo ./os/prepare-node.sh rick1 192.168.50.11 192.168.50.1     # rick2 .12, rick3 .13, rick4 .14
sudo reboot
```

`prepare-node.sh` sets the hostname and fixed address, installs Docker Engine + Compose, configures time keeping (rick1 serves time to the others) and a Redis kernel setting. `RICK_PCIE_GEN3=1` also enables PCIe Gen 3 for the SSD.

Set up SSH keys from rick1 to the others so `./rick.sh sync` and `./rick.sh cluster` work: `ssh-keygen` on rick1, then `ssh-copy-id <user>@192.168.50.12` (and .13, .14).

## 3. Configure the kit (once)

On rick1:

```bash
cd /opt/resgrid-rick
./setup.sh
```

Setup asks for the four node addresses, the router address and the kit domain (default `rick.internal`), then writes `.env` with every password and key for the whole kit, creates the local certificate authority (`certs/`) and `dns/dnsmasq.conf`. At the end it offers to start the kit right away (`./rick.sh rollout`, step 6); answer `n` the first time if you still need to pull images or import maps. Copy the configured checkout to the other nodes:

```bash
./rick.sh sync
```

Every node must have the **same** `.env` and `certs/`. Run `setup.sh` on rick1 only; `./rick.sh sync` (and `rollout`) copy its result to the others. `sync` never touches the nodes' `docker-data/`, `backups/` or `bundle/` folders.

## 4. Download the images (with internet)

```bash
./rick.sh cluster pull
```

To prepare spare SSDs or rebuild a node in the field without internet, also save the images once (on any machine that has Docker and this checkout) and keep the file with the kit: `./rick.sh bundle` writes `bundle/rick-images-arm64-<date>.tar`; load it on a node with `./rick.sh load`.

## 5. Offline maps (with internet, recommended)

The web map uses OpenStreetMap tiles served by rick4. Import your area once (pick the smallest [Geofabrik extract](https://download.geofabrik.de) that covers it). On rick4:

```bash
./rick.sh maps-import https://download.geofabrik.de/north-america/us/nevada-latest.osm.pbf
```

Importing a US state takes 1–3 hours on a Pi 5. To save time, import on a PC with the [`master`](https://github.com/Resgrid/resgrid-setup) stack's `maps/import.sh` and copy the `osm-data` volume to rick4. Tiles render on first view and are cached; browse your area at the zoom levels you need once before deploying to warm the cache.

The Responder and Unit apps draw their maps with Mapbox, which needs internet; offline they show the map only where they have it cached.

## 6. Start the kit

From rick1:

```bash
./rick.sh rollout
```

`rollout` copies the checkout to every node, pulls images on each (images it can't reach offline are skipped; `RESGRID_NO_PULL=1` skips pulling), starts data, infra, app and edge in that order over SSH, waits until the database is ready, walks you through the [optional features](#optional-features) and ends with `./rick.sh health`. Without SSH between the nodes, start each node yourself instead (below), then run `./rick.sh features` on rick1.

To start an already configured kit again: `./rick.sh cluster start` (or `./rick.sh start` on each node).

On each node yourself, in the order rick3, rick4, rick2, rick1: `./rick.sh start` (the optional services in `COMPOSE_PROFILES`, such as `maps` and `dns`, start with it). `./rick.sh role` shows which role a node has (it matches the node's IP address with `.env`).

First start takes 10–20 minutes on Pis while the worker on rick2 creates the database (`./rick.sh logs worker` on rick2). `./rick.sh health` lists every service of the kit:

```text
Kit health (from rick1):
  rick3 data   PostgreSQL 192.168.50.13:5432 ok
  rick4 infra  Redis 192.168.50.14:6379 ok
  rick4 infra  RabbitMQ 192.168.50.14:5672 ok
  rick4 infra  RustFS 192.168.50.14:9000 ok
  rick2 app    API 192.168.50.12:5152 ok
  rick2 app    TTS 192.168.50.12:5154 ok
  rick1 edge   web https://rg.rick.internal ok
  rick1 edge   API https://rgapi.rick.internal ok
  rick1 edge   events https://rgevents.rick.internal ok
  rick4 infra  map tiles 192.168.50.14:5156 ok
```

From then on the kit starts by itself when powered on: Docker starts every container and each one waits for the others (rick1/rick2 retry until rick3/rick4 are up), so the order nodes boot in doesn't matter.

## Optional features

Resgrid ships several modules behind feature flags that are off on a new kit. `rollout` asks about each one; change them any time from rick1:

```bash
./rick.sh features          # walk through the optional features
./rick.sh features --all    # also offer flags no feature in the catalog covers
```

One question covers everything a feature needs: **Records (RMS)** (13 flags: incident and field records, prevention, investigations, quality review, analytics), **Unified search** (index stored in RustFS on rick4), **Chat**, **Run cards**, **Checklists**, **Deployments**, **Setup wizard and admin guidance**, **Department import and migration**, **Attachment virus scanning** (a ClamAV container on rick4 that needs about 1.5 GB of RAM; it brings its own signatures, so it works offline with the signatures from your last online update) and **Text-message commands (Twilio)** (needs internet). Resgrid's paid add-ons need Resgrid's hosted billing and aren't offered.

The flags are switched in the database on rick3 (over SSH when you run it elsewhere), settings go into `.env`, and when settings changed `features` copies `.env` to every node and restarts what changed. Without questions: `RESGRID_FEATURES=records,search,chat ./rick.sh features` (or `all` / `none`; features not listed are switched off). Later rollouts only ask about features that are new in that version and switch the features you turned on (`RESGRID_FEATURES` in `.env`) fully back on when a restored database or a new version left them off. The catalog is [`features/catalog.ini`](features/catalog.ini), shared by all setup branches: see [Maintaining the feature list](https://github.com/Resgrid/resgrid-setup#maintaining-the-feature-list).

## 7. First login (command laptop)

1. Join the kit WiFi (or plug into the switch).
2. Trust the kit certificate on the laptop: copy `certs/ca/resgrid-root-ca.crt` from rick1 (for example `scp <user>@192.168.50.11:/opt/resgrid-rick/certs/ca/resgrid-root-ca.crt .`) and install it as a trusted root (Windows: double-click > *Install Certificate* > *Local Machine* > *Trusted Root Certification Authorities*; macOS: Keychain Access > *Always Trust*).
3. Open `https://rg.rick.internal` and choose **Sign Up** to create your account and the department. Then add personnel, units, stations and roles ([department setup](https://docs.resgrid.com/configuration/setup)). Without internet no email is sent: set each person's password under **Personnel > Add Person**.
4. Turn sign-up off afterwards: in `.env` set `RESGRID__SystemBehaviorConfig__AllowSignupWithoutBilling=false`, `./rick.sh sync`, then `./rick.sh cluster start`.

## 8. Responders' phones

Install the **Resgrid Responder** and **Resgrid Unit** apps from the App Store / Google Play **before** going offline. Then:

1. Join the kit WiFi. Android: when it says the network has no internet, choose **Stay connected** (and turn mobile data off, or Android may send the apps over cellular). iPhone: allow **Local Network** access when the app asks.
2. On the app's login screen tap **Change Server URL** (Responder) or **Server URL** (Unit), choose **Custom** and enter `https://rgapi.rick.internal` (no path, no trailing slash). The app may take up to 30 seconds to give up looking for resgrid.com first.
3. Log in with the user name and password created in the web app.

Certificates on phones:

| Phone | Kit with the local CA (`RESGRID_TLS=internal`) | Kit with a public certificate (`./rick.sh cert`) |
|---|---|---|
| iPhone / iPad | Install `resgrid-root-ca.crt` as a profile, then enable it in *Settings > General > About > Certificate Trust Settings* | Works as is |
| Android | Browsers work after installing the CA (*Settings > Security > Install a certificate > CA certificate*); **the Responder and Unit apps do not trust user-installed CAs** | Works as is |

So if Android phones must use the apps, give the kit a publicly trusted certificate ([below](#publicly-trusted-certificate-android-apps)).

What works offline on phones: dispatches, calls, statuses, staffing, personnel and unit locations, messages and chat **while the app is open** (real-time updates over the events hub). Not available offline: push notifications when the app is closed (they need Google/Apple services), maps (Mapbox), address search, voice/PTT.

## Publicly trusted certificate (Android apps)

The Android Resgrid apps only accept certificates from public certificate authorities. Use a domain you own (e.g. `rick.yourdept.org`, set as the kit domain in `setup.sh`) and get a Let's Encrypt certificate with a DNS challenge, which works even though the kit itself is never reachable from the internet. While the kit (rick1) is online:

```bash
mkdir -p certs/acme
echo 'CF_DNS_API_TOKEN=your-token' > certs/acme/dns.env       # your DNS provider's API credentials
RICK_DNS_PROVIDER=cloudflare RICK_ACME_EMAIL=you@yourdept.org ./rick.sh cert
./rick.sh sync && ./rick.sh start && ./rick.sh restart caddy   # on rick1: load the new certificate
```

Provider codes and credential variable names: <https://go-acme.github.io/lego/dns/> (Cloudflare, Route 53, Azure DNS, Google Cloud DNS, DigitalOcean, GoDaddy, …). The DNS records for the three hostnames stay on the kit router (pointing at rick1); only the challenge record is created at your DNS provider. Let's Encrypt certificates last 90 days: **run `./rick.sh cert` again while online at least every 60 days** (it renews), or the apps and browsers will refuse to connect.

## Time without internet

TLS certificates and logins depend on every device having the right time. rick1 serves time to rick2–rick4 (chrony); with an RTC battery it keeps time when powered off. Check with `chronyc tracking` on any node. Phones and laptops keep their own time.

## Operations

```bash
./rick.sh status                 # this node's services
./rick.sh logs api               # follow a service's log (on the node that runs it)
./rick.sh health                 # whole kit
./rick.sh cluster stop           # stop the kit before powering off (edge, app, infra, data)
./rick.sh cluster start
```

Shut down cleanly before cutting power when you can (`./rick.sh cluster stop`, then `sudo poweroff` on each node). The UCTRONICS rack's safe-shutdown button also works per Pi.

### Backup

On rick3 (data node):

```bash
./rick.sh backup
```

writes `backups/resgrid-<date>.tar.gz` (database dump, `.env`, certificates). Copy it to an encrypted USB drive and off the kit after each deployment. Restore onto a kit with the same `.env`/`certs/`:

```bash
tar -xzf backups/resgrid-<date>.tar.gz -C /tmp
docker compose --env-file .env -f nodes/app/docker-compose.yml stop        # on rick2
docker compose --env-file .env -f nodes/edge/docker-compose.yml stop web events   # on rick1
gunzip -c /tmp/resgrid-<date>/resgrid.sql.gz | docker compose --env-file .env -f nodes/data/docker-compose.yml exec -T db sh -c 'psql -q -U "$POSTGRES_USER" -d postgres'   # on rick3
./rick.sh cluster start
```

### Upgrade and repair (with internet)

Back up first, then on rick1:

```bash
./rick.sh upgrade
```

`upgrade` gets the newest setup files (`git pull`, or the archive without git) and runs `./setup.sh` again, which then runs `./rick.sh rollout`. Running `./setup.sh` again is always safe: it never replaces a value you set, never rotates a secret and never deletes data. It backs up `.env`, adds the settings new versions need (new secrets get random values, example node addresses become yours), fills in required values that are empty, regenerates `dns/dnsmasq.conf` and missing certificates; `rollout` then copies everything to the nodes, pulls the new images, restarts the kit (the worker migrates the database), asks about new optional features and re-applies yours.

Offline, `RESGRID_NO_PULL=1 ./setup.sh` repairs the configuration and restarts the kit with the images it has.

**Kits configured before October 2026** (three nodes: web, infra, database, with `.env` tracked in git): run `./rick.sh upgrade` on the old web node as above. If your checkout has no `rick.sh upgrade` yet, run `cp .env ~/rick-env && git checkout -- .env && git pull && cp ~/rick-env .env && ./setup.sh`. Setup converts the settings to the four roles (the old web node runs edge and app, so every address stays valid), and `rollout` copies the old database into the data node (once, while the new database is empty; the old database container is stopped, not removed, and a dump is kept in `backups/` on rick3) and stops the old containers on every node so their ports are free.

## Optional services

Optional services run while their profile is listed in `COMPOSE_PROFILES` in `.env` (comma separated), so `start`, `cluster start` and `rollout` keep them running. Add the profile, then `./rick.sh sync && ./rick.sh cluster start`:

- **Virus scanning** (`clamav`, rick4): managed by the virus-scanning feature.
- **Offline maps** (`maps`, rick4): added by `./rick.sh maps-import`.
- **Kit DNS** (`dns`, rick1).
- **GPS trackers** (`tracking`, rick2): also enable `RESGRID__UnitTrackingConfig__*` (ports 5004/5023/5027 TCP+UDP).
- **Inbound email** (`relay`, rick2): SMTP 25; only useful when the kit has a mail path.
- **MCP** (AI assistants) listens on rick2's loopback only.

## Hardening

- Use WPA2/WPA3 with a strong passphrase and change it per deployment; the kit LAN is the security boundary.
- PostgreSQL, Redis, RabbitMQ and RustFS require passwords but listen on the kit LAN (rick1 and rick2 must reach them). For stricter isolation put responders' WiFi on a separate router network (guest/VLAN) that can only reach rick1:443 and the DNS server.
- Keep `.env`, `certs/private/` and backups encrypted when the kit is stored.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `./rick.sh` says no role matches | The node's address isn't one of `RICK_*_HOST` in `.env` (check `ip -4 addr`), or set `RICK_ROLE=edge` etc. |
| A health check fails | Run `./rick.sh status` and `./rick.sh logs <service>` on that node. Containers wait up to 10 minutes for the other nodes, then restart and wait again. |
| Phones can't resolve `rgapi.rick.internal` | Router DNS records missing, or the phone uses a private DNS / VPN (turn off *Private DNS* on Android, iCloud Private Relay / VPNs on iPhone). |
| Browser: certificate error | Install `certs/ca/resgrid-root-ca.crt` on that device, or check the clock on the device and the kit. |
| Android app: "network error" at login | The app doesn't trust the local CA: use a public certificate (`./rick.sh cert`). |
| App logs in but shows no updates | The events hostname must resolve and be trusted too (`rgevents.*`). |
| Web map blank | Maps not imported, or `maps` missing from `COMPOSE_PROFILES` on rick4 (`./rick.sh health` shows map tiles). |
| `exec format error` | Images aren't arm64: see [Images for Raspberry Pi](#images-for-raspberry-pi). |

## Files

| Path | Purpose |
|---|---|
| [setup.sh](setup.sh) | Kit configuration; run again to upgrade and repair it |
| [rick.sh](rick.sh) | Node tool: start/stop/status/logs/health, sync, cluster, rollout, features, upgrade, backup, maps-import, cert, bundle |
| [features/catalog.ini](features/catalog.ini), [lib/features.sh](lib/features.sh) | Optional features: the catalog and the code that applies it (shared by every branch) |
| [os/prepare-node.sh](os/prepare-node.sh) | Raspberry Pi OS preparation |
| [nodes/edge](nodes/edge/docker-compose.yml), [app](nodes/app/docker-compose.yml), [data](nodes/data/docker-compose.yml), [infra](nodes/infra/docker-compose.yml) | Compose file per role |
| [.env.example](.env.example) | Settings template; `setup.sh` writes `.env` |
| [caddy/Caddyfile](caddy/Caddyfile) | HTTPS for all clients, routing to the nodes |
| `certs/`, `dns/` | Local CA, your certificate, kit DNS (generated) |

## License

Apache 2.0, see [LICENSE](LICENSE).
