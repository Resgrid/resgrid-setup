# Shared helpers for setup.ps1 and resgrid.ps1. Works in Windows PowerShell 5.1
# and PowerShell 7+.

Set-StrictMode -Version Latest

$script:Root = Split-Path -Parent $PSScriptRoot
$script:EnvPath = Join-Path $script:Root ".env"
$script:TemplatePath = Join-Path $script:Root ".env.example"
$script:CaCertPath = Join-Path $script:Root "certs\ca\resgrid-root-ca.crt"
$script:CaKeyPath = Join-Path $script:Root "certs\private\resgrid-root-ca.key"

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "==> $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "Warning: $Message" -ForegroundColor Yellow }

# Run docker / docker compose and stop on failure.
function Invoke-Docker {
    & docker @args
    if ($LASTEXITCODE -ne 0) { throw "docker $($args -join ' ') failed (exit code $LASTEXITCODE)." }
}

function Invoke-Compose {
    Push-Location $script:Root
    try {
        & docker compose @args
        if ($LASTEXITCODE -ne 0) { throw "docker compose $($args -join ' ') failed (exit code $LASTEXITCODE)." }
    }
    finally { Pop-Location }
}

function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker Desktop is required: https://docs.docker.com/desktop/setup/install/windows-install/"
    }
    $osType = & docker info --format "{{.OSType}}" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Docker Desktop is not running. Start it and wait until it says 'Engine running'." }
    if ($osType -ne "linux") { throw "Docker Desktop is using Windows containers. Right-click the Docker icon and choose 'Switch to Linux containers'." }
    & docker compose version *> $null
    if ($LASTEXITCODE -ne 0) { throw "The Docker Compose v2 plugin is required (update Docker Desktop)." }
}

# Random string from a cryptographic RNG, without modulo bias.
function New-RandomString([int]$Length, [string]$Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") {
    $builder = [System.Text.StringBuilder]::new($Length)
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = New-Object byte[] 1
    $acceptedRange = [Math]::Floor(256 / $Alphabet.Length) * $Alphabet.Length
    try {
        while ($builder.Length -lt $Length) {
            $generator.GetBytes($buffer)
            if ($buffer[0] -lt $acceptedRange) { [void]$builder.Append($Alphabet[$buffer[0] % $Alphabet.Length]) }
        }
    }
    finally { $generator.Dispose() }
    return $builder.ToString()
}

function Read-EnvFile([string]$Path) {
    # The leading comma stops PowerShell from unrolling the list into a fixed-size array.
    return , ([System.Collections.Generic.List[string]]([System.IO.File]::ReadAllLines($Path)))
}

function Save-EnvFile([string]$Path, $Lines) {
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
}

function Get-EnvValue([string]$Key, [string]$Path = $script:EnvPath) {
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line.StartsWith("$Key=")) { return $line.Substring($Key.Length + 1) }
    }
    return $null
}

# Set KEY=value in the env file; the key must already exist.
function Set-EnvValues([hashtable]$Values, [string]$Path = $script:EnvPath) {
    $lines = Read-EnvFile $Path
    foreach ($key in $Values.Keys) {
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].StartsWith("$key=")) { $lines[$i] = "$key=$($Values[$key])"; $found = $true; break }
        }
        if (-not $found) { throw "Key '$key' is missing from $Path." }
    }
    Save-EnvFile $Path $lines
}

function Test-EnvKey([string]$Key, [string]$Path = $script:EnvPath) {
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) { if ($line.StartsWith("$Key=")) { return $true } }
    return $false
}

# Set KEY=value, appending the key when it doesn't exist yet.
function Set-EnvValueOrAdd([string]$Key, [string]$Value, [string]$Path = $script:EnvPath) {
    if (Test-EnvKey $Key $Path) { Set-EnvValues @{ $Key = $Value } $Path; return }
    $lines = Read-EnvFile $Path
    $lines.Add("$Key=$Value")
    Save-EnvFile $Path $lines
}

function Test-Placeholder([string]$Value) { return (-not $Value) -or $Value -match '(?i)changeme' }

