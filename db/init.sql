DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'resgrid') THEN
        CREATE DATABASE resgrid;
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'resgridoidc') THEN
        CREATE DATABASE resgridoidc;
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'resgridworkers') THEN
        CREATE DATABASE resgridworkers;
    END IF;
END
$$;
