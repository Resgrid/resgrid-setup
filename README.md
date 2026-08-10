# Resgrid Setup

Easy self-hosted setup for [Resgrid](https://resgrid.com) — the open core computer aided dispatch (CAD), personnel, and unit management system for first responders ([Resgrid Core source](https://github.com/Resgrid/Core)).

This repository contains a Docker Compose stack that runs the complete Resgrid system on a single machine: the web app, API, real-time events hub, background worker, text-to-speech service, MCP server for AI assistants, PostgreSQL, Redis, RabbitMQ, RustFS (S3-compatible object storage), and a Caddy reverse proxy with automatic HTTPS — plus optional add-ons for hardware GPS tracker ingest and inbound-email dispatch.

## Quick install (one line)

On a 64-bit Linux server (or macOS / Windows via WSL2) with [Docker](https://docs.docker.com/engine/install/) installed:

```bash
curl -fsSL https://raw.githubusercontent.com/Resgrid/resgrid-setup/master/setup.sh | bash
```

The installer will:

1. Check prerequisites (Docker, Docker Compose, OpenSSL).
2. Download this repository to `~/resgrid` (or configure in place when run from a checkout).
3. Ask for your three hostnames (web, API, events) and a Let's Encrypt email.
4. Generate random passwords for PostgreSQL, Redis, and RabbitMQ, plus all Resgrid passphrases, encryption keys, and the JWT secret.
5. Generate fresh OpenIddict (OIDC) signing and encryption certificates.
6. Write everything into `.env` and start the stack.

Non-interactive install (for automation) — every prompt can be pre-answered with an environment variable:

```bash
RESGRID_WEB_URL=dispatch.example.com RESGRID_API_URL=dispatchapi.example.com RESGRID_EVENTS_URL=dispatchevents.example.com RESGRID_LETSENCRYPT_EMAIL=you@example.com bash setup.sh
```

Other installer options: `RESGRID_INSTALL_DIR` (install path, default `~/resgrid`), `RESGRID_BRANCH` (repo branch, default `master`), `RESGRID_NO_START=1` (configure but don't start containers).

> **Do not skip the installer for a real deployment.** The template `.env` in this repo contains publicly known default passwords, keys, and certificates. The installer replaces all of them.

## What gets deployed

| Service | Image | Purpose | Host ports |
|---|---|---|---|
| `web` | `resgridllc/resgridwebcore` | Resgrid web application | 5151 |
| `api` | `resgridllc/resgridwebservices` | REST API (used by web app and mobile apps) | 5152 |
| `events` | `resgridllc/resgridwebevents` | Real-time events hub (SignalR) | 5153 |
| `worker` | `resgridllc/resgridworkersconsole` | Background jobs, queue processing, **database migrations** | — |
| `tts` | `resgridllc/resgridwebtts` | Text-to-speech (Piper) for dispatch voice audio | 5154 |
| `mcp` | `resgridllc/resgridwebmcp` | Model Context Protocol server for AI assistants | 5155 (LAN only!) |
| `db` | `dhi.io/postgres:18` | PostgreSQL — databases `resgrid`, `resgridoidc`, `resgridworkers`, `resgriddoc` | 5432 |
| `redis` | `dhi.io/redis:8` | Cache | 6379 |
| `rabbitmq` | `dhi.io/rabbitmq:4.3` | Message bus | 5159 (AMQP), 5160 (management UI) |
| `rustfs` | `rustfs/rustfs` | S3-compatible object storage (TTS audio, internal buckets) | — |
| `caddy` | `dhi.io/caddy:2` | Reverse proxy, automatic HTTPS | 80, 443 |

Optional services, enabled via [Compose profiles](https://docs.docker.com/compose/how-tos/profiles/):

| Service | Image | Profile | Purpose | Host ports |
|---|---|---|---|---|
| `tracker-gateway` | `resgridllc/resgridtrackergateway` | `tracking` | Hardware GPS tracker ingest (Queclink/GT06/Teltonika) | 5004, 5023, 5027 (TCP+UDP) |
| `relay` | `resgridllc/resgridrelay` | `relay` | Inbound email → dispatch (SMTP listener) | 25 |

All infrastructure containers use [Docker Hardened Images](https://docs.docker.com/dhi/) (`dhi.io`). The services run on a fixed Docker network (`172.16.193.0/24`) so containers can reference each other by static IP. Startup ordering is handled with `WAIT_HOSTS` checks — the app containers wait for PostgreSQL, Redis, and RabbitMQ before starting.

The four Resgrid databases are created automatically on first start by [db/create-databases.sh](db/create-databases.sh) (via a custom PostgreSQL entrypoint), and the worker container runs the schema migrations on every startup (`RESGRID__DODBUPGRADE=true` in `.env`). **First start takes several minutes** — watch it with `docker compose logs -f worker`.

Data is persisted on the host under `docker-data/` (PostgreSQL data, Redis dumps, Caddy certificates).

## DNS and HTTPS

Resgrid needs three hostnames, all pointing at this machine, proxied by Caddy ([docker-data/caddy/Caddyfile](docker-data/caddy/Caddyfile)):

- **Web** (default `rg.mylocal`)
- **API** (default `rgapi.mylocal`)
- **Events** (default `rgevents.mylocal`)

Two modes, controlled by the Let's Encrypt email you give the installer:

- **`internal` (default)** — for LAN-only installs. Caddy serves self-signed certificates and browsers will warn; you must accept the warning for **all three** hostnames or the web app can't reach the API. Add the hostnames to the hosts file of every client machine: `SERVER_IP rg.mylocal rgapi.mylocal rgevents.mylocal`.
- **A real email address** — for internet-reachable installs with real DNS records. Caddy obtains and renews Let's Encrypt certificates automatically (ports 80 and 443 must be reachable from the internet).

## Manual setup

If you'd rather not use `setup.sh`:

1. Clone this repository.
2. Edit `.env`:
   - Set the three `NGINX_RESGRID_*_URL` values **and** the matching `RESGRID__SystemBehaviorConfig__*Url` values (they must agree).
   - Set `NGINX_LETSENCRYPT_EMAIL`.
   - Change **every** password, passphrase, and key: `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `RABBITMQ_PASSWORD`, `RUSTFS_ACCESS_KEY`/`RUSTFS_SECRET_KEY` (and their copies inside the Resgrid connection strings / config values below them, including `TtsConfig__S3AccessKey`/`S3SecretKey`), `ExternalLinkUrlParamPassphrase`, `ExternalAudioUrlParamPasshprase`, `ApiTokenEncryptionPassphrase`, `EncryptionKey` (exactly 32 characters), `EncryptionSaltValue`, `SystemApiKey`, `EventsClientSecret`, `PayloadKey`, `TtsConfig__StaticPromptAdminKey`, and `UnitTrackingConfig__CredentialPepper`.
   - Generate new OIDC certificates and paste them into `EncryptionCert` / `SigningCert`:

     ```bash
     openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout enc.key -out enc.crt -subj "/CN=Resgrid OIDC Server Encryption Certificate" -addext "keyUsage=keyEncipherment"
     openssl pkcs12 -export -out enc.pfx -inkey enc.key -in enc.crt -passout pass:
     openssl base64 -A -in enc.pfx    # -> RESGRID__OidcConfig__EncryptionCert
     ```

     Repeat with `keyUsage=digitalSignature` for the signing certificate (`RESGRID__OidcConfig__SigningCert`). The PKCS#12 files must have an **empty password** — Resgrid loads them without one.
3. Start it: `docker compose up -d`
4. Wait for the worker to finish migrating (`docker compose logs -f worker`), then browse to your web URL and use **Sign Up** to create the first account and department.

## Configuration reference

Resgrid is configured entirely through environment variables in `.env`, following the pattern `RESGRID__{ConfigClass}__{FieldName}` (double underscores). They map to the static config classes in `Core/Resgrid.Config` of the [Resgrid Core](https://github.com/Resgrid/Core) codebase. Full reference: <https://docs.resgrid.com/reference/docker>.

Things worth knowing (verified against the Core source):

- **Enum values must be numeric** (`Environment=3`, not `Environment=Dev`). Names silently fail.
- **Misspelled variables are silently ignored** — no startup error. Field names are case-sensitive.
- A few field names contain intentional typos that must be matched exactly: `ExternalAudioUrlParamPasshprase`, `RabbbitPassword` (three b's).
- `RESGRID__DataConfig__CoreConnectionString` must be set (identical to `ConnectionString`) — it is what the data repositories **and the database migration runner** use.
- `RESGRID__DODBUPGRADE` is read only by the worker container and must be the literal string `true` to run migrations at startup.
- The API and events containers must share the same `RESGRID__JwtConfig__EventsClientSecret` (they do automatically, since every container loads the same `.env`).
- Database types: `0` = SQL Server, `1` = PostgreSQL, `2` = MongoDB. This stack uses PostgreSQL (`1`) for everything, including the document database (`DocDatabaseType=1` — no MongoDB container needed).

Frequently changed optional settings:

| Setting | Purpose |
|---|---|
| `RESGRID__SystemBehaviorConfig__Environment` | `0` Production, `1` Staging, `2` QA, `3` Development |
| `RESGRID__MappingConfig__LeafletTileUrl` | Map tile server. The OSM default is for **initial testing only** — see the [OSM tile usage policy](https://operations.osmfoundation.org/policies/tiles/) |
| `RESGRID__MappingConfig__GoogleMapsApiKey` / `GoogleMapsJSKey` | Google geocoding / maps |
| `RESGRID__SystemBehaviorConfig__ErrorLoggerType` | `1` Sentry.io (set the Sentry DSN variables), `2` Console |
| `RESGRID__OutboundEmailServerConfig__*` | SMTP settings (see below) |

## Text-to-speech (TTS) and RustFS

The `tts` container generates dispatch voice audio with [Piper](https://github.com/rhasspy/piper) and stores it in [RustFS](https://rustfs.com), an S3-compatible object store that also serves as general internal bucket storage. The `rustfs-init` one-shot container creates the `resgrid-tts` bucket automatically on first start.

How the pieces connect (all preconfigured in `.env`):

- The API and worker call TTS internally via `RESGRID__TtsConfig__ServiceBaseUrl` (`http://172.16.193.58:8080`).
- Twilio fetches playback audio from `RESGRID__TtsConfig__PlaybackBaseUrl` — Caddy routes `/tts/audio/*` on your **API hostname** to the TTS container, so no extra hostname is needed. This only matters if you use Twilio voice; otherwise TTS is fully internal.
- `S3UsePresignedUrls=false` keeps RustFS off the public internet: TTS proxies the audio itself.
- RustFS credentials (`RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY`) are generated by the installer and mirrored into `RESGRID__TtsConfig__S3AccessKey/S3SecretKey`. RustFS is not published on a host port by default (uncomment the port mapping in [docker-compose.yml](docker-compose.yml) if you want the S3 API/console on the host).

## MCP server (AI assistants)

The `mcp` container exposes a [Model Context Protocol](https://modelcontextprotocol.io) endpoint (`POST /mcp` on host port 5155) so AI assistants like Claude can interact with your Resgrid system. Users authenticate *inside* the protocol with their Resgrid credentials (login tool → OAuth against the API).

> **Security:** the MCP HTTP endpoint itself is **unauthenticated**. Keep port 5155 on your LAN/VPN — do not port-forward it to the internet or put it behind Caddy without adding an auth layer.

## GPS tracker gateway (optional, profile `tracking`)

The `tracker-gateway` container accepts direct TCP/UDP connections from hardware GPS trackers: Queclink (5004), GT06 (5023), Teltonika (5027). Trackers dial in over raw sockets, so these ports must be reachable from the trackers (port-forward or L4 load balancer — an HTTP proxy won't work). Do **not** expose its internal health port (8080).

To enable, edit the Unit Tracking section of `.env` — set `Enabled=true`, `NativeGatewayEnabled=true`, and at least one protocol (e.g. `EnableTeltonika=true`); `CredentialPepper` is generated by the installer (changing it later invalidates enrolled devices). Then:

```bash
docker compose --profile tracking up -d
```

## Inbound email dispatch relay (optional, profile `relay`)

The `relay` container ([Resgrid Relay](https://github.com/Resgrid/Relay)) runs an SMTP listener that turns inbound email into Resgrid dispatches: mail to `{dispatchcode}@dispatch.yourdomain` creates a call for the department, `{groupcode}@groups.yourdomain` dispatches a group. Duplicate messages are suppressed for 72 hours.

Setup:

1. The installer pre-wires auth: it generates a system API key shared between `RESGRID__SecurityConfig__SystemApiKey` (Core) and `RESGRID__RELAY__Resgrid__SystemApiKey` (relay), and points the relay at the internal API.
2. In `.env`, set `RESGRID__RELAY__Resgrid__DepartmentId` (your department id, visible in the web app after signup) and check the dispatch domain (`RESGRID__RELAY__Smtp__DepartmentAddressDomains__0`, default `dispatch.<your web hostname>`).
3. Point the **MX record** of that dispatch domain at this host. Host port 25 maps into the relay.
4. Start it:

```bash
docker compose --profile relay up -d
```

> **Security:** the relay accepts any sender — no TLS, no SMTP auth, no SPF/DKIM checks; the only gate is the recipient domain list. For internet-facing setups restrict port 25 by firewall to your upstream MTA, or put a filtering mail server in front.

## Outbound email

Resgrid sends email (invites, password resets, dispatch notifications). The stack does **not** include an outbound mail server — point the `RESGRID__OutboundEmailServerConfig__*` variables in `.env` at your SMTP server or relay (SendGrid, SES, a corporate relay, etc.), or set `OutboundEmailType=0` and use [Postmark](https://postmarkapp.com).

If you want to run your own mail server, [mailserver.env](mailserver.env) is a ready-made configuration for [docker-mailserver](https://docker-mailserver.github.io/docker-mailserver/edge/) you can add as an additional compose service (persist its state under `docker-data/dms/`, which is already scaffolded).

## Operations

```bash
docker compose ps                        # status
docker compose logs -f [service]         # logs (web, api, events, worker, db, redis, rabbitmq, caddy)
docker compose down                      # stop
docker compose pull && docker compose up -d   # upgrade to latest images (worker re-runs migrations)
```

**Backup**: back up `.env` (contains all secrets — without it, encrypted data and logins are unrecoverable) and the `docker-data/` directory (PostgreSQL, Redis, Caddy certs, RustFS buckets). For consistent database backups prefer `docker compose exec db pg_dumpall -U <POSTGRES_USER>` over copying `docker-data/sql` while running. The relay's dedupe store lives in the `relay-data` named volume (safe to lose — worst case a duplicate email redispatches within 72h).

**Troubleshooting**:

- *Web app loads but nothing works / login fails* — the API or events hostname isn't reachable from your browser, or (internal mode) you haven't accepted the self-signed certificate warning for the API and events hostnames.
- *Containers restart-loop on first boot* — normal for a minute or two while waiting for PostgreSQL/RabbitMQ; check `docker compose logs -f worker` for migration progress.
- *Ports 80/443 already in use* — stop the conflicting service or edit the `caddy` ports in [docker-compose.yml](docker-compose.yml).
- *`db` scripts fail with `\r: not found`* — the shell scripts were checked out with Windows line endings. This repo's `.gitattributes` prevents that; re-clone or run `git checkout -- db/`.

## Repository layout

| Path | Purpose |
|---|---|
| [setup.sh](setup.sh) | One-line installer: prompts, secret generation, `.env` writing, startup |
| [docker-compose.yml](docker-compose.yml) | The full stack definition |
| [.env](.env) | All configuration — template defaults, populated by `setup.sh` |
| [db/](db) | PostgreSQL entrypoint + database creation scripts |
| [docker-data/](docker-data) | Persistent data (PostgreSQL, Redis, Caddy certs) and the [Caddyfile](docker-data/caddy/Caddyfile) |
| [mailserver.env](mailserver.env) | Optional docker-mailserver configuration |

## License

See [LICENSE](LICENSE). Resgrid Core is open source under the Apache 2.0 license.
