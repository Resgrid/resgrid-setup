# shellcheck shell=bash
#
# Optional-feature setup shared by the setup scripts. Reads features/catalog.ini
# and the feature flags in the Resgrid database, asks one question per feature
# (or applies RESGRID_FEATURES), writes the feature's settings to the env file,
# switches its flags for the whole server and clears the flag cache.
#
# The sourcing script provides:
#   FEAT_CATALOG              path of catalog.ini
#   feat_psql <sql>           runs SQL on the "resgrid" database, prints psql -At rows
#   feat_redis <args...>      runs redis-cli against Resgrid's Redis
#   get_env <key> / upsert_env <key> <value>   read / write the env file
#   prompt <question> <default>, info, warn
# FEAT_PROFILE_KEY names the env key listing the optional services that run
# (default COMPOSE_PROFILES); the script may also override feat_profile <name> <on|off>.
#
# After features_run: FEAT_ENV_CHANGED=1 if the env file changed (restart the
# containers), FEAT_FLAGS_CHANGED=1 if flags changed, FEAT_PROFILES_OFF lists
# the profiles switched off (stop their services). Works with bash 3.2.

# shellcheck disable=SC2034  # results are read by the sourcing script
FEAT_SECTIONS=""
FEAT_DB=""
FEAT_ENV_CHANGED=0
FEAT_FLAGS_CHANGED=0
FEAT_PROFILES_OFF=""

feat_sid() { printf '%s' "$1" | tr -c 'A-Za-z0-9\n' '_'; }

feat_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# feat_get <section> <key>: value (repeatable keys: one per line)
feat_get() { local v; v="FS_$(feat_sid "$1")_$2"; printf '%s' "${!v:-}"; }

feat_add() {
  local v cur
  v="FS_$(feat_sid "$1")_$2"
  cur="${!v:-}"
  if [ -n "$cur" ]; then printf -v "$v" '%s\n%s' "$cur" "$3"; else printf -v "$v" '%s' "$3"; fi
}

feat_load_catalog() {
  FEAT_SECTIONS=""
  local line sec="" key val
  [ -f "$FEAT_CATALOG" ] || { warn "Feature catalog $FEAT_CATALOG not found; skipping optional features."; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(feat_trim "${line%$'\r'}")"
    case "$line" in ''|'#'*|';'*) continue ;; esac
    case "$line" in
      '['*']') sec="${line#[}"; sec="${sec%]}"; FEAT_SECTIONS="$FEAT_SECTIONS $sec"; continue ;;
    esac
    [ -n "$sec" ] || continue
    key="$(feat_trim "${line%%=*}")"; val="$(feat_trim "${line#*=}")"
    feat_add "$sec" "$key" "$val"
  done < "$FEAT_CATALOG"
}

# Flags present in the database: "key|category|t-or-f" per line.
feat_load_db() {
  FEAT_DB="$(feat_psql "SELECT flagkey || '|' || coalesce(category, '') || '|' || CASE WHEN isenabledglobally THEN 't' ELSE 'f' END FROM featureflags WHERE NOT isarchived ORDER BY flagkey;")"
}

# Flag keys of a section that exist in this database, one per line.
feat_flags_of() {
  local cat flags excl k c e
  cat="$(feat_get "$1" category)"; flags=" $(feat_get "$1" flags) "; excl=" $(feat_get "$1" exclude) "
  while IFS='|' read -r k c e; do
    [ -n "$k" ] || continue
    case "$excl" in *" $k "*) continue ;; esac
    if [ -n "$cat" ] && [ "$c" = "$cat" ]; then printf '%s\n' "$k"; continue; fi
    case "$flags" in *" $k "*) printf '%s\n' "$k" ;; esac
  done <<EOF
$FEAT_DB
EOF
}

# (No grep -q in a pipe anywhere: under pipefail its early exit reads as failure.)
feat_flag_on() {
  local k c e
  while IFS='|' read -r k c e; do
    [ "$k" = "$1" ] && [ "$e" = t ] && return 0
  done <<EOF
$FEAT_DB
EOF
  return 1
}

