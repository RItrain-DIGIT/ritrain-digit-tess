#!/bin/bash
# Backs up and restores public/system (files uploaded to the application).
#
# Usage:
#   scripts/backup_uploads.sh backup  [archive.tar.gz] [production|development]
#   scripts/backup_uploads.sh restore archive.tar.gz  [production|development]
#
# development: public/system is a directory of the project (bind mount).
# production:  public/system is the "uploads" docker volume.
# If the environment is not given, it is detected from the running app container.
set -euo pipefail

usage() {
  echo "Usage: $0 backup [archive.tar.gz] [production|development]" >&2
  echo "       $0 restore <archive.tar.gz> [production|development]" >&2
  exit 1
}

ACTION="${1:-}"
ARCHIVE="${2:-}"
RAILS_ENV="${3:-}"

cd "$(dirname "$0")/.."

case "$ACTION" in
  backup) ARCHIVE="${ARCHIVE:-backup/uploads_$(date +%Y%m%d_%H%M%S).tar.gz}" ;;
  restore) [ -f "$ARCHIVE" ] || { echo "Archive not found: '${ARCHIVE}'" >&2; usage; } ;;
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

# Runs in a one-off app container so file ownership matches the application container.
in_system() {
  docker compose -f "$COMPOSE_FILE" run --rm --no-deps -T --entrypoint "$1" app "${@:2}"
}
SYSTEM_DIR=/code/public/system

case "$ACTION" in
  backup)
    mkdir -p "$(dirname "$ARCHIVE")"
    printf "\n * Backing up %s (%s) to %s\n" "$SYSTEM_DIR" "$RAILS_ENV" "$ARCHIVE"
    in_system tar -czf - -C "$SYSTEM_DIR" . > "$ARCHIVE"
    ;;
  restore)
    printf "\n * Restoring %s (%s) from %s\n" "$SYSTEM_DIR" "$RAILS_ENV" "$ARCHIVE"
    gzip -t "$ARCHIVE"
    in_system find "$SYSTEM_DIR" -mindepth 1 -delete
    in_system tar -xzf - -C "$SYSTEM_DIR" < "$ARCHIVE"
    ;;
esac

printf "\n * Done\n"