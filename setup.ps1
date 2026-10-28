<#
.SYNOPSIS
    Configures and starts Resgrid on this Windows computer (Docker Desktop).

.DESCRIPTION
    First run: generates every password, key and certificate into .env,
    creates a local certificate authority and trusts it for your Windows
    account, picks free ports, starts the stack, offers the optional features
    and opens Resgrid in your browser.

    Every later run upgrades and repairs the install: it keeps your settings,
    secrets and data, adds new settings and services, pulls new images (when
    online), restarts, and offers the optional features again. Run it after
    downloading a newer version of this folder (git pull).

.EXAMPLE
    .\setup.ps1

.EXAMPLE
    .\setup.ps1 -Features records,search -MapRegion https://download.geofabrik.de/north-america/us/nevada-latest.osm.pbf
#>
[CmdletBinding()]
param(
    # Hostnames. Names ending in .localhost need no hosts-file entry.
    [string]$WebHost = "rg.localhost",
    [string]$ApiHost = "rgapi.localhost",
    [string]$EventsHost = "rgevents.localhost",
    # 0 = use 80/443 if free, otherwise 8080/8443.
    [int]$HttpPort = 0,
    [int]$HttpsPort = 0,
    # OpenStreetMap extract (URL or .osm.pbf file) for offline maps.
    [string]$MapRegion = "",
    # Don't add the local CA to the Windows trust store.
    [switch]$NoTrustCa,
    # Optional features (sections of features\catalog.ini) to have on, e.g.
    # "records,search", or "all" / "none". Without it setup asks.
    [string[]]$Features = @(),
    # Never ask questions; keep features as they are unless -Features is given.
    [switch]$NonInteractive,
    # Don't download images (re-run while offline).
    [switch]$NoPull,
    # Configure only; don't pull images or start containers.
    [switch]$NoStart,
    # Don't open the browser at the end.
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "scripts\common.ps1")
. (Join-Path $PSScriptRoot "scripts\features.ps1")
Set-Location -LiteralPath $script:Root

Write-Host ""
Write-Host "  Resgrid for Windows - offline laptop installer" -ForegroundColor White
Write-Host ""

if (-not (Test-Path -LiteralPath $script:TemplatePath)) { throw "Run setup.ps1 from a checkout of the laptop branch (.env.example not found)." }

Write-Step "Checking Docker Desktop"
Assert-Docker

