# Resgrid Setup

Self-hosted installers for [Resgrid](https://resgrid.com), the open-core computer-aided dispatch (CAD), personnel and unit management system for first responders ([Resgrid Core source](https://github.com/Resgrid/Core)).

Each branch of this repository is a complete, tested deployment for one situation:

| Branch | For | Runs on | Network |
|---|---|---|---|
| **`master`** (this branch) | A department or agency server | One 64-bit Linux server with Docker | LAN or internet |
| [`laptop`](https://github.com/Resgrid/resgrid-setup/tree/laptop) | One person on one Windows computer, e.g. training, a command post laptop, a disconnected field deployment | Windows 10/11 + Docker Desktop | Fully offline after setup, local browser only |
| [`multi`](https://github.com/Resgrid/resgrid-setup/tree/multi) | Production, several servers, scaling and redundancy | Kubernetes or k3s cluster | LAN or internet |
| [`rick`](https://github.com/Resgrid/resgrid-setup/tree/rick) | Resgrid Incident Command Kit: a portable, battery-powered kit for a base camp or command vehicle | 4 × Raspberry Pi 5 + WiFi hotspot router | Fully offline; responders' phones join the hotspot |

Step-by-step guides with screenshots: <https://docs.resgrid.com/self-hosted/installation>.

---

## What you get

A single Docker Compose stack with every Resgrid service plus the infrastructure it needs:

| Service | Image | Purpose | Port on the server |
|---|---|---|---|
| `caddy` | `dhi.io/caddy` | HTTPS for the three Resgrid hostnames (automatic certificates) | 80, 443 |
| `web` | `resgridllc/resgridwebcore` | Web application | 5151 |
| `api` | `resgridllc/resgridwebservices` | REST API used by the web app and the mobile apps; also the login (OpenID Connect) server | 5152 |
| `events` | `resgridllc/resgridwebevents` | Real-time updates (SignalR) | 5153 |
| `worker` | `resgridllc/resgridworkersconsole` | Background jobs, notifications and the **database schema migrations** | — |
| `tts` | `resgridllc/resgridwebtts` | Text-to-speech for dispatch audio | 5154 |
| `mcp` | `resgridllc/resgridwebmcp` | Model Context Protocol server for AI assistants | 5155 (keep on your LAN) |
| `db` | `dhi.io/postgres:18` | PostgreSQL: databases `resgrid`, `resgridoidc`, `resgridworkers`, `resgriddoc` | 127.0.0.1:5432 |
| `redis` | `dhi.io/redis:8` | Cache, SignalR backplane, ASP.NET data-protection keys | — |
| `rabbitmq` | `dhi.io/rabbitmq:4.3` | Message bus | 127.0.0.1:5160 (management UI) |
| `rustfs` | `rustfs/rustfs` | S3-compatible object storage (TTS audio, imports) | — |
| `db-init`, `rustfs-init`, `caddy-init` | | One-shot jobs: create databases, buckets, load the local CA key | — |

Optional services ([Compose profiles](https://docs.docker.com/compose/how-tos/profiles/)):

| Profile | Service | Purpose |
|---|---|---|
| `maps` | `tileserver` | Offline OpenStreetMap tiles for the web map ([Offline maps](#offline-maps)) |
| `tracking` | `tracker-gateway` | Hardware GPS trackers (Queclink 5004, GT06 5023, Teltonika 5027, TCP+UDP) |
| `relay` | `relay` | Inbound email to dispatch (SMTP on port 25) |
| `clamav` | `clamav` | Virus scanning of uploaded files ([Optional features](#optional-features)) |

The profiles in use are listed in `COMPOSE_PROFILES` in `.env`. Docker Compose reads that setting itself, so `docker compose up -d` keeps them running; setup and the map import maintain the list.

All data lives in Docker named volumes (`resgrid_postgres-data`, `resgrid_rustfs-data`, …), so `docker compose down` and upgrades never delete it.

## Requirements

- A 64-bit Linux server (Ubuntu Server 24.04 LTS or Debian 12/13 recommended). macOS and Windows work through Docker Desktop/WSL2 for testing.
- [Docker Engine](https://docs.docker.com/engine/install/) with the Compose v2 plugin, `openssl`, `git` (or `curl`).
- 4 CPU cores, 8 GB RAM and 40 GB of disk at minimum; 16 GB RAM recommended. The whole stack idles at about 1 GB of RAM.
- Three hostnames that resolve to the server: web, API and events (for example `dispatch.example.com`, `dispatchapi.example.com`, `dispatchevents.example.com`).
- Internet access during installation to download the images (about 6 GB).

The infrastructure images are [Docker Hardened Images](https://docs.docker.com/dhi/) from `dhi.io`. If a pull fails with an authorization error run `docker login dhi.io`; if Docker Hub answers `429 Too Many Requests`, run `docker login` (anonymous pulls are rate-limited).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Resgrid/resgrid-setup/master/setup.sh | bash
```

or from a clone:

```bash
git clone https://github.com/Resgrid/resgrid-setup.git ~/resgrid
cd ~/resgrid
./setup.sh
```

The installer:

1. Checks for Docker, Compose and OpenSSL.
2. Downloads this repository to `~/resgrid` (or uses the clone you ran it from).
3. Asks for the three hostnames and how to get HTTPS certificates (see below).
4. Copies `.env.example` to `.env` and generates every password, passphrase, encryption key and the JWT secret.
5. Creates the OpenID Connect signing and encryption certificates and Resgrid's local certificate authority (`certs/`).
6. Pulls the images, starts the stack and waits until the web app and API answer.
7. Walks you through the [optional features](#optional-features) (Records, Search, Chat, ...).

The first start takes 5–10 minutes: the `worker` container creates and migrates the database. Follow it with `docker compose logs -f worker`.

Unattended install (every prompt has a variable):

```bash
RESGRID_WEB_HOST=dispatch.example.com \
RESGRID_API_HOST=dispatchapi.example.com \
RESGRID_EVENTS_HOST=dispatchevents.example.com \
RESGRID_TLS=admin@example.com \
RESGRID_FEATURES=records,search \
bash setup.sh
```

Other variables: `RESGRID_INSTALL_DIR` (default `~/resgrid`), `RESGRID_BRANCH`, `RESGRID_HTTP_PORT` / `RESGRID_HTTPS_PORT` (when 80/443 are taken), `RESGRID_TLS_CERT_FILE` + `RESGRID_TLS_KEY_FILE` (your own certificate), `RESGRID_NONINTERACTIVE=1` (never ask), `RESGRID_NO_PULL=1` (use the images already on the server), `RESGRID_NO_START=1` (configure only).

> **Never run a real system on the values in `.env.example`.** They are public placeholders; the installer replaces all of them.

### Hostnames and HTTPS

Browsers and the mobile apps talk to all three hostnames, so every one must resolve to the server and present a certificate the client trusts. Pick one TLS mode:

| `RESGRID_TLS` | Use when | What clients need |
|---|---|---|
| your email address | The server is reachable from the internet on ports 80 and 443 with public DNS records | Nothing: Caddy gets and renews Let's Encrypt certificates |
| `internal` (default) | LAN-only or offline installs | Install `certs/ca/resgrid-root-ca.crt` as a trusted root on every computer and iPhone (see below) |
| `/certs/site/fullchain.pem /certs/site/privkey.pem` | You already have a certificate (corporate CA, wildcard, DNS-01) | Copy the PEM files to `certs/site/`; clients need whatever trusts that certificate |

For LAN installs without DNS, add one line to the hosts file of each client (`C:\Windows\System32\drivers\etc\hosts` or `/etc/hosts`), or create the records on your router:

```text
192.168.1.50  rg.mylocal rgapi.mylocal rgevents.mylocal
```

#### Trusting the local CA (`RESGRID_TLS=internal`)

`certs/ca/resgrid-root-ca.crt` is one certificate that covers all three hostnames (Caddy issues short-lived site certificates from it and renews them itself). Install it once per device:

- **Windows**: double-click the file, *Install Certificate*, *Local Machine*, *Place all certificates in the following store*, *Trusted Root Certification Authorities*.
- **macOS**: double-click, then in Keychain Access open the certificate and set *When using this certificate* to *Always Trust*.
- **iPhone/iPad**: AirDrop or email the file, install the profile in Settings, then enable it under *Settings > General > About > Certificate Trust Settings*.
- **Android**: *Settings > Security > Encryption & credentials > Install a certificate > CA certificate*. This works for browsers; the Resgrid Responder and Unit apps on Android only trust public certificates, so use Let's Encrypt or your own certificate if Android phones must use the apps.
- **Linux**: `sudo cp resgrid-root-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`.

The Resgrid containers already trust this CA (`SSL_CERT_DIR` in `.env`), so server-to-server calls through Caddy work without disabling certificate checks.

## First login

Open `https://<web hostname>` and choose **Sign Up**. Sign Up creates your user account and your department; you are its administrator. There is no default administrator account.

Self-hosted sign up is enabled by `RESGRID__SystemBehaviorConfig__AllowSignupWithoutBilling=true` in `.env`. After you have created your department, set it to `false` and run `docker compose up -d` so nobody else can create departments on your server; add people with **Personnel > Add Person** or invitations instead.

Then follow the [department setup guide](https://docs.resgrid.com/configuration/setup) (stations, units, roles, statuses).

### Mobile apps

The Resgrid **Responder** and **Unit** apps work against your server: on the login screen tap **Change Server URL** (Responder) or **Server URL** (Unit), choose **Custom** and enter `https://<API hostname>` (no path). See [Connecting the apps](https://docs.resgrid.com/self-hosted/apps) for details and limitations: push notifications are not configured on a self-hosted server (they need a Novu instance plus Firebase/APNs credentials for the apps, `RESGRID__ChatConfig__Novu*`), so the apps receive dispatches in real time while they are open.

## Optional features

Resgrid ships several modules behind feature flags that are off on a new server. Setup asks about each one at the end of the install, and you can change them any time:

```bash
./setup.sh features         # walk through the optional features
./setup.sh features --all   # also offer flags that no feature in the catalog covers
```

```text
==> Optional features
    Resgrid ships some modules switched off. Answer y to turn a feature on for
    every department on this server, n to turn it off; Enter takes the answer
    in brackets. Run this again any time with: ./setup.sh features

  [1/10] Records (RMS)  (now: off)
        Incident and field records (replaces Logs), records in the Responder, Unit and Dispatch apps,
        prevention (occupancy, inspections, hydrants, permits, community risk reduction),
        investigations, quality review and records analytics.
        After switching it on, a department administrator activates Records in the department settings.
        Turn on Records (RMS)? (y/n) [n]: y
```

One question covers everything a feature needs. Records, for example, is 13 feature flags that only make sense together. When a feature needs a setting or an extra service, setup takes care of that too:

| Feature | Name | What setup changes |
|---|---|---|
| Records (RMS) | `records` | Every `Records.*` flag. A department administrator then activates Records in the department settings. Suggests Unified search. |
| Unified search | `search` | `Search.Unified`, and `RESGRID__SearchConfig__*` (the index is kept in the RustFS bucket `resgrid-search`) |
| Chat | `chat` | `Chat.System` |
| Run cards | `runcards` | Run cards, station dispatching, closest unit, move-up and conditional run cards (`Dispatch.*`) |
| Checklists | `checklists` | `Checklists.System` |
| Deployments | `deployments` | `Operations.Deployments` |
| Setup wizard and admin guidance | `setup-wizard` | `Admin.Setup`, `Admin.Assist` |
| Department import and migration | `import` | Spreadsheet and CAD/RMS imports (`Onboarding.*`). Suggests virus scanning. |
| Attachment virus scanning | `scanning` | Starts the `clamav` container (profile `clamav`, about 1.5 GB of RAM) and sets `RESGRID__AttachmentScanningConfig__Enabled=true` |
| Text-message commands (Twilio) | `twilio-text` | `Chatbot.TwilioTextIntegration`, and asks for the `RESGRID__NumberProviderConfig__Twilio*` settings. Needs internet access. |

Resgrid's paid add-ons (Enhanced AI, Workforce and Business Operations, Incident Back Office, Readiness Pro work orders, Advanced Data Protection) depend on Resgrid's hosted billing; setup lists them but doesn't offer them.

A feature is switched on or off for every department on the server (the `featureflags` table of the `resgrid` database), and setup clears the flag cache in Redis so the change shows on the next page load. Without questions: `RESGRID_FEATURES=records,search,chat ./setup.sh features` (or `all`, or `none`); features not listed are switched off.

Setup remembers your choices in `.env`: `RESGRID_FEATURES` (the features that are on) and `RESGRID_FEATURES_OFFERED` (the ones it has asked about). When you run setup again after an upgrade it:

- asks only about the features that are new in that version (otherwise a single "Change the optional features?" question);
- switches a feature you turned on fully back on when its flags are off or only partly on, for example after restoring a database, or when a new Core version adds a flag to that feature.

### Maintaining the feature list

The questions come from [`features/catalog.ini`](features/catalog.ini), which `lib/features.sh` reads (the laptop branch's `scripts/features.ps1` reads the same file). Adding, grouping or retiring a feature is an edit to that file, and the same catalog is used on every branch:

```ini
[records]
title=Records (RMS)
about=Incident and field records (replaces Logs), ...
category=Records
recommends=search
```

| Key | Meaning |
|---|---|
| `title=`, `about=` | The question and its explanation (`about=` may repeat for several lines) |
| `flags=` | Flag keys, space separated |
| `category=` / `exclude=` | Every flag of a category, including flags Core adds later, except the listed keys |
| `requires=` / `recommends=` | Other sections switched on with this one / suggested ("y" as the default answer) |
| `setting=KEY=value` / `off=KEY=value` | `.env` values written when the feature is switched on / off; `{OTHER_KEY}` copies another setting |
| `ask=KEY\|question\|default` | A value to ask for when the feature is switched on |
| `profile=` | Compose profile that runs while the feature is on |
| `online=yes` | Shown as needing internet access |
| `available=no` | Listed as a hosted-only add-on, never switched |

Flags that Core no longer has are skipped, and a section with no flags in the database isn't shown, so an older catalog keeps working with a newer Core. When Core retires a feature for good, delete its section.

## Configuration

Everything is configured in `.env`. Resgrid settings use the pattern `RESGRID__{ConfigClass}__{FieldName}` and map to the static classes in [`Core/Resgrid.Config`](https://github.com/Resgrid/Core/tree/master/Core/Resgrid.Config). Full reference: <https://docs.resgrid.com/reference/docker>. After changing `.env`, run `docker compose up -d` (Compose recreates the affected containers).

Things worth knowing (all verified against the Core source):

- Names are **case-sensitive** and **misspelled names are silently ignored**. Some field names are misspelled in Core and must stay that way: `ExternalAudioUrlParamPasshprase`, `RabbbitPassword`.
- **Enum values must be numbers** (`Environment=0`, not `Production`).
- `RESGRID__ApiConfig__BackendInternalApikey` is required (the web app uses it to get API tokens for chat, messages, maps and the events connection).
- `RESGRID__ApiConfig__BypassSslChecks` must stay `false`; Core refuses to start with `true` in production.
- `RESGRID__DataConfig__CoreConnectionString` must equal `ConnectionString`; the repositories and the migration runner use it.
- `RESGRID__SecurityConfig__EncryptionKey` must be exactly 32 characters. Changing it, the salt, or the OIDC certificates after install makes encrypted data unreadable and signs everyone out.
- PostgreSQL is used for every database (`DatabaseType=1`, `DocDatabaseType=1`); MongoDB and SQL Server are not needed.

Frequently changed settings:

| Setting | Purpose |
|---|---|
| `RESGRID__OutboundEmailServerConfig__*` | SMTP server for invitations, password resets and notifications. No mail server is included. Or set `RESGRID__SystemBehaviorConfig__OutboundEmailType=0` and a Postmark key. |
| `RESGRID__MappingConfig__LeafletTileUrl` | Web map tiles. The OSM default is for testing only ([tile usage policy](https://operations.osmfoundation.org/policies/tiles/)); use a tile provider or [offline maps](#offline-maps). |
| `RESGRID__MappingConfig__GoogleMapsApiKey` / `GoogleMapsJSKey` / `What3WordsApiKey` | Optional geocoding providers |
| `RESGRID__MappingConfig__ResponderAppMapboxKey` / `UnitAppMapBoxKey` | Map tiles in the mobile apps (they use Mapbox) |
| `RESGRID__WebConfig__RecaptchaPublicKey` / `RecaptchaPrivateKey` | reCAPTCHA on Sign Up / Forgot Password for internet-facing servers |
| `RESGRID__SystemBehaviorConfig__ErrorLoggerType` | `2` console logs (default), `1` Sentry (fill in the Sentry DSNs) |

## Offline maps

The `maps` profile runs an OpenStreetMap tile server on your server, so the web map works without internet or a commercial tile provider. Import the area you need once (while online), pick the smallest extract that covers it from [Geofabrik](https://download.geofabrik.de):

```bash
./maps/import.sh https://download.geofabrik.de/north-america/us/nevada-latest.osm.pbf
```

The script imports the region (10–60 minutes for a US state), starts the tile server, and points `RESGRID__MappingConfig__LeafletTileUrl` at `https://<web hostname>/tiles/{z}/{x}/{y}.png`. Tiles render on first view and are cached. The script also adds `maps` to `COMPOSE_PROFILES` in `.env`, so the tile server starts with the rest of the stack from then on.

## GPS trackers (profile `tracking`)

Set `RESGRID__UnitTrackingConfig__Enabled=true`, `NativeGatewayEnabled=true` and at least one protocol (`EnableQueclink`, `EnableGt06`, `EnableTeltonika`) in `.env`, add `tracking` to `COMPOSE_PROFILES` (comma separated, e.g. `COMPOSE_PROFILES=tracking`), then:

```bash
docker compose up -d
```

Trackers connect to raw TCP/UDP ports 5004 (Queclink), 5023 (GT06) and 5027 (Teltonika); forward those ports (an HTTP proxy won't work). `CredentialPepper` is generated by the installer; changing it later invalidates enrolled devices.

## Inbound email dispatch (profile `relay`)

The [Resgrid Relay](https://github.com/Resgrid/Relay) turns email into dispatches: mail to `{dispatchcode}@dispatch.<web hostname>` creates a call. The installer already shares a system API key between Core and the relay.

1. In `.env` set `RESGRID__RELAY__Resgrid__DepartmentId` (your department id) and check `RESGRID__RELAY__Smtp__DepartmentAddressDomains__0`.
2. Point the MX record of that domain at the server (host port 25).
3. Add `relay` to `COMPOSE_PROFILES` in `.env` and run `docker compose up -d`.

> The relay accepts any sender: no TLS, no SMTP authentication, no SPF/DKIM checks. Firewall port 25 to your upstream mail server, or put a filtering mail server in front of it.

## MCP server (AI assistants)

`mcp` exposes a [Model Context Protocol](https://modelcontextprotocol.io) endpoint at `http://<server>:5155/mcp`. Users log in with their Resgrid credentials inside the protocol, but the HTTP endpoint itself is **unauthenticated**: keep port 5155 on your LAN or VPN.

## Operations

```bash
cd ~/resgrid
docker compose ps                      # status
docker compose logs -f worker          # logs (web, api, events, worker, caddy, db, ...)
docker compose restart api             # restart one service
docker compose down                    # stop everything (data is kept)
docker compose up -d                   # start again
```

### Upgrade and repair

Running the installer again is the upgrade, and it is safe to run any time:

```bash
cd ~/resgrid && ./setup.sh upgrade        # git pull, then everything below
```

or the one-liner you installed with, which finds the install in `~/resgrid` and updates it:

```bash
curl -fsSL https://raw.githubusercontent.com/Resgrid/resgrid-setup/master/setup.sh | bash
```

On an existing install, setup never replaces a value you set, never rotates a secret your data depends on and never deletes data. It:

1. Updates the setup files (`git pull`, or the archive download without git). When `setup.sh` itself changed, the new version takes over.
2. Backs up `.env` (`.env.backup-<date>`), adds the settings introduced since you installed (new secrets get random values), fills in required values that are empty and fixes values known to break (old container IP addresses, `BypassSslChecks=true`, ...).
3. Recreates generated files that are missing (local CA, OpenID Connect certificates).
4. Keeps the data of an older version (next sections).
5. Pulls the new images (images it can't download, for example while offline, are skipped; `RESGRID_NO_PULL=1` skips pulling), starts new services, removes retired ones and restarts the stack. The worker migrates the database.
6. Asks about optional features that are new in this version and re-applies the ones you turned on.

Back up first (below): rolling back after a database migration means restoring the backup that matches the older images. After pulling a new version, run `./setup.sh` rather than a bare `docker compose up -d`, so these steps happen.

### Backup and restore

Back up three things: the database, `.env` (all secrets; without it encrypted data and logins are unrecoverable) and `certs/`.

```bash
mkdir -p backups
docker compose exec -T db sh -c 'pg_dumpall -U "$POSTGRES_USER" --clean --if-exists' | gzip > backups/resgrid-$(date +%F).sql.gz
cp .env backups/env-$(date +%F) && tar -czf backups/certs-$(date +%F).tar.gz certs
```

Restore onto an install that uses the same `.env` and `certs/`:

```bash
docker compose stop web api events worker tts mcp
gunzip -c backups/resgrid-2026-10-27.sql.gz | docker compose exec -T db sh -c 'psql -q -U "$POSTGRES_USER" -d postgres'
docker compose up -d
```

Uploaded files and TTS audio live in the `resgrid_rustfs-data` volume; back it up with `docker run --rm -v resgrid_rustfs-data:/data -v "$PWD/backups":/backup alpine tar -czf /backup/rustfs-$(date +%F).tar.gz -C /data .`.

### Upgrading an install created before October 2026

Use `./setup.sh upgrade` or the one-liner, as above. Setup recognizes the old layout:

- `.env` was tracked in git: it's set aside during the `git pull` and put back.
- The `NGINX_*` settings become `RESGRID_WEB_HOST` / `RESGRID_API_HOST` / `RESGRID_EVENTS_HOST` / `RESGRID_TLS`, and the fixed container IP addresses become service names.
- Data in `docker-data/sql` (installs up to April 2025, PostgreSQL 17) is copied into the new PostgreSQL 18 database, once and only while the new database is empty, so nothing is overwritten. The folder isn't changed and a dump is kept in `backups/legacy-db-*.sql.gz`. The copy runs the old PostgreSQL version's image, so it needs internet access; `RESGRID_MIGRATE_LEGACY_DB=0` skips it.
- A database container of the old stack is stopped and its data directory saved to `backups/legacy-pgdata-*.tar` before anything can recreate it. Old containers under a different Compose project name are stopped (not removed) so their ports are free; remove them once the new version works.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Browser shows a certificate warning | `internal` TLS: install `certs/ca/resgrid-root-ca.crt` on that device. Accepting the warning for the web hostname only is not enough; the web app also calls the API and events hostnames. |
| Web app loads but login, chat or maps fail | The API or events hostname doesn't resolve on that client, or isn't trusted. Check all three hostnames from the client. |
| Containers restart for a minute on first start | Normal while PostgreSQL, RabbitMQ and the migrations come up. `docker compose logs -f worker` shows progress. |
| `Bind for 0.0.0.0:80 failed: port is already allocated` | Another web server uses 80/443. Stop it, or set `RESGRID_HTTP_PORT`/`RESGRID_HTTPS_PORT` in `.env` (the public URLs must then include the HTTPS port) and run `docker compose up -d`. |
| `429 Too Many Requests` while pulling | Docker Hub's anonymous limit. Run `docker login` and retry. |
| api/web/events log `BypassSslChecks` errors and exit | Set `RESGRID__ApiConfig__BypassSslChecks=false` (`./setup.sh upgrade` does it). |
| Sign Up sends you back to the login page | `RESGRID__SystemBehaviorConfig__AllowSignupWithoutBilling` is not `true`, or `RESGRID__ApiConfig__BackendInternalApikey` is empty. |
| Worker logs `transient_nonexcl_queues is deprecated` | RabbitMQ 4 without `rabbitmq/rabbitmq.conf` mounted. Use this repository's `docker-compose.yml`. |
| Worker logs `ConstraintExists is not supported by the connectionless processor` | `RESGRID__DataConfig__CoreConnectionString` is empty. Set it to the same value as `ConnectionString`. |
| `Keyword not supported: 'host'` | A PostgreSQL connection string read as SQL Server: set `DatabaseType=1` (and `DocDatabaseType`, `OidcConfig__DatabaseType`, `WorkerConfig__DatabaseType`). |

## Repository layout

| Path | Purpose |
|---|---|
| [setup.sh](setup.sh) | Installer, upgrader and repair (`./setup.sh`, `./setup.sh upgrade`), optional features (`./setup.sh features`) |
| [features/catalog.ini](features/catalog.ini) | The optional features setup offers, and the feature flags and settings behind each |
| [lib/features.sh](lib/features.sh) | Reads the catalog, asks, switches flags and settings (shared by every branch) |
| [docker-compose.yml](docker-compose.yml) | The stack |
| [.env.example](.env.example) | Configuration template; `setup.sh` writes `.env` from it (git-ignored) |
| [caddy/Caddyfile](caddy/Caddyfile) | Reverse proxy and HTTPS |
| [db/create-databases.sh](db/create-databases.sh) | Creates the four databases (run by `db-init`) |
| [rabbitmq/](rabbitmq) | Enables the management UI and the transient queues Resgrid uses |
| [maps/import.sh](maps/import.sh) | Offline map import |
| `certs/` | Local CA (`ca/`, `private/`) and your own certificate (`site/`); generated, git-ignored |
| [mailserver.env](mailserver.env) | Optional [docker-mailserver](https://docker-mailserver.github.io/docker-mailserver/edge/) configuration if you want to run your own SMTP server |

## License

Apache 2.0, see [LICENSE](LICENSE). Resgrid Core is open source under the Apache 2.0 license.
