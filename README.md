# Resgrid on a Windows laptop (offline)

This branch runs the complete Resgrid system on **one Windows 10/11 computer** with Docker Desktop. After a one-time setup while online, it runs **fully offline**: one person uses Resgrid in a browser on the same computer, for example on a command post laptop, at a disconnected incident, for training, or to evaluate Resgrid.

- Every port is bound to `127.0.0.1`: other computers and phones can't reach it. For a shared server use the [`master`](https://github.com/Resgrid/resgrid-setup/tree/master) branch; for a portable multi-user kit with phones use [`rick`](https://github.com/Resgrid/resgrid-setup/tree/rick).
- Hostnames end in `.localhost` (`rg.localhost`, `rgapi.localhost`, `rgevents.localhost`): Chrome, Edge and Firefox resolve them to this computer, so **no hosts-file edit and no administrator rights** are needed.
- HTTPS comes from a local certificate authority that setup creates and trusts for your Windows account.
- Maps work offline once you import your area ([Offline maps](#offline-maps)).

Guide with screenshots: <https://docs.resgrid.com/self-hosted/laptop>.

## What runs

Web app, API, events hub, worker (database migrations and background jobs), text-to-speech, MCP, PostgreSQL, Redis, RabbitMQ, RustFS object storage and Caddy, about 1 GB of RAM when idle. Optional: offline map tiles (`maps`), GPS tracker gateway (`tracking`), inbound email relay (`relay`).

## Requirements

- Windows 10 22H2 or Windows 11, 64-bit, with virtualization enabled in the BIOS/UEFI.
- [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/) with the WSL 2 backend and **Linux containers** (the default). Docker Desktop is free for personal use, education and small businesses; larger organizations need a paid subscription.
- 4 CPU cores, 8 GB RAM (16 GB recommended), 25 GB free disk (plus 5–20 GB for offline maps).
- Windows PowerShell 5.1 (built in) or PowerShell 7.
- Internet access during setup (about 6 GB of downloads).

## Install

1. Install Docker Desktop, start it and wait until it shows **Engine running**. In Docker Desktop **Settings > General**, turn on **Start Docker Desktop when you sign in to your computer** so Resgrid starts with Windows.
2. Open PowerShell and download this branch:

   ```powershell
   git clone --branch laptop https://github.com/Resgrid/resgrid-setup.git $HOME\resgrid
   cd $HOME\resgrid
   ```

   No git? Download <https://github.com/Resgrid/resgrid-setup/archive/refs/heads/laptop.zip>, extract it to `%USERPROFILE%\resgrid`, then in PowerShell run `cd $HOME\resgrid; Get-ChildItem -Recurse | Unblock-File`.

3. Run setup:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\setup.ps1
   ```

   To import an offline map at the same time, add your area's [Geofabrik](https://download.geofabrik.de) extract:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\setup.ps1 -MapRegion https://download.geofabrik.de/north-america/us/nevada-latest.osm.pbf
   ```

   Setup checks Docker Desktop, picks free ports (8443 and 8080, or the next free ones, if IIS or another program uses 443/80), generates every password, key and certificate into `.env`, creates the local certificate authority, asks Windows to trust it (**answer Yes** in the security prompt), downloads the images and starts Resgrid. The first start takes 5–10 minutes while the database is created. Setup then walks you through the [optional features](#optional-features) and opens Resgrid in your browser.

4. In the browser choose **Sign Up** to create your account and your department. You are its administrator.

Setup options: `-WebHost`, `-ApiHost`, `-EventsHost` (other hostnames; names not ending in `.localhost` need a hosts-file line, which setup prints), `-HttpPort` / `-HttpsPort`, `-NoTrustCa` (don't touch the Windows certificate store), `-Features records,search` (optional features without questions; `all` or `none`), `-NonInteractive` (never ask), `-NoPull` (use the images already on the laptop), `-NoStart`, `-NoBrowser`.

Firefox: if Firefox still warns about the certificate, open `about:config` and set `security.enterprise_roots.enabled` to `true` (Firefox then uses the Windows trust store).

## Everyday use

Use `resgrid.ps1` from the install folder (`cd $HOME\resgrid` first):

```powershell
.\resgrid.ps1 open              # open Resgrid in the browser
.\resgrid.ps1 status            # what's running
.\resgrid.ps1 stop              # stop (data is kept)
.\resgrid.ps1 start             # start again
.\resgrid.ps1 logs worker       # follow a service's log
.\resgrid.ps1 backup            # backup to backups\resgrid-<date>.zip
.\resgrid.ps1 features          # turn optional features on or off
```

If PowerShell refuses to run scripts, use `powershell -ExecutionPolicy Bypass -File .\resgrid.ps1 <command>`.

Resgrid starts automatically with Docker Desktop. Its address is `https://rg.localhost` (or `https://rg.localhost:8443` when setup had to use port 8443; `.\resgrid.ps1 status` prints it).

## Optional features

Resgrid ships several modules behind feature flags that are off on a new install. Setup asks about each one once Resgrid is running; change them any time with:

```powershell
.\resgrid.ps1 features          # walk through the optional features
.\resgrid.ps1 features -All     # also offer flags no feature in the catalog covers
```

One question covers everything a feature needs: **Records (RMS)** (13 flags: incident and field records, prevention, investigations, quality review, analytics), **Unified search** (search across calls, personnel, units, contacts and records, with its index in the local RustFS storage), **Chat**, **Run cards**, **Checklists**, **Deployments**, **Setup wizard and admin guidance**, **Department import and migration**, **Attachment virus scanning** (starts a ClamAV container that needs about 1.5 GB of RAM) and **Text-message commands (Twilio)** (needs internet). Resgrid's paid add-ons (Enhanced AI, Workforce and Business Operations, Incident Back Office, Readiness Pro work orders, Advanced Data Protection) need Resgrid's hosted billing and aren't offered.

A feature is switched for every department on this computer, and the change shows on the next page load. Setup remembers your choices in `.env` (`RESGRID_FEATURES`); later runs of `setup.ps1` only ask about features that are new in that version, and switch a feature you turned on fully back on if a restored database or a new Resgrid version left it off or partly on. Without questions: `.\setup.ps1 -Features records,search` (features not listed are switched off).

The list of features and the flags and settings behind each come from [features/catalog.ini](features/catalog.ini), shared by all setup branches; see [Maintaining the feature list](https://github.com/Resgrid/resgrid-setup#maintaining-the-feature-list).

## Working offline

Everything Resgrid needs runs on the laptop: once setup has finished you can disconnect from all networks. What changes without internet:

- **Email** (invitations, password resets, notifications) isn't sent. Add people under **Personnel > Add Person** and set their passwords yourself.
- **Maps**: the web map needs the offline tile server ([Offline maps](#offline-maps)); without it the map area is blank. Address search (Nominatim) and routing don't work offline.
- **Push notifications, SMS and voice calls** need internet services and aren't available.
- Some pages use web fonts from Google; offline they fall back to system fonts.

## Offline maps

Import the area you need while online (smallest extract that covers it; a US state takes 10–60 minutes and 5–20 GB):

```powershell
.\resgrid.ps1 maps-import https://download.geofabrik.de/north-america/us/nevada-latest.osm.pbf
```

or a file you downloaded: `.\resgrid.ps1 maps-import C:\Downloads\nevada-latest.osm.pbf`. Resgrid's web map then uses `https://rg.localhost/tiles/...`, and the tile server starts with Resgrid from then on (`maps` in `COMPOSE_PROFILES` in `.env`). Tiles are drawn the first time an area is viewed and cached afterwards; browse the zoom levels you need once before going offline to warm the cache.

## Backup, restore and upgrade

`.\resgrid.ps1 backup` writes `backups\resgrid-<date>.zip` with a database dump, `.env` and the certificates. It contains every secret: copy it to encrypted removable storage, off the laptop.

`.\resgrid.ps1 restore backups\resgrid-<date>.zip` replaces the current data with the backup (it asks you to type `RESTORE`). On a new laptop, run `setup.ps1 -NoStart` first, then copy `env.txt` from the backup over `.env` and its `certs` folder over `certs`, then `.\resgrid.ps1 start` and restore.

To upgrade (needs internet): back up, then

```powershell
.\resgrid.ps1 upgrade
```

`upgrade` gets the newest setup files (`git pull`; without git, extract the newest [laptop branch zip](https://github.com/Resgrid/resgrid-setup/archive/refs/heads/laptop.zip) over the folder first: it contains no `.env`, certificates or data) and runs `setup.ps1` again. Running `setup.ps1` again is always safe; on an existing install it never replaces a value you set, never rotates a secret and never deletes data. It:

1. backs up `.env` (`.env.backup-<date>`), adds the settings new versions need (new secrets get random values) and fixes values known to break;
2. recreates generated files that are missing (certificates);
3. keeps the data of an older version: a database container from an earlier layout is stopped and saved as the image `resgrid-legacy-db:<id>`, its data copied into the new database while that is still empty, and a dump kept in `backups\`;
4. keeps the ports, unless another program took one while Resgrid was stopped: the HTTP redirect port then moves to a free one, and for the HTTPS port setup asks you to run `.\setup.ps1 -HttpsPort 8443` (which updates every Resgrid address);
5. downloads the new images (skipped when offline, or with `-NoPull`), starts new services, removes retired ones and restarts; the database is migrated automatically;
6. asks about optional features that are new in this version and re-applies the ones you turned on.

Installs created before October 2026 tracked `.env` in git: `upgrade` keeps your copy across the `git pull`. If `git pull` stops with "Your local changes would be overwritten", run `copy .env $HOME\resgrid-env-backup; git checkout -- .env; git pull; copy $HOME\resgrid-env-backup .env`, then `.\setup.ps1`.

## Remove

```powershell
.\resgrid.ps1 uninstall              # remove containers, keep data
.\resgrid.ps1 uninstall -DeleteData  # remove everything (asks you to type DELETE)
```

To remove the trusted certificate: run `certmgr.msc`, open **Trusted Root Certification Authorities > Certificates** and delete **Resgrid Local CA**.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Docker Desktop is not running` | Start Docker Desktop and wait for **Engine running**. |
| `Docker Desktop is using Windows containers` | Right-click the Docker tray icon, **Switch to Linux containers**. |
| Certificate warning in the browser | Run `.\resgrid.ps1 trust-ca` and restart the browser. Firefox: see the note in [Install](#install). |
| Browser can't find `rg.localhost` | Use Chrome, Edge or Firefox (they resolve `*.localhost`), or install with `-WebHost`/`-ApiHost`/`-EventsHost` and add the hosts-file line setup prints. |
| Sign Up returns to the login page | `.env` must contain `RESGRID__SystemBehaviorConfig__AllowSignupWithoutBilling=true`; run `.\resgrid.ps1 upgrade` if it's missing. |
| `429 Too Many Requests` during setup | Docker Hub rate limit: sign in to Docker Desktop (or `docker login`) and run setup again. |
| Pages are slow right after start | The first start migrates the database; wait for `.\resgrid.ps1 logs worker` to settle. |

## Files

| Path | Purpose |
|---|---|
| [setup.ps1](setup.ps1) | Setup, upgrade and repair (safe to run again) |
| [resgrid.ps1](resgrid.ps1) | start, stop, status, logs, open, backup, restore, features, upgrade, maps-import, trust-ca, uninstall |
| [features/catalog.ini](features/catalog.ini), [scripts/features.ps1](scripts/features.ps1) | Optional features: the catalog and the PowerShell code that applies it |
| [docker-compose.yml](docker-compose.yml) | The stack (all ports on 127.0.0.1) |
| [.env.example](.env.example) | Configuration template; setup writes `.env` (git-ignored) |
| [caddy/Caddyfile](caddy/Caddyfile) | HTTPS and the `/tiles/` route |
| `certs/` | Local certificate authority (generated) |
| [setup.sh](setup.sh), [maps/import.sh](maps/import.sh) | The same setup for WSL 2 / Linux shells |

## License

Apache 2.0, see [LICENSE](LICENSE).
