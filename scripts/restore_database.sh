#!/bin/bash

# Replaces the database of a running dockerized TeSS with a dump file from the host.
# Usage: scripts/import_database.sh <dump_file> [production|development]
# If the environment is not given, it is detected from the running app container.
 
set -euo pipefail

DUMP_FILE="${1:-}"
RAILS_ENV="${2:-}"

if [ -z "$DUMP_FILE" ] || [ ! -f "$DUMP_FILE" ]; then
  echo "Usage: $0 <dump_file> [production|development]" >&2
  echo "Dump file not found: '${DUMP_FILE}'" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

# Export variables from source env file
set -a
# Ignore lack of .env file when checking with shellcheck (it might not exist yet)
# shellcheck disable=SC1091
. ./.env
set +a

if [ -z "$RAILS_ENV" ]; then
  RAILS_ENV=$(docker inspect "${PREFIX}-app" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^RAILS_ENV=//p' || true)
  if [ -z "$RAILS_ENV" ]; then
    echo "Could not detect environment (is ${PREFIX}-app running?); using production" >&2
    RAILS_ENV=production
  else
    echo "Detected running environment: $RAILS_ENV"
  fi
fi

case "$RAILS_ENV" in
  production) COMPOSE_FILE="docker-compose-prod.yml" ;;
  development) COMPOSE_FILE="docker-compose.yml" ;;
  *) echo "Unsupported RAILS_ENV: $RAILS_ENV (use production or development)" >&2; exit 1 ;;
esac

DC="docker compose -f $COMPOSE_FILE"
PSQL="$DC exec -T db psql -v ON_ERROR_STOP=1 -U $DB_USER -d postgres"

printf "\n * Stopping app and sidekiq (%s)\n" "$RAILS_ENV"
$DC stop app sidekiq

printf "\n * Recreating database %s\n" "$DB_NAME"
$PSQL -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}' AND pid <> pg_backend_pid();" >/dev/null
$PSQL -c "DROP DATABASE IF EXISTS \"${DB_NAME}\";"
$PSQL -c "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\";"

printf "\n * Restoring %s\n" "$DUMP_FILE"
if [ "$(head -c 5 "$DUMP_FILE")" = "PGDMP" ]; then
  # custom-format archive
  $DC exec -T db pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner --no-acl < "$DUMP_FILE"
else
  # plain SQL (optionally gzipped)
  if [ "$(head -c 2 "$DUMP_FILE" | od -An -tx1 | tr -d ' ')" = "1f8b" ]; then
    gunzip -c "$DUMP_FILE"
  else
    cat "$DUMP_FILE"
  fi | $DC exec -T db psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" >/dev/null
fi

printf "\n * Starting app and sidekiq\n"
$DC up -d app sidekiq

printf "\n * Running migrations\n"
$DC exec -T -e RAILS_ENV="$RAILS_ENV" -e DISABLE_DATABASE_ENVIRONMENT_CHECK=1 app bundle exec rails db:migrate

printf "\n * Reindexing Solr\n"
$DC exec -T -e RAILS_ENV="$RAILS_ENV" app bundle exec rake sunspot:reindex

printf "\n * Done\n"