$firstRun = -not (Test-Path -LiteralPath $script:EnvPath)
if (-not $firstRun) {
    Write-Ok "Existing install found: upgrading and repairing it (your settings and data are kept)."
    Update-EnvFile
    $WebHost = Get-EnvValue "RESGRID_WEB_HOST"; $ApiHost = Get-EnvValue "RESGRID_API_HOST"; $EventsHost = Get-EnvValue "RESGRID_EVENTS_HOST"

    # Ports: keep the configured ones unless you pass new ones, or another
    # program took them while Resgrid was stopped (Resgrid's own Caddy holding
    # them is fine). The HTTP port only redirects, so it can move by itself;
    # the HTTPS port is part of every Resgrid address.
    Push-Location $script:Root
    $caddyUp = [bool](& docker compose ps -q --status running caddy 2>$null)
    Pop-Location
    $oldHttps = [int](Get-EnvValue "RESGRID_HTTPS_PORT")
    if ($HttpsPort -ne 0 -and $HttpsPort -ne $oldHttps) {
        $from = if ($oldHttps -eq 443) { "" } else { ":$oldHttps" }
        $to = if ($HttpsPort -eq 443) { "" } else { ":$HttpsPort" }
        $text = [System.IO.File]::ReadAllText($script:EnvPath)
        foreach ($h in @($WebHost, $ApiHost, $EventsHost)) {
            $text = [regex]::Replace($text, "https://$([regex]::Escape($h))$([regex]::Escape($from))(?=[/\s]|$)", "https://$h$to")
        }
        [System.IO.File]::WriteAllText($script:EnvPath, $text, (New-Object System.Text.UTF8Encoding($false)))
        Set-EnvValues @{ RESGRID_HTTPS_PORT = "$HttpsPort" }
        Write-Ok "Resgrid now uses port $HttpsPort (https://$WebHost$to)."
    }
    elseif (-not $caddyUp -and (Test-PortInUse $oldHttps)) {
        throw "Port $oldHttps (Resgrid's HTTPS port) is now used by another program. Stop that program, or move Resgrid: .\setup.ps1 -HttpsPort 8443"
    }
    $oldHttp = [int](Get-EnvValue "RESGRID_HTTP_PORT")
    if ($HttpPort -ne 0) { Set-EnvValues @{ RESGRID_HTTP_PORT = "$HttpPort" } }
    elseif (-not $caddyUp -and (Test-PortInUse $oldHttp)) {
        $free = @(80, 8080, 8880, 18080) | Where-Object { -not (Test-PortInUse $_) } | Select-Object -First 1
        if (-not $free) { throw "Port $oldHttp is in use and no free HTTP port was found. Pass -HttpPort with a free port." }
        Set-EnvValues @{ RESGRID_HTTP_PORT = "$free" }
        Write-Warn "Port $oldHttp is now used by another program; Resgrid's HTTP redirect moves to port $free."
    }
}
else {

$normalize = { param($v) ($v -replace '^https?://', '' -replace '/.*$', '').ToLowerInvariant() }
$WebHost = & $normalize $WebHost
$ApiHost = & $normalize $ApiHost
$EventsHost = & $normalize $EventsHost

$firstFree = { param([int[]]$candidates) foreach ($c in $candidates) { if (-not (Test-PortInUse $c)) { return $c } }; return $candidates[-1] }
if ($HttpsPort -eq 0) { $HttpsPort = & $firstFree @(443, 8443, 9443, 18443) }
if ($HttpPort -eq 0) { $HttpPort = & $firstFree @(80, 8080, 8880, 18080) }
foreach ($p in @($HttpPort, $HttpsPort)) { if (Test-PortInUse $p) { throw "Port $p is already in use. Pass -HttpPort / -HttpsPort with free ports." } }
$suffix = if ($HttpsPort -eq 443) { "" } else { ":$HttpsPort" }
if ($HttpsPort -ne 443) { Write-Warn "Port 443 is in use (IIS or another program); Resgrid will use port $HttpsPort." }

Write-Step "Generating passwords, keys and certificates"
Copy-Item -LiteralPath $script:TemplatePath -Destination $script:EnvPath

$pgPassword = New-RandomString 32
$redisPassword = New-RandomString 32
$rabbitPassword = New-RandomString 32
$rustAccess = New-RandomString 20 "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
$rustSecret = New-RandomString 40 "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
$systemApiKey = New-RandomString 48
$pg = { param($db) "User ID=resgrid;Password=$pgPassword;Host=db;Port=5432;Database=$db;Pooling=true;Connection Lifetime=0;Include Error Detail=true;" }
$keyUsage = [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]

Set-EnvValues @{
    RESGRID_WEB_HOST = $WebHost
    RESGRID_API_HOST = $ApiHost
    RESGRID_EVENTS_HOST = $EventsHost
    RESGRID_TLS = "internal"
    RESGRID_HTTP_PORT = "$HttpPort"
    RESGRID_HTTPS_PORT = "$HttpsPort"
    POSTGRES_USER = "resgrid"
    POSTGRES_PASSWORD = $pgPassword
    REDIS_PASSWORD = $redisPassword
    RABBITMQ_USER = "resgrid"
    RABBITMQ_PASSWORD = $rabbitPassword
    RUSTFS_ACCESS_KEY = $rustAccess
    RUSTFS_SECRET_KEY = $rustSecret
    RESGRID__SystemBehaviorConfig__ResgridBaseUrl = "https://$WebHost$suffix"
    RESGRID__SystemBehaviorConfig__ResgridApiBaseUrl = "https://$ApiHost$suffix"
    RESGRID__SystemBehaviorConfig__ResgridEventingBaseUrl = "https://$EventsHost$suffix"
    RESGRID__SystemBehaviorConfig__ExternalLinkUrlParamPassphrase = (New-RandomString 24)
    RESGRID__SystemBehaviorConfig__ExternalAudioUrlParamPasshprase = (New-RandomString 24)
    RESGRID__SystemBehaviorConfig__ApiTokenEncryptionPassphrase = (New-RandomString 24)
    RESGRID__SystemBehaviorConfig__FullHealthCheckKey = (New-RandomString 32)
    RESGRID__SecurityConfig__EncryptionKey = (New-RandomString 32)
    RESGRID__SecurityConfig__EncryptionSaltValue = (New-RandomString 24)
    RESGRID__SecurityConfig__SystemApiKey = $systemApiKey
    RESGRID__SecurityConfig__DepartmentApiKeyPepper = (New-RandomString 48)
    RESGRID__ApiConfig__BackendInternalApikey = (New-RandomString 48)
    RESGRID__CacheConfig__RedisConnectionString = "redis:6379,password=$redisPassword,allowAdmin=True"
    RESGRID__DataConfig__ConnectionString = (& $pg "resgrid")
    RESGRID__DataConfig__CoreConnectionString = (& $pg "resgrid")
    RESGRID__DataConfig__DocumentConnectionString = (& $pg "resgriddoc")
    RESGRID__OidcConfig__ConnectionString = (& $pg "resgridoidc")
    RESGRID__WorkerConfig__WorkerDbConnectionString = (& $pg "resgridworkers")
    RESGRID__OidcConfig__EncryptionCert = (New-OidcCertificate "Resgrid OIDC Server Encryption Certificate" $keyUsage::KeyEncipherment)
    RESGRID__OidcConfig__SigningCert = (New-OidcCertificate "Resgrid OIDC Server Signing Certificate" $keyUsage::DigitalSignature)
    RESGRID__JwtConfig__EventsClientSecret = (New-RandomString 48)
    RESGRID__ServiceBusConfig__RabbitUsername = "resgrid"
    RESGRID__ServiceBusConfig__RabbbitPassword = $rabbitPassword
    RESGRID__WorkerConfig__PayloadKey = (New-RandomString 96)
    RESGRID__TtsConfig__PlaybackBaseUrl = "https://$ApiHost$suffix"
    RESGRID__TtsConfig__StaticPromptAdminKey = (New-RandomString 32)
    RESGRID__TtsConfig__S3AccessKey = $rustAccess
    RESGRID__TtsConfig__S3SecretKey = $rustSecret
    RESGRID__ImportConfig__S3AccessKey = $rustAccess
    RESGRID__ImportConfig__S3SecretKey = $rustSecret
    RESGRID__UnitTrackingConfig__CredentialPepper = (New-RandomString 48)
    RESGRID__RELAY__Resgrid__SystemApiKey = $systemApiKey
    RESGRID__RELAY__Resgrid__ClientSecret = (New-RandomString 32)
    RESGRID__RELAY__Smtp__DepartmentAddressDomains__0 = "dispatch.$WebHost"
}

[System.IO.File]::WriteAllText((Join-Path $script:Root ".setup-complete"), [DateTimeOffset]::Now.ToString("O"))
Write-Ok "Configuration written to .env. It holds all your secrets: back it up (.\resgrid.ps1 backup) and keep it private."
}