# Bring an existing .env up to date. Never replaces a value you set and never
# rotates a secret your data depends on: renames old settings, fills in
# settings that are missing or empty, fixes values known to break.
function Update-EnvFile {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Copy-Item -LiteralPath $script:EnvPath -Destination "$($script:EnvPath).backup-$stamp"
    Write-Step "Checking your configuration (backup: .env.backup-$stamp)"
    $lines = Read-EnvFile $script:EnvPath
    $existing = @{}
    foreach ($l in $lines) { if ($l -match '^([^#=][^=]*)=(.*)$') { $existing[$Matches[1]] = $Matches[2] } }

    # Settings renamed in October 2026 (NGINX_* -> RESGRID_*).
    if (-not $existing.ContainsKey("RESGRID_WEB_HOST") -and $existing.ContainsKey("NGINX_RESGRID_WEB_URL")) {
        Write-Step "Renaming NGINX_* settings to RESGRID_*"
        $lines.Add(""); $lines.Add("# Hostnames and TLS (renamed from NGINX_* by setup)")
        $lines.Add("RESGRID_WEB_HOST=$($existing['NGINX_RESGRID_WEB_URL'])")
        $lines.Add("RESGRID_API_HOST=$($existing['NGINX_RESGRID_API_URL'])")
        $lines.Add("RESGRID_EVENTS_HOST=$($existing['NGINX_RESGRID_EVENTS_URL'])")
        $lines.Add("RESGRID_TLS=$($existing['NGINX_LETSENCRYPT_EMAIL'])")
        foreach ($k in "RESGRID_WEB_HOST", "RESGRID_API_HOST", "RESGRID_EVENTS_HOST", "RESGRID_TLS") { $existing[$k] = "x" }
    }

    # Containers reach each other by service name, listen on 8080 and trust
    # the local CA instead of bypassing certificate checks.
    $fixes = [ordered]@{
        "Host=172.16.193.55;" = "Host=db;"; "172.16.193.56:6379" = "redis:6379"
        "RabbitHostname=172.16.193.57" = "RabbitHostname=rabbitmq"; "http://172.16.193.58:8080" = "http://tts:8080"
        "http://172.16.193.61:9000" = "http://rustfs:9000"
        "RESGRID__RELAY__Resgrid__BaseUrl=http://172.16.193.52" = "RESGRID__RELAY__Resgrid__BaseUrl=http://api:8080"
        "ASPNETCORE_URLS=http://0.0.0.0:80" = "ASPNETCORE_URLS=http://+:8080"
        "RESGRID__ApiConfig__BypassSslChecks=true" = "RESGRID__ApiConfig__BypassSslChecks=false"
    }
    for ($i = 0; $i -lt $lines.Count; $i++) { foreach ($f in $fixes.Keys) { $lines[$i] = $lines[$i].Replace($f, $fixes[$f]) } }

    # Settings introduced since this install was created.
    $added = 0
    foreach ($l in [System.IO.File]::ReadAllLines($script:TemplatePath)) {
        if ($l -notmatch '^([^#=][^=]*)=(.*)$') { continue }
        $key = $Matches[1]; $value = $Matches[2]
        if ($existing.ContainsKey($key)) { continue }
        switch -Wildcard ($key) {
            "RESGRID__ApiConfig__BackendInternalApikey" { $value = New-RandomString 48 }
            "RESGRID__SystemBehaviorConfig__FullHealthCheckKey" { $value = New-RandomString 32 }
            # Empty = derived from the encryption key, as existing department API keys were made.
            "RESGRID__SecurityConfig__DepartmentApiKeyPepper" { $value = "" }
            "RESGRID__SearchConfig__S3*" { if ($key -like "*Key") { $value = "" } }
            "RESGRID__*Config__S3AccessKey" { if ($key -notlike "*Search*") { $value = $existing["RUSTFS_ACCESS_KEY"] } }
            "RESGRID__*Config__S3SecretKey" { if ($key -notlike "*Search*") { $value = $existing["RUSTFS_SECRET_KEY"] } }
        }
        if ($added -eq 0) { $lines.Add(""); $lines.Add("# Added by setup on $(Get-Date -Format yyyy-MM-dd)") }
        $lines.Add("$key=$value"); $existing[$key] = $value
        Write-Host "    added $key"
        $added++
    }
    Save-EnvFile $script:EnvPath $lines

    # Required values that are empty can be generated safely.
    if (-not (Get-EnvValue "RESGRID__ApiConfig__BackendInternalApikey")) { Set-EnvValues @{ RESGRID__ApiConfig__BackendInternalApikey = (New-RandomString 48) } }
    if (-not (Get-EnvValue "RESGRID__SecurityConfig__SystemApiKey")) { Set-EnvValues @{ RESGRID__SecurityConfig__SystemApiKey = (New-RandomString 48) } }
    if (-not (Get-EnvValue "RESGRID__RELAY__Resgrid__SystemApiKey")) { Set-EnvValues @{ RESGRID__RELAY__Resgrid__SystemApiKey = (Get-EnvValue "RESGRID__SecurityConfig__SystemApiKey") } }
    $jwt = Get-EnvValue "RESGRID__JwtConfig__EventsClientSecret"
    if ((Test-Placeholder $jwt) -or $jwt -eq "SecretKeyChangeMe1234!") { Set-EnvValues @{ RESGRID__JwtConfig__EventsClientSecret = (New-RandomString 48) } }
    if (-not (Get-EnvValue "RESGRID__OidcConfig__EncryptionCert") -or -not (Get-EnvValue "RESGRID__OidcConfig__SigningCert")) {
        Write-Step "Creating the missing OpenID Connect certificates"
        $usage = [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]
        Set-EnvValues @{
            RESGRID__OidcConfig__EncryptionCert = (New-OidcCertificate "Resgrid OIDC Server Encryption Certificate" $usage::KeyEncipherment)
            RESGRID__OidcConfig__SigningCert = (New-OidcCertificate "Resgrid OIDC Server Signing Certificate" $usage::DigitalSignature)
        }
    }
    foreach ($key in "POSTGRES_PASSWORD", "REDIS_PASSWORD", "RABBITMQ_PASSWORD", "RESGRID__SecurityConfig__EncryptionKey", "RESGRID__SecurityConfig__EncryptionSaltValue", "RESGRID__WorkerConfig__PayloadKey") {
        if (Test-Placeholder (Get-EnvValue $key)) { Write-Warn "$key still has the public template value. Change it (and everything that depends on it) by hand, or reinstall." }
    }
}

