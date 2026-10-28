#!/bin/sh
# Creates the four Resgrid databases if they don't exist. Run by the db-init
# one-shot container once PostgreSQL is healthy; the connection comes from
# PGHOST / PGUSER / PGPASSWORD. Safe to run on every start.
set -eu

for db in resgrid resgridoidc resgridworkers resgriddoc; do
  if [ "$(psql -v ON_ERROR_STOP=1 -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'")" != "1" ]; then
    echo "Creating database $db"
    psql -v ON_ERROR_STOP=1 -d postgres -c "CREATE DATABASE \"$db\""
  fi
  psql -v ON_ERROR_STOP=1 -q -d "$db" -c 'CREATE EXTENSION IF NOT EXISTS citext;'
done

echo "Resgrid databases are ready."
