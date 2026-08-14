[CmdletBinding()]
param(
    [string]$WebHost = "rg.mylocal",
    [string]$ApiHost = "rgapi.mylocal",
    [string]$EventsHost = "rgevents.mylocal",
    [string]$LetsEncryptEmail = "internal",
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function New-RandomString([int]$Length, [string]$Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") {
    $builder = [System.Text.StringBuilder]::new($Length)
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = New-Object byte[] 1
    $acceptedRange = [Math]::Floor(256 / $Alphabet.Length) * $Alphabet.Length
    try {
        for ($index = 0; $index -lt $Length; $index++) {
            do {
                $generator.GetBytes($buffer)
            } while ($buffer[0] -ge $acceptedRange)
            $position = $buffer[0] % $Alphabet.Length
            [void]$builder.Append($Alphabet[$position])
        }
    }
    finally {
        $generator.Dispose()
    }
    return $builder.ToString()
}

function New-OidcCertificate([string]$CommonName, [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]$Usage) {
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=$CommonName",
            $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new($Usage, $true)
        )
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddYears(10))
        try {
            $bytes = $certificate.Export(
                [System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12,
                [string]::Empty
            )
            return [Convert]::ToBase64String($bytes)
        }
        finally {
            $certificate.Dispose()
        }
    }
    finally {
        $rsa.Dispose()
    }
}

function Set-EnvValue([string]$Path, [string]$Key, [string]$Value) {
    $lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $Path)
    $pattern = "^$([Regex]::Escape($Key))="
    $found = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match $pattern) {
            $lines[$index] = "$Key=$Value"
            $found = $true
            break
        }
    }
    if (-not $found) {
        throw "Key '$Key' is missing from the .env template."
    }
    [System.IO.File]::WriteAllLines($Path, $lines, [System.Text.UTF8Encoding]::new($false))
}

function Normalize-Host([string]$Value) {
    return ($Value -replace '^https?://', '' -replace '/.*$', '')
}

$root = $PSScriptRoot
Set-Location -LiteralPath $root
$envPath = Join-Path $root ".env"
$markerPath = Join-Path $root ".setup-complete"

if (-not (Test-Path -LiteralPath $envPath)) {
    throw "Run setup.ps1 from a checkout of the laptop branch; .env was not found."
}
if (Test-Path -LiteralPath $markerPath) {
    throw "This checkout is already configured. Back up .env, remove .setup-complete, and restore the template before reconfiguring."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker Desktop is required: https://docs.docker.com/desktop/setup/install/windows-install/"
}

Write-Step "Checking Docker Desktop"
& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker Desktop is not running or is not using Linux containers."
}
& docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "The Docker Compose v2 plugin is required."
}

$WebHost = Normalize-Host $WebHost
$ApiHost = Normalize-Host $ApiHost
$EventsHost = Normalize-Host $EventsHost

Write-Step "Generating credentials and OpenIddict certificates"
$postgresUser = "resgrid"
$postgresPassword = New-RandomString 32
$redisPassword = New-RandomString 32
$rabbitUser = "resgrid"
$rabbitPassword = New-RandomString 32
$rustAccess = New-RandomString 20 "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
$rustSecret = New-RandomString 40 "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
$systemApiKey = New-RandomString 48

