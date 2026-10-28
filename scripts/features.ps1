# Optional-feature setup for the laptop install (PowerShell version of
# lib/features.sh). Reads features\catalog.ini and the feature flags in the
# Resgrid database, asks one question per feature (or applies -Features),
# writes the feature's settings to .env, switches its flags for the whole
# server and clears the flag cache. Dot-source after scripts\common.ps1.

$script:FeatureCatalogPath = Join-Path $script:Root "features\catalog.ini"

function Read-FeatureCatalog {
    $sections = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($raw in [System.IO.File]::ReadAllLines($script:FeatureCatalogPath)) {
        $line = $raw.Trim()
        if ($line -eq "" -or $line.StartsWith("#") -or $line.StartsWith(";")) { continue }
        if ($line -match '^\[(.+)\]$') {
            $current = [ordered]@{ name = $Matches[1]; about = @(); setting = @(); off = @(); ask = @() }
            $sections.Add($current)
            continue
        }
        if ($null -eq $current -or $line -notmatch '^([^=]+)=(.*)$') { continue }
        $key = $Matches[1].Trim(); $value = $Matches[2].Trim()
        if ($key -in @("about", "setting", "off", "ask")) { $current[$key] += $value } else { $current[$key] = $value }
    }
    return $sections
}

function Invoke-FeatureSql([string]$Sql) {
    $user = Get-EnvValue "POSTGRES_USER"
    Push-Location $script:Root
    try {
        $out = & docker compose exec -T db psql -v ON_ERROR_STOP=1 -At -U $user -d resgrid -c $Sql
        if ($LASTEXITCODE -ne 0) { throw "Database query failed." }
        return $out
    }
    finally { Pop-Location }
}

function Get-FeatureDbFlags {
    $rows = Invoke-FeatureSql "SELECT flagkey || '|' || coalesce(category, '') || '|' || CASE WHEN isenabledglobally THEN 't' ELSE 'f' END FROM featureflags WHERE NOT isarchived ORDER BY flagkey;"
    $flags = @()
    foreach ($row in @($rows)) {
        if (-not $row) { continue }
        $parts = $row.Split('|')
        $flags += [pscustomobject]@{ Key = $parts[0]; Category = $parts[1]; Enabled = ($parts[2] -eq "t") }
    }
    return $flags
}

function Get-FeatureFlagKeys($Section, $DbFlags) {
    $flags = @(); if ($Section.Contains("flags")) { $flags = $Section.flags -split '\s+' }
    $exclude = @(); if ($Section.Contains("exclude")) { $exclude = $Section.exclude -split '\s+' }
    $category = if ($Section.Contains("category")) { $Section.category } else { "" }
    return @($DbFlags | Where-Object {
            $_.Key -notin $exclude -and (($category -and $_.Category -eq $category) -or ($_.Key -in $flags))
        } | ForEach-Object { $_.Key })
}

function Get-FeatureState($Section, $DbFlags) {
    $keys = @(Get-FeatureFlagKeys $Section $DbFlags)
    if ($keys.Count -eq 0) {
        if ($Section.Contains("profile") -and -not $Section.Contains("flags") -and -not $Section.Contains("category")) {
            $profiles = @((Get-EnvValue "COMPOSE_PROFILES") -split ',')
            return $(if ($Section.profile -in $profiles) { "on" } else { "off" })
        }
        return "none"
    }
    $on = @($DbFlags | Where-Object { $_.Key -in $keys -and $_.Enabled }).Count
    if ($on -eq 0) { return "off" }
    if ($on -eq $keys.Count) { return "on" }
    return "partial"
}

# Replace {KEY} with that key's value from .env.
function Expand-FeatureValue([string]$Value) {
    return [regex]::Replace($Value, '\{([A-Za-z0-9_]+)\}', { param($m) [string](Get-EnvValue $m.Groups[1].Value) })
}