# on | off | partial | none (no flags of this section in the database)
feat_state() {
  local total=0 on=0 k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    total=$((total + 1)); feat_flag_on "$k" && on=$((on + 1))
  done <<EOF
$(feat_flags_of "$1")
EOF
  # A section without flags (e.g. ClamAV) is "on" when its profile runs.
  if [ "$total" -eq 0 ]; then
    local p; p="$(feat_get "$1" profile)"
    if [ -n "$p" ] && [ "$(feat_get "$1" flags)$(feat_get "$1" category)" = "" ]; then
      case ",$(get_env "${FEAT_PROFILE_KEY:-COMPOSE_PROFILES}")," in *",$p,"*) echo on ;; *) echo off ;; esac
      return
    fi
    echo none; return
  fi
  if [ "$on" -eq 0 ]; then echo off; elif [ "$on" -eq "$total" ]; then echo on; else echo partial; fi
}

feat_available() { [ "$(feat_get "$1" available)" != "no" ]; }

# Replace {KEY} with that key's value from the env file.
feat_expand() {
  local s="$1" k
  while [[ "$s" =~ \{([A-Za-z0-9_]+)\} ]]; do
    k="${BASH_REMATCH[1]}"
    s="${s//\{$k\}/$(get_env "$k")}"
  done
  printf '%s' "$s"
}

feat_set() { # feat_set <key> <value>: write only when different
  [ "$(get_env "$1")" = "$2" ] && return 0
  upsert_env "$1" "$2"; FEAT_ENV_CHANGED=1
}

# Setup's own bookkeeping (RESGRID_FEATURES*): no service reads it, no restart.
feat_note() { [ "$(get_env "$1")" = "$2" ] || upsert_env "$1" "$2"; }

# Default profile handling: keep COMPOSE_PROFILES in the env file in step
# (docker compose reads it, so `docker compose up -d` starts those services).
feat_profile() { # feat_profile <name> <on|off>
  local cur new="" p
  cur="$(get_env "${FEAT_PROFILE_KEY:-COMPOSE_PROFILES}")"
  for p in $(printf '%s' "$cur" | tr ',' ' '); do [ "$p" = "$1" ] || new="${new:+$new,}$p"; done
  [ "$2" = on ] && new="${new:+$new,}$1"
  if [ "$2" = off ] && [ "$new" != "$cur" ]; then FEAT_PROFILES_OFF="$FEAT_PROFILES_OFF $1"; fi
  feat_set "${FEAT_PROFILE_KEY:-COMPOSE_PROFILES}" "$new"
}

feat_sql_list() { local out="" k; for k in "$@"; do out="${out:+$out, }'$k'"; done; printf '%s' "$out"; }

feat_apply_flags() { # feat_apply_flags <on|off> <keys...>
  local mode="$1"; shift
  [ "$#" -gt 0 ] || return 0
  if [ "$mode" = on ]; then
    feat_psql "UPDATE featureflags SET isenabledglobally = true, updatedon = now() WHERE flagkey IN ($(feat_sql_list "$@")) AND NOT isenabledglobally;" >/dev/null
  else
    feat_psql "UPDATE featureflags SET isenabledglobally = false, updatedon = now() WHERE flagkey IN ($(feat_sql_list "$@")) AND isenabledglobally;" >/dev/null
  fi
  FEAT_FLAGS_CHANGED=1
}

# Flags are cached in Redis (FeatureFlags_All, FeatureFlagOverrides_<id>, ...).
feat_clear_cache() {
  local keys
  keys="$(feat_redis --scan --pattern '*FeatureFlag*' 2>/dev/null | tr -d '\r')"
  [ -n "$keys" ] || return 0
  # shellcheck disable=SC2086
  feat_redis DEL $keys >/dev/null 2>&1 || true
}

