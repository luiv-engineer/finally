# FinAlly — AI Trading Workstation
# Multi-stage build: Next.js static export (Node) -> FastAPI runtime (Python).
# The final image serves BOTH the API and the static frontend on port 8000.

# ---------------------------------------------------------------------------
# Stage 1 — Frontend: build the Next.js static export
# ---------------------------------------------------------------------------
FROM node:20-slim AS frontend

ENV NEXT_TELEMETRY_DISABLED=1 \
    CI=true

WORKDIR /build

# Dependency manifests first so the npm layer caches independently of source.
# The lockfile is matched with a glob so the build still works before one is
# committed (npm install is the fallback below).
COPY frontend/package.json ./
COPY frontend/package-lock.json* ./

RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

# Now the actual source.
COPY frontend/ ./

# next.config.* sets `output: 'export'`, so this produces a static site in ./out
RUN npm run build && test -d out

# ---------------------------------------------------------------------------
# Stage 2 — Runtime: FastAPI on Python 3.12
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS runtime

# uv, pinned. Copied as a binary rather than installed via pip.
COPY --from=ghcr.io/astral-sh/uv:0.5.14 /uv /usr/local/bin/uv

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    PATH="/app/.venv/bin:$PATH" \
    HOME=/tmp \
    DATABASE_PATH=/app/data/finally.db

WORKDIR /app

# Dependencies before source: this layer only rebuilds when the lock changes.
COPY backend/pyproject.toml backend/uv.lock backend/README.md ./
RUN uv sync --frozen --no-dev --no-install-project

# Application source, then install the project itself into the venv.
COPY backend/app ./app
RUN uv sync --frozen --no-dev

# Static frontend. CONTRACTS.md §8: FastAPI mounts this LAST so it cannot
# shadow /api/* routes.
COPY --from=frontend /build/out ./static

# Non-root. `data/` is a bind mount at runtime (CONTRACTS.md §9) — the start
# scripts pass --user "$(id -u):$(id -g)" so files written there are owned by
# the host user. 0777 on the build-time directory keeps the fallback (running
# as the baked-in uid against a host-owned directory) from failing outright.
RUN groupadd --gid 10001 finally \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin finally \
 && mkdir -p /app/data /app/static \
 && chown -R finally:finally /app \
 && chmod 0777 /app/data

USER 10001:10001

EXPOSE 8000

# python -c rather than curl: keeps the runtime image free of extra packages.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/api/health', timeout=4).status == 200 else 1)"]

# ---------------------------------------------------------------------------
# EXACTLY ONE WORKER — DO NOT "OPTIMIZE" THIS.
#
# CONTRACTS.md §8. FinAlly keeps the live price cache, the market-data
# background task, the per-ticker history ring buffer, and the 30s portfolio
# snapshot task IN PROCESS MEMORY. A second worker would get its own price
# cache (clients would see different prices depending on which worker served
# their SSE stream) and would run a duplicate simulator and a duplicate
# snapshot task writing to the same SQLite file.
#
# So: no --workers, no gunicorn, no --reload, nothing that forks.
# ---------------------------------------------------------------------------
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-access-log"]
