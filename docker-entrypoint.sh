#!/bin/sh
set -e

BITBARREL_DATA_DIR="${BITBARREL_STORAGE_DATA_DIR:-/data}"
BITBARREL_SERVER_PORT="${BITBARREL_SERVER_PORT:-8080}"
BITBARREL_WEB_ADMIN_PATH="${BITBARREL_WEB_ADMIN_PATH:-/opt/bitbarrel/webadmin}"

mkdir -p "${BITBARREL_DATA_DIR}"

echo "Starting BitBarrel on port ${BITBARREL_SERVER_PORT}..."

exec /usr/local/bin/bitbarrel serve     --port=${BITBARREL_SERVER_PORT}     --data-dir=${BITBARREL_DATA_DIR}     --webadmin-path=${BITBARREL_WEB_ADMIN_PATH}     --webadmin-enabled
