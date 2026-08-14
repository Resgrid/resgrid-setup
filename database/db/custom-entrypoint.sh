#!/bin/sh
set -e

docker-entrypoint.sh postgres &
postgres_pid="$!"

echo "Waiting for PostgreSQL to be ready..."
until pg_isready -h 127.0.0.1 -U "$POSTGRES_USER"; do
  sleep 1
done

/tmp/create-databases.sh
wait "$postgres_pid"
