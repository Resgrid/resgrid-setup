
SELECT ‘CREATE DATABASE resgrid WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'resgrid')
SELECT ‘CREATE DATABASE resgridoidc WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'resgridoidc')
SELECT ‘CREATE DATABASE resgridworkers WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'resgridworkers')