New-LocalCa $WebHost
if (-not $NoTrustCa) { Import-Ca }

if (-not $WebHost.EndsWith(".localhost")) {
    Write-Warn "Add this line to C:\Windows\System32\drivers\etc\hosts (edit Notepad as Administrator):"
    Write-Host "    127.0.0.1  $WebHost $ApiHost $EventsHost"
}

if ($NoStart) {
    Write-Ok "Configured. Start with: .\resgrid.ps1 start"
    exit 0
}

# Before any container is (re)created: keep the data of an earlier version.
Save-LegacyContainers

if (-not $NoPull) {
    Write-Step "Downloading container images (several GB the first time)"
    if ($firstRun) {
        Invoke-Compose pull
        if ($MapRegion) { Invoke-Compose --profile maps pull tileserver }
    }
    else {
        Push-Location $script:Root
        & docker compose pull --ignore-pull-failures
        if ($LASTEXITCODE -ne 0) { Write-Warn "Some images could not be downloaded (offline?). Using the images already on this computer." }
        Pop-Location
    }
}

Copy-LegacyDatabase -NonInteractive:$NonInteractive

Write-Step "Starting Resgrid"
Invoke-Compose up -d --remove-orphans
# Caddy doesn't watch its Caddyfile; restart it so a new version is used.
if (-not $firstRun) { Invoke-Compose restart caddy }
$up = Wait-Resgrid

if ($MapRegion) {
    & (Join-Path $script:Root "resgrid.ps1") maps-import $MapRegion
}

if ($up -and (Wait-Migrations)) {
    Invoke-Features -Wanted ($Features -join ",") -NonInteractive:$NonInteractive -OnlyNew
    Complete-FeatureChanges
}

$url = Get-WebUrl
Write-Host ""
Write-Host "  Resgrid:  $url" -ForegroundColor White
if ($firstRun) { Write-Host "  Choose 'Sign Up' to create the first account and department." }
$on = Get-EnvValue "RESGRID_FEATURES"
Write-Host "  Optional features on: $(if ($on) { $on -replace ',', ', ' } else { 'none' })  (change with .\resgrid.ps1 features)"
Write-Host ""
Write-Host "  Manage it with .\resgrid.ps1  (start | stop | status | logs | open | backup | features | upgrade)"
Write-Host "  Docker Desktop must be running; enable 'Start Docker Desktop when you sign in' in its settings."
Write-Host ""
if ($up -and $firstRun -and -not $NoBrowser) { Start-Process $url }