feat_switch() { # feat_switch <section> <on|off>
  local sec="$1" mode="$2" line key q def cur ans flags
  if [ "$mode" = on ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      key="${line%%|*}"; q="${line#*|}"; def="${q#*|}"; q="${q%%|*}"
      [ "$def" = "$q" ] && def=""
      cur="$(get_env "$key")"
      if [ -n "${!key:-}" ]; then ans="${!key}"
      elif [ "$FEAT_INTERACTIVE" = 1 ]; then ans="$(prompt "    $q" "${cur:-$def}")"
      else ans="${cur:-$def}"; fi
      feat_set "$key" "$ans"
    done <<EOF
$(feat_get "$sec" ask)
EOF
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      feat_set "${line%%=*}" "$(feat_expand "${line#*=}")"
    done <<EOF
$(feat_get "$sec" setting)
EOF
  else
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      feat_set "${line%%=*}" "$(feat_expand "${line#*=}")"
    done <<EOF
$(feat_get "$sec" off)
EOF
  fi
  [ -n "$(feat_get "$sec" profile)" ] && feat_profile "$(feat_get "$sec" profile)" "$mode"
  flags="$(feat_flags_of "$sec" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  [ -n "$flags" ] && feat_apply_flags "$mode" $flags
  return 0
}

feat_in_list() { case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# Sections recorded as on (RESGRID_FEATURES) that are off or partly off: a
# restored database, or flags a new Core version added to the feature
# (seeded off). Switch them fully on again.
feat_heal() {
  local sec
  for sec in $(get_env RESGRID_FEATURES | tr ',' ' '); do
    feat_available "$sec" || continue
    case "$(feat_state "$sec")" in
      off|partial) feat_switch "$sec" on; info "$(feat_get "$sec" title): on again (recorded in RESGRID_FEATURES)" ;;
    esac
  done
  return 0
}

# features_run [--all] [--new]
#   Interactive when a terminal is available and RESGRID_FEATURES isn't set.
#   RESGRID_FEATURES=records,search (or all / none) sets the wanted features
#   without questions; sections not listed are switched off.
#   --all  also offers the flags no catalog section covers
#   --new  (setup re-runs) asks only about sections not offered before
#          (RESGRID_FEATURES_OFFERED); with none, asks whether to change any
features_run() {
  local all=0 only_new=0 arg sec state wanted decided="" recommended="" title answer def enabled_list="" n=0 count=0 hosted=""
  local offered="" fresh="" shown=""
  for arg in "$@"; do
    case "$arg" in --all) all=1 ;; --new) only_new=1 ;; esac
  done
  # shellcheck disable=SC2034
  FEAT_ENV_CHANGED=0; FEAT_FLAGS_CHANGED=0; FEAT_PROFILES_OFF=""
  feat_load_catalog || return 0
  feat_load_db
  if [ -z "$FEAT_DB" ]; then
    warn "The database has no feature flags yet (still migrating?). Run the feature setup again later."
    return 0
  fi

  wanted="${RESGRID_FEATURES:-}"
  FEAT_INTERACTIVE=0
  if [ -z "$wanted" ] && { : </dev/tty >/dev/tty; } 2>/dev/null && [ "${RESGRID_NONINTERACTIVE:-0}" != 1 ]; then FEAT_INTERACTIVE=1; fi
  # Setup re-runs first put the recorded features back where needed.
  [ "$only_new" = 1 ] && [ -z "$wanted" ] && feat_heal
  if [ "$FEAT_INTERACTIVE" = 0 ] && [ -z "$wanted" ]; then
    # No terminal and nothing requested: leave the other features as they are.
    if [ "$FEAT_FLAGS_CHANGED" = 1 ]; then feat_clear_cache; fi
    return 0
  fi
  if [ "$wanted" = all ]; then
    wanted=""; for sec in $FEAT_SECTIONS; do feat_available "$sec" && wanted="$wanted,$sec"; done
  fi

  # Sections that can be offered here (available, and Core has their flags).
  for sec in $FEAT_SECTIONS; do
    feat_available "$sec" || continue
    [ "$(feat_state "$sec")" = none ] && continue
    shown="${shown:+$shown,}$sec"
  done
  offered="$(get_env RESGRID_FEATURES_OFFERED)"
  if [ "$FEAT_INTERACTIVE" = 1 ] && [ "$only_new" = 1 ] && [ -n "$offered" ]; then
    for sec in $(printf '%s' "$shown" | tr ',' ' '); do
      feat_in_list "$sec" "$offered" || fresh="${fresh:+$fresh,}$sec"
    done
    if [ -z "$fresh" ]; then
      printf '\n' >/dev/tty
      answer="$(prompt "Change the optional features (now on: $(get_env RESGRID_FEATURES | sed 's/,/, /g'))? (y/n)" n)"
      case "$answer" in y|Y|yes|YES|Yes) only_new=0 ;; *) return 0 ;; esac
    fi
  else
    only_new=0
  fi
  for sec in $(printf '%s' "$shown" | tr ',' ' '); do
    if [ "$only_new" = 0 ] || feat_in_list "$sec" "$fresh"; then count=$((count + 1)); fi
  done

  if [ "$FEAT_INTERACTIVE" = 1 ]; then
    printf '\n'
    if [ "$only_new" = 1 ]; then
      info "New optional features"
      printf '%s\n' "    This version of Resgrid adds optional features you haven't been asked about." \
                    "    Your other features stay as they are (change them with ./setup.sh features)."
    else
      info "Optional features"
      printf '%s\n' "    Resgrid ships some modules switched off. Answer y to turn a feature on for" \
                    "    every department on this server, n to turn it off; Enter takes the answer" \
                    "    in brackets. Run this again any time with: ./setup.sh features"
    fi
  fi

  for sec in $FEAT_SECTIONS; do
    if ! feat_available "$sec"; then
      [ -n "$(feat_flags_of "$sec")" ] && hosted="$hosted, $(feat_get "$sec" title)"
      continue
    fi
    state="$(feat_state "$sec")"
    [ "$state" = none ] && continue
    if [ "$only_new" = 1 ] && ! feat_in_list "$sec" "$fresh"; then
      # Not asked this time: keep it as it is.
      case "$state" in on|partial) enabled_list="${enabled_list:+$enabled_list,}$sec" ;; esac
      continue
    fi
    n=$((n + 1))
    title="$(feat_get "$sec" title)"
    if [ "$FEAT_INTERACTIVE" = 1 ]; then
      printf '\n  [%d/%d] %s  (now: %s)\n' "$n" "$count" "$title" "$state" >/dev/tty
      { feat_get "$sec" about; printf '\n'; } | sed 's/^/        /' >/dev/tty
      [ "$(feat_get "$sec" online)" = yes ] && printf '        Needs internet access while in use.\n' >/dev/tty
      if feat_in_list "$sec" "$decided"; then
        printf '        On (required by another feature you chose).\n' >/dev/tty
        answer=y
      else
        def=n; { [ "$state" = on ] || [ "$state" = partial ] || feat_in_list "$sec" "$recommended"; } && def=y
        answer="$(prompt "        Turn on $title? (y/n)" "$def")"
      fi
    else
      if feat_in_list "$sec" "$wanted" || feat_in_list "$sec" "$decided"; then answer=y; else answer=n; fi
    fi
    case "$answer" in
      y|Y|yes|YES|Yes)
        feat_switch "$sec" on
        enabled_list="${enabled_list:+$enabled_list,}$sec"
        local r
        for r in $(feat_get "$sec" requires); do decided="$decided,$r"; done
        for r in $(feat_get "$sec" recommends); do recommended="$recommended,$r"; done
        [ "$state" = on ] || info "$title: on"
        ;;
      *)
        if [ "$state" != off ]; then feat_switch "$sec" off; info "$title: off"; fi
        ;;
    esac
  done

  # Requirements that come earlier in the catalog than the feature needing them.
  for sec in $(printf '%s' "$decided" | tr ',' ' '); do
    feat_in_list "$sec" "$enabled_list" && continue
    feat_available "$sec" || continue
    feat_switch "$sec" on; enabled_list="$enabled_list,$sec"
    info "$(feat_get "$sec" title): on (required)"
  done

  if [ -n "$hosted" ] && [ "$FEAT_INTERACTIVE" = 1 ] && [ "$only_new" = 0 ]; then
    printf '\n    Not available on self-hosted servers (Resgrid subscription add-ons): %s\n' "${hosted#, }" >/dev/tty
  fi

  [ "$all" = 1 ] && feat_run_other

  feat_note RESGRID_FEATURES "$enabled_list"
  for sec in $(printf '%s' "$shown" | tr ',' ' '); do
    feat_in_list "$sec" "$offered" || offered="${offered:+$offered,}$sec"
  done
  feat_note RESGRID_FEATURES_OFFERED "$offered"
  [ "$FEAT_FLAGS_CHANGED" = 1 ] && feat_clear_cache
  return 0
}

# Flags no catalog section covers (new in Core, or catalog not updated yet).
feat_run_other() {
  local covered="" sec k c e answer def
  for sec in $FEAT_SECTIONS; do covered="$covered $(feat_flags_of "$sec" | tr '\n' ' ')"; done
  [ "$FEAT_INTERACTIVE" = 1 ] || return 0
  printf '\n  Other feature flags (not in features/catalog.ini):\n' >/dev/tty
  while IFS='|' read -r k c e; do
    [ -n "$k" ] || continue
    case " $covered " in *" $k "*) continue ;; esac
    def=n; [ "$e" = t ] && def=y
    answer="$(prompt "    $k ($c)? (y/n)" "$def")"
    case "$answer" in
      y|Y|yes|Yes) [ "$e" = t ] || { feat_apply_flags on "$k"; info "$k: on"; } ;;
      *) [ "$e" = t ] && { feat_apply_flags off "$k"; info "$k: off"; } ;;
    esac
  done <<EOF
$FEAT_DB
EOF
}
