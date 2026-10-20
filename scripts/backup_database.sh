#!/bin/bash

# Backs up and restores the database of a dockerized TeSS instance.
# Usage:
#   scripts/backup_database.sh backup  [dump_file] [production|development]
#   scripts/backup_database.sh restore dump_file  [production|development]
# If the environment is not given, it is detected from the running app container.

set -euo pipefail

ACTION="${1:-}"
DUMP_FILE="${2:-}"
RAILS_ENV="${3:-}"

cd "$(dirname "$0")/.."

usage() {
  echo "Usage: $0 backup [dump_file] [production|development]" >&2
  echo "       $0 restore <dump_file> [production|development]" >&2
  exit 1
}

case "$ACTION" in
  backup) DUMP_FILE="${DUMP_FILE:-backup/database_$(date +%Y%m%d_%H%M%S).dump}" ;;
  restore) [ -f "$DUMP_FILE" ] || { echo "Dump file not found: '${DUMP_FILE}'" >&2; usage; } ;;
  *) usage ;;
esac

set -a
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

DC=(docker compose -f "$COMPOSE_FILE")

case "$ACTION" in
  backup)
    mkdir -p "$(dirname "$DUMP_FILE")"
    printf "\n * Backing up database %s (%s) to %s\n" "$DB_NAME" "$RAILS_ENV" "$DUMP_FILE"
    "${DC[@]}" exec -T db pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$DUMP_FILE"
    ;;
  restore)
    printf "\n * Stopping app and sidekiq (%s)\n" "$RAILS_ENV"
    "${DC[@]}" stop app sidekiq

    printf "\n * Recreating database %s\n" "$DB_NAME"
    "${DC[@]}" exec -T db psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres \
      -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}' AND pid <> pg_backend_pid();" >/dev/null
    "${DC[@]}" exec -T db psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres \
      -c "DROP DATABASE IF EXISTS \"${DB_NAME}\";"
    "${DC[@]}" exec -T db psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres \
      -c "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\";"

    printf "\n * Restoring %s\n" "$DUMP_FILE"
    if [ "$(head -c 5 "$DUMP_FILE")" = "PGDMP" ]; then
      "${DC[@]}" exec -T db pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner --no-acl < "$DUMP_FILE"
    elif [ "$(head -c 2 "$DUMP_FILE" | od -An -tx1 | tr -d ' ')" = "1f8b" ]; then
      gunzip -c "$DUMP_FILE" | "${DC[@]}" exec -T db psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" >/dev/null
    else
      "${DC[@]}" exec -T db psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" < "$DUMP_FILE" >/dev/null
    fi

    printf "\n * Starting app and sidekiq\n"
    "${DC[@]}" up -d app sidekiq

    printf "\n * Running migrations\n"
    "${DC[@]}" exec -T -e RAILS_ENV="$RAILS_ENV" -e DISABLE_DATABASE_ENVIRONMENT_CHECK=1 app bundle exec rails db:migrate

    printf "\n * Reindexing Solr\n"
    "${DC[@]}" exec -T -e RAILS_ENV="$RAILS_ENV" app bundle exec rake sunspot:reindex
    ;;
esac

printf "\n * Done\n"