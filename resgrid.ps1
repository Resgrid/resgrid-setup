<#
.SYNOPSIS
    Day-to-day management of Resgrid on this computer.

.DESCRIPTION
    .\resgrid.ps1 start             start Resgrid (and the map server, if imported)
    .\resgrid.ps1 stop              stop Resgrid (data is kept)
    .\resgrid.ps1 restart           restart every service
    .\resgrid.ps1 status            show service status
    .\resgrid.ps1 logs [service]    follow logs (web, api, events, worker, caddy, ...)
    .\resgrid.ps1 open              open Resgrid in the browser
    .\resgrid.ps1 backup            database dump + .env + certificates -> backups\
    .\resgrid.ps1 restore <file>    restore a database dump made by 'backup'
    .\resgrid.ps1 features [-All]   turn optional features on or off (Records, Search, Chat, ...)
    .\resgrid.ps1 upgrade           get the newest setup files and images, add new settings and
                                    services, keep your data (needs internet; same as re-running setup.ps1)
    .\resgrid.ps1 maps-import <url|file.osm.pbf>   load an offline map region
    .\resgrid.ps1 trust-ca          trust the local certificate authority again
    .\resgrid.ps1 uninstall [-DeleteData]          remove containers (and all data)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "restart", "status", "logs", "open", "backup", "restore", "features", "upgrade", "maps-import", "trust-ca", "uninstall", "help")]
    [string]$Command = "help",
    [Parameter(Position = 1)]
    [string]$Argument = "",
    [switch]$DeleteData,
    [switch]$All
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "scripts\common.ps1")
. (Join-Path $PSScriptRoot "scripts\features.ps1")
Set-Location -LiteralPath $script:Root

if ($Command -eq "help") { Get-Help $PSCommandPath -Detailed | Out-String | Write-Host; exit 0 }
if (-not (Test-Path -LiteralPath $script:EnvPath)) { throw "Resgrid is not configured yet. Run .\setup.ps1 first." }
Assert-Docker

# Optional services (maps, clamav, ...) are listed in COMPOSE_PROFILES in .env,
# which docker compose reads by itself.
function Get-Profiles { return @() }