$encryptionCertificate = New-OidcCertificate "Resgrid OIDC Server Encryption Certificate" ([System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment)
$signingCertificate = New-OidcCertificate "Resgrid OIDC Server Signing Certificate" ([System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature)

function New-PostgresConnection([string]$Database) {
    return "User ID=$postgresUser;Password=$postgresPassword;Host=172.16.193.55;Port=5432;Database=$Database;Pooling=true;Connection Lifetime=0;Include Error Detail=true;"
}

$settings = [ordered]@{
    NGINX_RESGRID_WEB_URL = $WebHost
    NGINX_RESGRID_API_URL = $ApiHost
    NGINX_RESGRID_EVENTS_URL = $EventsHost
    NGINX_LETSENCRYPT_EMAIL = $LetsEncryptEmail
    POSTGRES_USER = $postgresUser
    POSTGRES_PASSWORD = $postgresPassword
    REDIS_PASSWORD = $redisPassword
    RABBITMQ_USER = $rabbitUser
    RABBITMQ_PASSWORD = $rabbitPassword
    RUSTFS_ACCESS_KEY = $rustAccess
    RUSTFS_SECRET_KEY = $rustSecret
    RESGRID__SystemBehaviorConfig__ResgridBaseUrl = "https://$WebHost"
    RESGRID__SystemBehaviorConfig__ResgridApiBaseUrl = "https://$ApiHost"
    RESGRID__SystemBehaviorConfig__ResgridEventingBaseUrl = "https://$EventsHost"
    RESGRID__SystemBehaviorConfig__ExternalLinkUrlParamPassphrase = (New-RandomString 24)
    RESGRID__SystemBehaviorConfig__ExternalAudioUrlParamPasshprase = (New-RandomString 24)
    RESGRID__SystemBehaviorConfig__ApiTokenEncryptionPassphrase = (New-RandomString 24)
    RESGRID__SystemBehaviorConfig__FullHealthCheckKey = (New-RandomString 32)
    RESGRID__SecurityConfig__EncryptionKey = (New-RandomString 32)
    RESGRID__SecurityConfig__EncryptionSaltValue = (New-RandomString 24)
    RESGRID__SecurityConfig__SystemApiKey = $systemApiKey
    RESGRID__CacheConfig__RedisConnectionString = "172.16.193.56:6379,Password=$redisPassword,allowAdmin=True"
    RESGRID__DataConfig__ConnectionString = (New-PostgresConnection "resgrid")
    RESGRID__DataConfig__CoreConnectionString = (New-PostgresConnection "resgrid")
    RESGRID__DataConfig__DocumentConnectionString = (New-PostgresConnection "resgriddoc")
    RESGRID__OidcConfig__ConnectionString = (New-PostgresConnection "resgridoidc")
    RESGRID__OidcConfig__EncryptionCert = $encryptionCertificate
    RESGRID__OidcConfig__SigningCert = $signingCertificate
    RESGRID__JwtConfig__EventsClientSecret = (New-RandomString 48)
    RESGRID__ApiConfig__BypassSslChecks = $(if ($LetsEncryptEmail -eq "internal") { "true" } else { "false" })
    RESGRID__ServiceBusConfig__RabbitUsername = $rabbitUser
    RESGRID__ServiceBusConfig__RabbbitPassword = $rabbitPassword
    RESGRID__WorkerConfig__WorkerDbConnectionString = (New-PostgresConnection "resgridworkers")
    RESGRID__WorkerConfig__PayloadKey = (New-RandomString 96)
    RESGRID__TtsConfig__PlaybackBaseUrl = "https://$ApiHost"
    RESGRID__TtsConfig__StaticPromptAdminKey = (New-RandomString 32)
    RESGRID__TtsConfig__S3AccessKey = $rustAccess
    RESGRID__TtsConfig__S3SecretKey = $rustSecret
    RESGRID__RELAY__Resgrid__SystemApiKey = $systemApiKey
    RESGRID__RELAY__Resgrid__ClientSecret = (New-RandomString 32)
    RESGRID__RELAY__Smtp__DepartmentAddressDomains__0 = "dispatch.$WebHost"
    RESGRID__UnitTrackingConfig__CredentialPepper = (New-RandomString 48)
}

foreach ($entry in $settings.GetEnumerator()) {
    Set-EnvValue $envPath $entry.Key ([string]$entry.Value)
}

$dataDirectories = @(
    "docker-data/sql",
    "docker-data/redis/data",
    "docker-data/caddy/data",
    "docker-data/caddy/config",
    "docker-data/rustfs"
)
foreach ($directory in $dataDirectories) {
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $root $directory))
}
[System.IO.File]::WriteAllText($markerPath, [DateTimeOffset]::Now.ToString("O"))

Write-Host ""
Write-Host "Add this line to C:\Windows\System32\drivers\etc\hosts as Administrator:" -ForegroundColor Yellow
Write-Host "127.0.0.1  $WebHost $ApiHost $EventsHost"
Write-Host ""

if ($NoStart) {
    Write-Host "Configuration complete. Start later with: docker compose up -d" -ForegroundColor Green
    exit 0
}

Write-Step "Pulling images"
& docker compose pull
if ($LASTEXITCODE -ne 0) { throw "docker compose pull failed." }

Write-Step "Starting Resgrid"
& docker compose up -d
if ($LASTEXITCODE -ne 0) { throw "docker compose up failed." }

Write-Host "Resgrid is starting. Follow migrations with: docker compose logs -f worker" -ForegroundColor Green
Write-Host "Open https://$WebHost after the worker completes its first database migration."