# The worker creates/migrates the schema (and seeds the feature flags) after
# every start of a new image; wait for it before touching feature flags.
function Wait-Migrations([int]$TimeoutMinutes = 15) {
    Write-Step "Waiting for the database migration to finish"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Push-Location $script:Root
    try {
        while ((Get-Date) -lt $deadline) {
            $logs = (& docker compose logs --no-color worker 2>$null) -join "`n"
            if ($logs -match "Completed updating the core Resgrid databases") { return $true }
            Start-Sleep -Seconds 5
        }
    }
    finally { Pop-Location }
    Write-Warn "The worker hasn't reported a finished migration after $TimeoutMinutes minutes (.\resgrid.ps1 logs worker)."
    return $false
}

# Earlier versions (May-October 2026) kept PostgreSQL data inside the db
# container: the hardened image keeps it in /var/lib/postgresql/18/data, which
# their docker-data\sql mount missed. Recreating that container would delete
# the data, so it is saved as an image first. Containers of an older project
# name are stopped (and kept) so their ports are free.
function Save-LegacyContainers {
    $ids = @(& docker ps -aq --filter "label=com.docker.compose.project.working_dir=$script:Root" --filter "label=com.docker.compose.service=db" 2>$null) +
        @(& docker ps -aq --filter "label=com.docker.compose.project=resgrid" --filter "label=com.docker.compose.service=db" 2>$null)
    foreach ($id in @($ids | Where-Object { $_ } | Sort-Object -Unique)) {
        $short = $id.Substring(0, 12)
        $mounts = & docker inspect -f "{{range .Mounts}}{{.Name}} {{end}}" $id 2>$null
        if ("$mounts" -match "postgres-data") { continue }   # this version's database
        $tag = "resgrid-legacy-db:$short"
        & docker image inspect $tag *> $null
        if ($LASTEXITCODE -eq 0) { continue }
        & docker cp "${id}:/var/lib/postgresql/18/data/PG_VERSION" - *> $null
        if ($LASTEXITCODE -ne 0) { continue }
        Write-Step "Saving the database of the previous version (container $short) as image $tag"
        & docker update --restart=no $id *> $null
        & docker stop $id *> $null
        & docker commit $id $tag *> $null
        if ($LASTEXITCODE -ne 0) { throw "Saving the database from container $short failed (disk full?). Nothing else was changed; the container is only stopped (docker start $short)." }
    }
    foreach ($id in @(& docker ps -q --filter "label=com.docker.compose.project.working_dir=$script:Root" 2>$null | Where-Object { $_ })) {
        $project = & docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' $id 2>$null
        if ($project -eq "resgrid") { continue }
        & docker update --restart=no $id *> $null
        & docker stop $id *> $null
        Write-Step "Stopped container $($id.Substring(0, 12)) of the previous version (project $project). It is kept; remove it once you no longer need it."
    }
}

