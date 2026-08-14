#!/bin/sh
set -e

create_db() {
    dbname="$1"
    echo "Ensuring PostgreSQL database $dbname exists"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -tc "SELECT 1 FROM pg_database WHERE datname = '$dbname'" | grep -q 1 || \
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "CREATE DATABASE $dbname"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -d "$dbname" -c 'CREATE EXTENSION IF NOT EXISTS "citext";'
}

create_db "resgrid"
create_db "resgridoidc"
create_db "resgridworkers"
create_db "resgriddoc"
