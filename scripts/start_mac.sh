#!/usr/bin/env bash
#
# FinAlly — start the app (macOS / Linux).
#
#   ./scripts/start_mac.sh            start, building the image only if missing
#   ./scripts/start_mac.sh --build    force a rebuild first
#   ./scripts/start_mac.sh --no-open  don't open a browser
#   ./scripts/start_mac.sh --port 9000
#
# Safe to run repeatedly. Never touches your data.

set -euo pipefail

IMAGE_NAME="finally:latest"
CONTAINER_NAME="finally"
PORT=8000
FORCE_BUILD=false
OPEN_BROWSER=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- pretty output -----------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  RED=$'\033[31m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi
info()  { printf '%s\n' "${DIM}·${RESET} $*"; }
ok()    { printf '%s\n' "${GREEN}✓${RESET} $*"; }
warn()  { printf '%s\n' "${YELLOW}!${RESET} $*"; }
die()   { printf '%s\n' "${RED}✗${RESET} $*" >&2; exit 1; }

# --- args --------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --build)    FORCE_BUILD=true; shift ;;
    --no-open)  OPEN_BROWSER=false; shift ;;
    --port)     PORT="${2:-}"; [ -n "$PORT" ] || die "--port needs a value"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown option: $1  (try --help)" ;;
  esac
done

# --- preflight ---------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "Docker is not installed. Get Docker Desktop: https://docker.com/products/docker-desktop"
docker info >/dev/null 2>&1 || die "Docker is installed but not running. Start Docker Desktop and try again."

cd "${PROJECT_ROOT}"

# .env — create from the example on first run.
if [ ! -f .env ]; then
  [ -f .env.example ] || die ".env.example is missing; cannot create .env"
  cp .env.example .env
  warn "No .env found — created one from .env.example."
  info "  FinAlly runs fine as-is (market simulator, AI chat disabled)."
  info "  Add an OPENROUTER_API_KEY to .env to enable the AI assistant."
fi

# Runtime data directory. Bind-mounted into the container (CONTRACTS.md §9),
# so the SQLite file is visible — and deletable — right here on your machine.
mkdir -p "${PROJECT_ROOT}/data"

# --- build -------------------------------------------------------------------
image_exists() { docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; }

if [ "${FORCE_BUILD}" = true ] || ! image_exists; then
  if [ "${FORCE_BUILD}" = true ]; then
    info "Building ${IMAGE_NAME} (--build)…"
  else
    info "Image ${IMAGE_NAME} not found — building it (first run takes a few minutes)…"
  fi
  docker build -t "${IMAGE_NAME}" "${PROJECT_ROOT}"
  ok "Image built."
else
  info "Using existing image ${IMAGE_NAME}. Pass --build to rebuild."
fi

# --- container ---------------------------------------------------------------
container_state() { docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || true; }

STATE="$(container_state)"
if [ "${STATE}" = "running" ] && [ "${FORCE_BUILD}" = false ]; then
  ok "FinAlly is already running."
  printf '%s\n' "  ${BOLD}http://localhost:${PORT}${RESET}"
  info "Logs:  docker logs -f ${CONTAINER_NAME}"
  info "Stop:  ./scripts/stop_mac.sh"
  exit 0
fi

if [ -n "${STATE}" ]; then
  info "Removing existing container (${STATE})…"
  docker rm -f "${CONTAINER_NAME}" >/dev/null
fi

# --user: the bind mount means the container writes finally.db onto the host
# filesystem. Running as the invoking user keeps that file owned by you rather
# than by root or by the image's baked-in uid.
info "Starting container…"
docker run -d \
  --name "${CONTAINER_NAME}" \
  --user "$(id -u):$(id -g)" \
  -p "${PORT}:8000" \
  --env-file "${PROJECT_ROOT}/.env" \
  -e DATABASE_PATH=/app/data/finally.db \
  -v "${PROJECT_ROOT}/data:/app/data" \
  "${IMAGE_NAME}" >/dev/null

# --- wait for health ---------------------------------------------------------
URL="http://localhost:${PORT}"
info "Waiting for the app to come up…"
READY=false
for _ in $(seq 1 60); do
  if [ "$(container_state)" != "running" ]; then
    printf '\n'
    docker logs --tail 40 "${CONTAINER_NAME}" || true
    die "Container exited during startup (logs above)."
  fi
  if curl -fsS --max-time 2 "${URL}/api/health" >/dev/null 2>&1; then
    READY=true
    break
  fi
  sleep 1
done

if [ "${READY}" = true ]; then
  ok "FinAlly is up."
else
  warn "Container is running but /api/health did not respond within 60s."
  info "Recent logs:"
  docker logs --tail 40 "${CONTAINER_NAME}" || true
fi

printf '\n  %s\n\n' "${BOLD}${URL}${RESET}"
info "Logs:  docker logs -f ${CONTAINER_NAME}"
info "Stop:  ./scripts/stop_mac.sh"

if [ "${OPEN_BROWSER}" = true ] && [ "${READY}" = true ]; then
  if command -v open >/dev/null 2>&1; then
    open "${URL}" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${URL}" >/dev/null 2>&1 || true
  fi
fi