switch ($Command) {
    "start" {
        $profiles = Get-Profiles
        Save-LegacyContainers
        Copy-LegacyDatabase
        Invoke-Compose @profiles up -d
        [void](Wait-Resgrid)
        Write-Host "Resgrid: $(Get-WebUrl)"
    }
    "stop" {
        $profiles = Get-Profiles
        Invoke-Compose @profiles stop
    }
    "restart" {
        $profiles = Get-Profiles
        Invoke-Compose @profiles restart
    }
    "status" {
        $profiles = Get-Profiles
        Invoke-Compose @profiles ps --format "table {{.Service}}\t{{.State}}\t{{.Status}}"
        Write-Host ""
        Write-Host "Resgrid: $(Get-WebUrl)"
    }
    "logs" {
        $services = @()
        if ($Argument) { $services = @($Argument) }
        Invoke-Compose logs -f --tail 200 @services
    }
    "open" {
        Start-Process (Get-WebUrl)
    }
    "backup" {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $dir = Join-Path $script:Root "backups\resgrid-$stamp"
        [void](New-Item -ItemType Directory -Force -Path $dir)
        Write-Step "Dumping the database"
        Invoke-Compose exec -T db sh -c "pg_dumpall -U `"`$POSTGRES_USER`" --clean --if-exists > /tmp/resgrid-backup.sql"
        Invoke-Compose cp db:/tmp/resgrid-backup.sql (Join-Path $dir "resgrid.sql")
        Invoke-Compose exec -T db rm -f /tmp/resgrid-backup.sql
        Copy-Item -LiteralPath $script:EnvPath -Destination (Join-Path $dir "env.txt")
        Copy-Item -Recurse -LiteralPath (Join-Path $script:Root "certs") -Destination (Join-Path $dir "certs")
        $zip = "$dir.zip"
        Compress-Archive -Path "$dir\*" -DestinationPath $zip
        Remove-Item -Recurse -Force -LiteralPath $dir
        Write-Ok "Backup written to $zip"
        Write-Host "It contains every password and key. Store it encrypted, off this computer."
    }
    "restore" {
        if (-not $Argument -or -not (Test-Path -LiteralPath $Argument)) { throw "Usage: .\resgrid.ps1 restore <backup .zip or resgrid.sql>" }
        $sql = $Argument
        $temp = $null
        if ($Argument.EndsWith(".zip")) {
            $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("resgrid-restore-" + [guid]::NewGuid())
            Expand-Archive -LiteralPath $Argument -DestinationPath $temp
            $sql = Join-Path $temp "resgrid.sql"
            Write-Warn "Restore uses the database from the backup but keeps the current .env. If this is a new install, copy env.txt and certs\ from the backup first, or logins and encrypted data won't work."
        }
        $answer = Read-Host "This REPLACES all Resgrid data with the backup. Type RESTORE to continue"
        if ($answer -ne "RESTORE") { Write-Host "Cancelled."; exit 1 }
        Write-Step "Stopping Resgrid services"
        Invoke-Compose stop web api events worker tts mcp
        try {
            Invoke-Compose cp $sql db:/tmp/resgrid-restore.sql
            Write-Step "Restoring the database (messages that something 'already exists' are expected)"
            Invoke-Compose exec -T db sh -c "psql -v ON_ERROR_STOP=0 -q -U `"`$POSTGRES_USER`" -d postgres -f /tmp/resgrid-restore.sql > /dev/null 2> /tmp/resgrid-restore.log; grep ERROR /tmp/resgrid-restore.log | grep -v -e 'already exists' -e 'current user cannot be dropped' || true"
            & docker compose exec -T -u 0 db rm -f /tmp/resgrid-restore.sql /tmp/resgrid-restore.log *> $null
        }
        finally {
            if ($temp) { Remove-Item -Recurse -Force -LiteralPath $temp }
            Invoke-Compose up -d
        }
        [void](Wait-Resgrid)
        Write-Ok "Restore complete."
    }
    "features" {
        Save-LegacyContainers
        Invoke-Features -All:$All
        Complete-FeatureChanges
        $on = Get-EnvValue "RESGRID_FEATURES"
        Write-Ok "Optional features on: $(if ($on) { $on -replace ',', ', ' } else { 'none' })"
    }
    "upgrade" {
        # Newest setup files first (keeps .env, certificates and data), then
        # setup.ps1 repairs the configuration, pulls images and restarts.
        if ((Test-Path -LiteralPath (Join-Path $script:Root ".git")) -and (Get-Command git -ErrorAction SilentlyContinue)) {
            Write-Step "Updating the setup files (git pull)"
            & git -C $script:Root pull --ff-only
            if ($LASTEXITCODE -ne 0) { Write-Warn "git pull failed (local changes?). Continuing with the files you have." }
        }
        else {
            Write-Warn "Not a git checkout: download the newest laptop branch zip, extract it over this folder (your .env, certs and data are not in it), then run .\setup.ps1."
        }
        & (Join-Path $script:Root "setup.ps1") -NoBrowser
    }
    "maps-import" {
        if (-not $Argument) { throw "Usage: .\resgrid.ps1 maps-import <https://download.geofabrik.de/...osm.pbf | C:\path\region.osm.pbf>" }
        Write-Step "Preparing the offline map server"
        Invoke-Compose --profile maps rm -sf tileserver
        Invoke-Compose --profile maps run --rm --no-deps --entrypoint sh tileserver -c "rm -rf /data/database/* /data/tiles/*"
        Write-Step "Importing $Argument (a US state takes 10-60 minutes)"
        if ($Argument -match '^https?://') {
            Invoke-Compose --profile maps run --rm -e "DOWNLOAD_PBF=$Argument" tileserver import
        }
        else {
            $file = (Resolve-Path -LiteralPath $Argument).Path
            Invoke-Compose --profile maps run --rm -v "${file}:/data/region.osm.pbf:ro" tileserver import
        }
        # Keep "maps" in COMPOSE_PROFILES so start/upgrade keep the tile server running.
        $profilesNow = @((Get-EnvValue "COMPOSE_PROFILES") -split ',' | Where-Object { $_ })
        if ("maps" -notin $profilesNow) { Set-EnvValueOrAdd "COMPOSE_PROFILES" (($profilesNow + "maps") -join ',') }
        Invoke-Compose --profile maps up -d tileserver
        $tiles = "$(Get-WebUrl)/tiles/{z}/{x}/{y}.png"
        Set-EnvValues @{ RESGRID__MappingConfig__LeafletTileUrl = $tiles }
        Invoke-Compose up -d web api
        Write-Ok "Offline maps ready: $tiles"
    }
    "trust-ca" {
        Import-Ca
    }
    "uninstall" {
        $profiles = @("--profile", "maps", "--profile", "tracking", "--profile", "relay")
        if ($DeleteData) {
            $answer = Read-Host "This deletes ALL Resgrid data (database, files, maps). Type DELETE to continue"
            if ($answer -ne "DELETE") { Write-Host "Cancelled."; exit 1 }
            Invoke-Compose @profiles down --volumes --remove-orphans
            Remove-Item -Force -LiteralPath $script:EnvPath, (Join-Path $script:Root ".setup-complete") -ErrorAction SilentlyContinue
            Write-Ok "Resgrid and its data were removed. certs\ is kept; delete it if you no longer need the CA."
        }
        else {
            Invoke-Compose @profiles down --remove-orphans
            Write-Ok "Containers removed. Data volumes and .env are kept; .\resgrid.ps1 start brings Resgrid back."
        }
    }
}
