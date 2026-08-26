#!/bin/sh
set -eu
umask 077

runtime_password=$(cat /run/secrets/postgres_runtime_password)

psql --set=ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set=runtime_password="$runtime_password" <<'SQL'
SELECT format(
  'CREATE ROLE makerseed_app LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS',
  :'runtime_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'makerseed_app')
\gexec

GRANT CONNECT ON DATABASE makerseed TO makerseed_app;
GRANT USAGE ON SCHEMA public TO makerseed_app;
SQL