function Set-FeatureEnv([string]$Key, [string]$Value, [switch]$Note) {
    if ((Get-EnvValue $Key) -eq $Value) { return }
    Set-EnvValueOrAdd $Key $Value
    # -Note: setup's own bookkeeping (RESGRID_FEATURES*), no service reads it, no restart.
    if (-not $Note) { $script:FeatureEnvChanged = $true }
}

function Set-FeatureProfile([string]$Name, [bool]$On) {
    $current = @((Get-EnvValue "COMPOSE_PROFILES") -split ',' | Where-Object { $_ })
    $new = @($current | Where-Object { $_ -ne $Name })
    if ($On) { $new += $Name }
    elseif ($current.Count -ne $new.Count) { $script:FeatureProfilesOff += $Name }
    Set-FeatureEnv "COMPOSE_PROFILES" ($new -join ',')
}

function Set-FeatureFlags([string[]]$Keys, [bool]$On) {
    if (-not $Keys -or $Keys.Count -eq 0) { return }
    $list = ($Keys | ForEach-Object { "'$_'" }) -join ", "
    if ($On) { [void](Invoke-FeatureSql "UPDATE featureflags SET isenabledglobally = true, updatedon = now() WHERE flagkey IN ($list) AND NOT isenabledglobally;") }
    else { [void](Invoke-FeatureSql "UPDATE featureflags SET isenabledglobally = false, updatedon = now() WHERE flagkey IN ($list) AND isenabledglobally;") }
    $script:FeatureFlagsChanged = $true
}

# Flags are cached in Redis (FeatureFlags_All, FeatureFlagOverrides_<id>, ...).
function Clear-FeatureCache {
    $password = Get-EnvValue "REDIS_PASSWORD"
    Push-Location $script:Root
    try {
        $keys = @(& docker compose exec -T redis redis-cli --no-auth-warning -a $password --scan --pattern '*FeatureFlag*' 2>$null | Where-Object { $_ })
        if ($keys.Count -gt 0) { & docker compose exec -T redis redis-cli --no-auth-warning -a $password DEL @keys *> $null }
    }
    finally { Pop-Location }
}

function Switch-Feature($Section, [bool]$On, $DbFlags, [bool]$Interactive) {
    if ($On) {
        foreach ($line in $Section.ask) {
            $parts = $line.Split('|')
            $key = $parts[0]; $question = $parts[1]; $default = if ($parts.Count -gt 2) { $parts[2] } else { "" }
            $current = Get-EnvValue $key
            $fromEnvironment = [Environment]::GetEnvironmentVariable($key)
            if ($fromEnvironment) { $answer = $fromEnvironment }
            elseif ($Interactive) {
                $suggest = if ($current) { $current } else { $default }
                $answer = Read-Host "        $question [$suggest]"
                if (-not $answer) { $answer = $suggest }
            }
            else { $answer = if ($current) { $current } else { $default } }
            Set-FeatureEnv $key $answer
        }
        foreach ($line in $Section.setting) {
            $key, $value = $line.Split('=', 2)
            Set-FeatureEnv $key (Expand-FeatureValue $value)
        }
    }
    else {
        foreach ($line in $Section.off) {
            $key, $value = $line.Split('=', 2)
            Set-FeatureEnv $key (Expand-FeatureValue $value)
        }
    }
    if ($Section.Contains("profile")) { Set-FeatureProfile $Section.profile $On }
    Set-FeatureFlags (Get-FeatureFlagKeys $Section $DbFlags) $On
}

function Test-Yes([string]$Answer) { return $Answer -match '^(y|yes)$' }

