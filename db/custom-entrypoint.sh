set -e

# Start PostgreSQL in the background
docker-entrypoint.sh postgres &

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
until pg_isready -h 127.0.0.1 -U $POSTGRES_USER
do
  echo "Waiting for PostgreSQL to be ready..."
  sleep 1
done

echo "PostgreSQL is ready - creating databases..."
# Run our database creation script
/create-databases.sh

# Keep the container running
wait