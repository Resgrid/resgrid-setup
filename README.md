# Resgrid for a Windows laptop or desktop

This branch runs the current Resgrid Core stack on one Windows 10/11 computer with Docker Desktop. It is intended for local development, evaluation, training, or a single-computer field deployment. It is not a high-availability or multi-user production design.

The stack includes the web app, API, event hub, worker and database migrations, PostgreSQL, Redis, RabbitMQ, TTS with RustFS object storage, MCP, and Caddy. GPS tracker ingest and inbound-email dispatch are optional Compose profiles.

All default host-published ports are bound to `127.0.0.1`. Other computers cannot connect unless you intentionally change those bindings and configure the Windows firewall.

## Requirements

- 64-bit Windows 10 or Windows 11 with virtualization enabled.
- Docker Desktop using Linux containers and the WSL2 backend.
- PowerShell 7 or Windows PowerShell 5.1.
- At least 4 CPU cores, 16 GB RAM, and 20 GB free disk space. More is recommended for long-lived data.
- Administrator access once, to edit the Windows hosts file.

## Install

Open PowerShell:

```powershell
git clone --branch laptop https://github.com/Resgrid/resgrid-setup.git resgrid
Set-Location .\resgrid
Set-ExecutionPolicy -Scope Process Bypass
.\setup.ps1
```

The configurator verifies Docker Desktop, generates unique infrastructure passwords and Resgrid encryption keys, creates new OpenIddict signing/encryption certificates, writes `.env`, and starts the stack.

To configure without downloading or starting images:

```powershell
.\setup.ps1 -NoStart
```

Custom local hostnames can be supplied as parameters:

```powershell
.\setup.ps1 `
  -WebHost dispatch.mylocal `
  -ApiHost dispatchapi.mylocal `
  -EventsHost dispatchevents.mylocal
```

WSL2 users may instead run `bash setup.sh`; this branch makes `laptop` the installer's default download branch.

## Add the local hostnames

Open Notepad as Administrator, edit `C:\Windows\System32\drivers\etc\hosts`, and add the line printed by `setup.ps1`. With the defaults it is:

```text
127.0.0.1  rg.mylocal rgapi.mylocal rgevents.mylocal
```

Open each URL once and accept Caddy's local certificate warning:

- `https://rg.mylocal`
- `https://rgapi.mylocal/api/health/getcurrent`
- `https://rgevents.mylocal`

The web app cannot use the API until the browser trusts or accepts the API certificate. You can optionally install Caddy's local root certificate from the `docker-data/caddy/data` directory into the Windows Trusted Root Certification Authorities store.

## First start

The worker creates and migrates four PostgreSQL databases on the first start. This can take several minutes:

```powershell
docker compose ps
docker compose logs -f worker
```

When migration activity settles, open `https://rg.mylocal` and use **Sign Up** to create the first account and department. There is no shared default administrator login.

## Local endpoints

| Service | Local endpoint |
|---|---|
| Web through Caddy | `https://rg.mylocal` |
| Web direct | `http://127.0.0.1:5151` |
| API direct | `http://127.0.0.1:5152` |
| Events direct | `http://127.0.0.1:5153` |
| TTS direct | `http://127.0.0.1:5154` |
| MCP (unauthenticated transport; local only) | `http://127.0.0.1:5155/mcp` |
| RabbitMQ management | `http://127.0.0.1:5160` |

PostgreSQL, Redis, and RabbitMQ's AMQP port are also loopback-only for local diagnostics.

## Optional services

Enable hardware tracker ingest after configuring `RESGRID__UnitTrackingConfig__*` in `.env`:

```powershell
docker compose --profile tracking up -d
```

The tracker ports intentionally listen on the computer's network interfaces so physical devices can reach them. Review Windows firewall rules before enabling the profile.

Enable the inbound-email relay after configuring its department and domain settings:

```powershell
docker compose --profile relay up -d
```

The relay opens host port 25 and accepts unauthenticated SMTP. Keep it behind a firewall or filtering mail server.

## Operations and upgrades

```powershell
docker compose ps
docker compose logs -f
docker compose down
docker compose pull
docker compose up -d
```

Do not delete all Docker images as part of an upgrade. Pulling and recreating this stack is sufficient and does not affect unrelated Docker projects.

Before an upgrade, back up `.env` and the `docker-data` directory. `.env` contains encryption material required to read existing data and tokens. For a consistent database backup:

```powershell
docker compose exec db pg_dumpall -U resgrid | Out-File -Encoding utf8 .\resgrid-backup.sql
```

Rollback is image-based: pin the previous Resgrid image tags in `docker-compose.yml`, restore the matching database backup if the new worker applied incompatible migrations, then run `docker compose up -d`. Keep both the pre-upgrade database dump and `.env` until the upgrade has been verified.

## Important configuration notes

- `.env` in Git contains public template values. Always run `setup.ps1` or `setup.sh` before real use.
- The document store is PostgreSQL (`DocDatabaseType=1`); MongoDB is no longer part of this deployment.
- OSM's public tile server is suitable only for initial testing. Configure an appropriate tile provider for operational use.
- This branch has no redundancy. Copy backups off the laptop, preferably to encrypted removable storage.

See the [Resgrid self-hosted documentation](https://docs.resgrid.com/) for the full environment-variable reference and troubleshooting guidance.
