#!/usr/bin/env bash
#
# FinAlly — stop the app (macOS / Linux).
#
#   ./scripts/stop_mac.sh
#
# Stops and removes the container. Your data in ./data is NOT touched —
# positions, cash and trade history survive. Safe to run when nothing
# is running.

set -euo pipefail

CONTAINER_NAME="finally"

if [ -t 1 ]; then
  DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
  DIM=""; GREEN=""; RED=""; RESET=""
fi
info() { printf '%s\n' "${DIM}·${RESET} $*"; }
ok()   { printf '%s\n' "${GREEN}✓${RESET} $*"; }
die()  { printf '%s\n' "${RED}✗${RESET} $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "Docker is not installed."
docker info >/dev/null 2>&1 || die "Docker is not running."

STATE="$(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || true)"

if [ -z "${STATE}" ]; then
  ok "FinAlly is not running — nothing to stop."
else
  if [ "${STATE}" = "running" ]; then
    info "Stopping ${CONTAINER_NAME}…"
    docker stop "${CONTAINER_NAME}" >/dev/null
  fi
  docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  ok "FinAlly stopped."
fi

info "Your database is untouched: ./data/finally.db"
