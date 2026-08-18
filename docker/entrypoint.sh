#!/usr/bin/env bash
# Blocks the application launch until the database is accepting connections.
# run.py opens its MongoClient at import time, so without this the process
# dies with a ServerSelectionTimeoutError stack trace instead of a clean log line.
set -euo pipefail

# No default host on purpose: an unset DB_HOST skips the wait rather than
# probing the container's own loopback, which would always time out.
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-27017}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-60}"

if [ -z "${DB_HOST}" ]; then
  echo "[entrypoint] DB_HOST is not set, skipping the database wait"
  exec "$@"
fi

echo "[entrypoint] waiting for database at ${DB_HOST}:${DB_PORT} (timeout: ${WAIT_TIMEOUT_SECONDS}s)"

# SECONDS measures wall-clock time, so the timeout holds even when a connect
# attempt itself blocks (a blackholed host rather than a refused connection).
SECONDS=0
until (exec 3<>"/dev/tcp/${DB_HOST}/${DB_PORT}") 2>/dev/null; do
  if [ "${SECONDS}" -ge "${WAIT_TIMEOUT_SECONDS}" ]; then
    echo "[entrypoint] database did not become reachable within ${WAIT_TIMEOUT_SECONDS}s, aborting" >&2
    exit 1
  fi
  sleep 1
done

echo "[entrypoint] database is reachable, starting application"
exec "$@"
