sysctl -w vm.max_map_count=262144
mkdir -p docker-data/sql/
docker-compose --project-name resgird up