# Copy the saved database into this version's database, once, while that one
# is still empty (so nothing is overwritten).
function Copy-LegacyDatabase([switch]$NonInteractive) {
    $marker = Join-Path $script:Root ".legacy-db-migrated"
    if (Test-Path -LiteralPath $marker) { return }
    $tag = @(& docker images "resgrid-legacy-db" --format "{{.Repository}}:{{.Tag}}" 2>$null | Where-Object { $_ }) | Select-Object -First 1
    if (-not $tag) { return }
    $user = Get-EnvValue "POSTGRES_USER"
    Invoke-Compose up -d db
    Push-Location $script:Root
    try {
        for ($i = 0; $i -lt 60; $i++) {
            & docker compose exec -T db pg_isready -q *> $null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds 2
        }
        & docker compose up -d db-init *> $null
        $tables = "$(& docker compose exec -T db psql -At -U $user -d resgrid -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>$null)".Trim()
    }
    finally { Pop-Location }
    if ($tables -and $tables -ne "0") {
        Write-Warn "Found the database of a previous version (image $tag), but the current database already has data. Not copying it."
        [System.IO.File]::WriteAllText($marker, [DateTimeOffset]::Now.ToString("O"))
        return
    }
    if (-not $NonInteractive) {
        $answer = Read-Host "Copy your data from the previous version (image $tag) into this install? (y/n) [y]"
        if ($answer -and $answer -notmatch '^(y|yes)$') { return }
    }
    $backups = Join-Path $script:Root "backups"
    [void](New-Item -ItemType Directory -Force -Path $backups)
    $dump = Join-Path $backups ("legacy-db-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".sql")
    Write-Step "Copying the database of the previous version (image $tag is not changed)"
    & docker rm -f resgrid-legacy-db *> $null
    Invoke-Docker run -d --name resgrid-legacy-db --entrypoint docker-entrypoint.sh -e POSTGRES_PASSWORD=unused $tag postgres | Out-Null
    try {
        for ($i = 0; $i -lt 60; $i++) {
            & docker exec resgrid-legacy-db pg_isready -q -U $user *> $null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds 2
        }
        Invoke-Docker exec resgrid-legacy-db sh -c "pg_dumpall -U '$user' --clean --if-exists > /tmp/legacy.sql"
        Invoke-Docker cp resgrid-legacy-db:/tmp/legacy.sql $dump
    }
    finally { & docker rm -f resgrid-legacy-db *> $null }
    Write-Step "Loading it into the current database (a copy of the dump is in backups\$(Split-Path $dump -Leaf))"
    Invoke-Compose cp $dump db:/tmp/legacy.sql
    Push-Location $script:Root
    try {
        & docker compose exec -T db sh -c "psql -q -U '$user' -d postgres -f /tmp/legacy.sql > /dev/null 2> /tmp/legacy.log" *> $null
        & docker compose exec -T -u 0 db rm -f /tmp/legacy.sql /tmp/legacy.log *> $null
    }
    finally { Pop-Location }
    [System.IO.File]::WriteAllText($marker, [DateTimeOffset]::Now.ToString("O"))
    Write-Ok "Data of the previous version copied. The worker upgrades its schema when Resgrid starts."
}

function ConvertTo-Pem([string]$Label, [byte[]]$Bytes) {
    $b64 = [Convert]::ToBase64String($Bytes)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("-----BEGIN $Label-----`n")
    for ($i = 0; $i -lt $b64.Length; $i += 64) { [void]$sb.Append($b64.Substring($i, [Math]::Min(64, $b64.Length - $i)) + "`n") }
    [void]$sb.Append("-----END $Label-----`n")
    return $sb.ToString()
}

# Resgrid's local certificate authority: Caddy issues the site certificates
# from it, the containers trust it, and Windows trusts it after Import-Ca.
function New-LocalCa([string]$Name) {
    if ((Test-Path -LiteralPath $script:CaCertPath) -and (Test-Path -LiteralPath $script:CaKeyPath)) {
        Write-Step "Keeping the existing local CA (certs\ca\resgrid-root-ca.crt)."
        return
    }
    Write-Step "Creating the Resgrid local certificate authority (10 year validity)"
    if ($PSVersionTable.PSEdition -eq "Core") {
        $key = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
    }
    else {
        $key = [System.Security.Cryptography.ECDsaCng]::new(256)
    }
    try {
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=Resgrid Local CA $Name, O=Resgrid self-hosted", [System.Security.Cryptography.ECDsa]$key,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
        $usage = [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign
        $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new($usage, $true))
        $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new($request.PublicKey, $false))
        $cert = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddYears(10))
        if ($PSVersionTable.PSEdition -eq "Core") { $pkcs8 = $key.ExportPkcs8PrivateKey() }
        else { $pkcs8 = $key.Key.Export([System.Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob) }
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $script:CaCertPath), (Split-Path $script:CaKeyPath))
        [System.IO.File]::WriteAllText($script:CaCertPath, (ConvertTo-Pem "CERTIFICATE" $cert.RawData), [System.Text.Encoding]::ASCII)
        [System.IO.File]::WriteAllText($script:CaKeyPath, (ConvertTo-Pem "PRIVATE KEY" $pkcs8), [System.Text.Encoding]::ASCII)
        $cert.Dispose()
    }
    finally { $key.Dispose() }
}