# Invoke-Features [-Wanted "records,search"|"all"|"none"] [-All] [-NonInteractive] [-OnlyNew]
#   Interactive unless -Wanted is given. Sections not in -Wanted are switched off.
#   -OnlyNew (setup re-runs): ask only about sections not offered before
#   (RESGRID_FEATURES_OFFERED); with none, ask whether to change any.
function Invoke-Features([string]$Wanted = "", [switch]$All, [switch]$NonInteractive, [switch]$OnlyNew) {
    $script:FeatureEnvChanged = $false
    $script:FeatureFlagsChanged = $false
    $script:FeatureProfilesOff = @()
    if (-not (Test-Path -LiteralPath $script:FeatureCatalogPath)) { Write-Warn "features\catalog.ini not found; skipping optional features."; return }
    $catalog = Read-FeatureCatalog
    $db = @(Get-FeatureDbFlags)
    if ($db.Count -eq 0) { Write-Warn "The database has no feature flags yet (still migrating?). Run .\resgrid.ps1 features later."; return }

    # Setup re-runs first put the recorded features back where needed: a restored
    # database, or flags a new Core version added to a feature (seeded off).
    if ($OnlyNew -and -not $Wanted) {
        foreach ($name in @((Get-EnvValue "RESGRID_FEATURES") -split ',' | Where-Object { $_ })) {
            $section = $catalog | Where-Object { $_.name -eq $name -and $_["available"] -ne "no" } | Select-Object -First 1
            if ($section -and (Get-FeatureState $section $db) -in @("off", "partial")) {
                Switch-Feature $section $true $db $false
                Write-Ok "$($section.title): on again (recorded in RESGRID_FEATURES)"
            }
        }
        if ($script:FeatureFlagsChanged) { $db = @(Get-FeatureDbFlags) }
    }

    $interactive = -not $Wanted -and -not $NonInteractive
    if (-not $interactive -and -not $Wanted) { return }
    $wantedList = @($Wanted -split ',' | Where-Object { $_ })
    if ($Wanted -eq "all") { $wantedList = @($catalog | Where-Object { $_["available"] -ne "no" } | ForEach-Object { $_.name }) }

    $shown = @($catalog | Where-Object { $_["available"] -ne "no" -and (Get-FeatureState $_ $db) -ne "none" })
    $offeredBefore = @((Get-EnvValue "RESGRID_FEATURES_OFFERED") -split ',' | Where-Object { $_ })
    $onlyNewMode = $false
    if ($interactive -and $OnlyNew -and $offeredBefore.Count -gt 0) {
        $fresh = @($shown | Where-Object { $_.name -notin $offeredBefore })
        if ($fresh.Count -eq 0) {
            $now = Get-EnvValue "RESGRID_FEATURES"
            Write-Host ""
            $answer = Read-Host "Change the optional features (now on: $(if ($now) { $now -replace ',', ', ' } else { 'none' }))? (y/n) [n]"
            if (-not (Test-Yes $answer)) { return }
        }
        else { $onlyNewMode = $true }
    }
    $asked = @(if ($onlyNewMode) { $fresh } else { $shown })
    if ($interactive) {
        Write-Host ""
        if ($onlyNewMode) {
            Write-Step "New optional features"
            Write-Host "    This version of Resgrid adds optional features you haven't been asked about."
            Write-Host "    Your other features stay as they are (change them with .\resgrid.ps1 features)."
        }
        else {
            Write-Step "Optional features"
            Write-Host "    Resgrid ships some modules switched off. Answer y to turn a feature on for every"
            Write-Host "    department on this computer, n to turn it off; Enter takes the answer in brackets."
            Write-Host "    Run this again any time with: .\resgrid.ps1 features"
        }
    }
    $required = @(); $recommended = @(); $enabled = @(); $n = 0
    foreach ($section in $shown) {
        $state = Get-FeatureState $section $db
        if ($section.name -notin @($asked | ForEach-Object { $_.name })) {
            # Not asked this time: keep it as it is.
            if ($state -in @("on", "partial")) { $enabled += $section.name }
            continue
        }
        $n++
        $title = $section.title
        if ($interactive) {
            Write-Host ""
            Write-Host ("  [{0}/{1}] {2}  (now: {3})" -f $n, $asked.Count, $title, $state) -ForegroundColor White
            foreach ($line in $section.about) { Write-Host "        $line" }
            if ($section["online"] -eq "yes") { Write-Host "        Needs internet access while in use." }
            if ($section.name -in $required) { Write-Host "        On (required by another feature you chose)."; $on = $true }
            else {
                $default = if ($state -in @("on", "partial") -or $section.name -in $recommended) { "y" } else { "n" }
                $answer = Read-Host "        Turn on $title? (y/n) [$default]"
                if (-not $answer) { $answer = $default }
                $on = Test-Yes $answer
            }
        }
        else { $on = ($section.name -in $wantedList -or $section.name -in $required) }

        if ($on) {
            Switch-Feature $section $true $db $interactive
            $enabled += $section.name
            if ($section["requires"]) { $required += ($section.requires -split '\s+') }
            if ($section["recommends"]) { $recommended += ($section.recommends -split '\s+') }
            if ($state -ne "on") { Write-Ok "${title}: on" }
        }
        elseif ($state -ne "off") {
            Switch-Feature $section $false $db $interactive
            Write-Ok "${title}: off"
        }
    }
    foreach ($name in $required) {
        if ($name -in $enabled) { continue }
        $section = $catalog | Where-Object { $_.name -eq $name -and $_["available"] -ne "no" } | Select-Object -First 1
        if ($section) { Switch-Feature $section $true $db $interactive; $enabled += $name; Write-Ok "$($section.title): on (required)" }
    }

    if ($interactive -and -not $onlyNewMode) {
        $hosted = @($catalog | Where-Object { $_["available"] -eq "no" -and @(Get-FeatureFlagKeys $_ $db).Count -gt 0 } | ForEach-Object { $_.title })
        if ($hosted.Count -gt 0) { Write-Host ""; Write-Host "    Not available on self-hosted installs (Resgrid subscription add-ons): $($hosted -join ', ')" }
    }

    if ($All -and $interactive) {
        $covered = @($catalog | ForEach-Object { Get-FeatureFlagKeys $_ $db })
        Write-Host ""
        Write-Host "  Other feature flags (not in features\catalog.ini):"
        foreach ($flag in $db | Where-Object { $_.Key -notin $covered }) {
            $default = if ($flag.Enabled) { "y" } else { "n" }
            $answer = Read-Host "    $($flag.Key) ($($flag.Category))? (y/n) [$default]"
            if (-not $answer) { $answer = $default }
            $on = Test-Yes $answer
            if ($on -ne $flag.Enabled) { Set-FeatureFlags @($flag.Key) $on; Write-Ok "$($flag.Key): $(if ($on) { 'on' } else { 'off' })" }
        }
    }

    Set-FeatureEnv "RESGRID_FEATURES" ($enabled -join ',') -Note
    $offeredNow = @($offeredBefore) + @($shown | Where-Object { $_.name -notin $offeredBefore } | ForEach-Object { $_.name })
    Set-FeatureEnv "RESGRID_FEATURES_OFFERED" ($offeredNow -join ',') -Note
    if ($script:FeatureFlagsChanged) { Clear-FeatureCache }
}

# Restart what changed, stop profiles switched off, clear the cache again.
function Complete-FeatureChanges {
    if ($script:FeatureEnvChanged) {
        Write-Step "Restarting the services whose settings changed"
        $base = @(& docker compose config --services 2>$null)
        foreach ($profileName in $script:FeatureProfilesOff) {
            foreach ($service in @(& docker compose --profile $profileName config --services 2>$null)) {
                if ($service -notin $base) { & docker compose --profile $profileName rm -sf $service *> $null }
            }
        }
        Invoke-Compose up -d --remove-orphans
        [void](Wait-Resgrid)
    }
    if ($script:FeatureFlagsChanged) { Clear-FeatureCache }
}
