#!/bin/bash
set -e

# Function to create database if it doesn't exist
create_db() {
    local dbname=$1
    echo "Creating PostgreSQL database $dbname"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -tc "SELECT 1 FROM pg_database WHERE datname = '$dbname'" | grep -q 1 || psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "CREATE DATABASE $dbname"
}

# Create the databases
create_db "resgrid"
create_db "resgridoidc"
create_db "resgridworkers"