# Trust the local CA for the current Windows user (Chrome and Edge use this
# store). Windows asks for confirmation.
function Import-Ca {
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($script:CaCertPath)
    $existing = Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
    if ($existing) { Write-Step "Windows already trusts the Resgrid local CA."; return }
    Write-Step "Trusting the Resgrid local CA for your Windows account (answer Yes in the Windows prompt)"
    [void](Import-Certificate -FilePath $script:CaCertPath -CertStoreLocation Cert:\CurrentUser\Root)
}

# OpenIddict signing/encryption certificate: base64 PKCS#12, empty password.
function New-OidcCertificate([string]$CommonName, [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]$Usage) {
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new("CN=$CommonName", $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new($Usage, $true))
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddYears(10))
        try { return [Convert]::ToBase64String($certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, [string]::Empty)) }
        finally { $certificate.Dispose() }
    }
    finally { $rsa.Dispose() }
}

function Test-PortInUse([int]$Port) {
    return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Get-WebUrl {
    $port = Get-EnvValue "RESGRID_HTTPS_PORT"
    $suffix = if ([string]::IsNullOrEmpty($port) -or $port -eq "443") { "" } else { ":$port" }
    return "https://$(Get-EnvValue 'RESGRID_WEB_HOST')$suffix"
}

# Poll the API and web app through Caddy until they answer.
function Wait-Resgrid([int]$TimeoutMinutes = 10) {
    $port = Get-EnvValue "RESGRID_HTTPS_PORT"
    if ([string]::IsNullOrEmpty($port)) { $port = "443" }
    $api = Get-EnvValue "RESGRID_API_HOST"
    $web = Get-EnvValue "RESGRID_WEB_HOST"
    Write-Step "Waiting for Resgrid to answer (the first start creates the database, 5-10 minutes)"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        & curl.exe -ksf -o NUL --max-time 5 --resolve "${api}:${port}:127.0.0.1" "https://${api}:${port}/health" 2>$null
        $apiOk = $LASTEXITCODE -eq 0
        & curl.exe -ksf -o NUL --max-time 10 --resolve "${web}:${port}:127.0.0.1" "https://${web}:${port}/Health/GetCurrent" 2>$null
        if ($apiOk -and $LASTEXITCODE -eq 0) { Write-Ok "Resgrid is up."; return $true }
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 5
    }
    Write-Host ""
    Write-Warn "Resgrid did not answer within $TimeoutMinutes minutes. Check: .\resgrid.ps1 logs worker"
    return $false
}
