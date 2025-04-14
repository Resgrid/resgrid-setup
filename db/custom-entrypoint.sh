#!/bin/bash
set -e

# Start PostgreSQL in the background
docker-entrypoint.sh postgres &

# Wait for PostgreSQL to be ready
until pg_isready -U $POSTGRES_USER -d $POSTGRES_DB; do
  echo "Waiting for PostgreSQL to be ready..."
  sleep 1
done

# Run our database creation script
/docker-entrypoint-initdb.d/create-databases.sh

# Keep the container running
wait 