# CONTRACTS.md — Binding Decisions for Implementation

**Status: AUTHORITATIVE.** This document resolves every open question in `PLAN.md` §13
and `FEEDBACK.md`. Where this document and `PLAN.md` disagree, **this document wins**.
Where this document is silent, `PLAN.md` governs.

Do not re-litigate these decisions. If you believe one is wrong, implement it as written
and note the objection in `planning/ISSUES.md`.

---

## 0. File Ownership (STRICT — do not edit outside your lane)

Multiple agents work this repo concurrently. Editing another agent's files causes lost work.

| Owner | Owns exclusively |
|---|---|
| Database Engineer | `backend/app/db/**`, `backend/app/services/**`, `backend/tests/db/**`, `backend/tests/services/**` |
| Backend API Engineer | `backend/app/main.py`, `backend/app/lifespan.py`, `backend/app/config.py`, `backend/app/api/**` (except `chat.py`), `backend/app/market/**`, `backend/tests/api/**`, `backend/tests/market/**` |
| LLM Engineer | `backend/app/llm/**`, `backend/app/api/chat.py`, `backend/tests/llm/**` |
| Frontend Engineer | `frontend/**` |
| DevOps Engineer | `Dockerfile`, `.dockerignore`, `docker-compose.yml`, `scripts/**`, `.env.example`, `.github/**` |
| Integration Tester | `test/**` |

`backend/pyproject.toml` is **frozen** — all dependencies are pre-added. If you genuinely
need another, ask the orchestrator; do not edit it yourself.
`planning/**` is orchestrator-owned, except `planning/ISSUES.md` which is append-only for everyone.

---

## 1. Money, Quantities & Numeric Policy  (resolves C6, FEEDBACK "Numeric representation")

- **Quantity**: fractional shares allowed. Rounded to **4 decimal places**. Minimum order
  quantity `0.0001`. Reject `<= 0`, `NaN`, `inf`, and `> 1_000_000`.
- **Cash**: rounded to **2 decimal places** after every mutation. Never allowed to go negative.
- **avg_cost**: rounded to **4 decimal places** (carries more precision than displayed price — expected).
- **Prices**: `PriceCache` already rounds to 2dp. That is the canonical traded price.
- **Arithmetic**: the trade service performs all money math with `decimal.Decimal`
  (`ROUND_HALF_EVEN`), then converts to `float` for SQLite `REAL` storage. Do not do
  float arithmetic on cash anywhere else.
- **Full sell**: if resulting quantity `< 0.0001`, **DELETE the position row**. Positions
  never persist at zero. (resolves C4)

## 2. Price Baseline & "Daily Change"  (resolves Q1, FEEDBACK correction #1)

**One baseline only, named `open_price`.** No previous-close concept anywhere.

- `PriceUpdate` gains a field `open_price: float`.
- Simulator: `open_price` = the ticker's seed price at the moment it entered the cache.
- Massive: `open_price` = the session-open field from the snapshot response; if absent,
  fall back to the first observed price.
- `change_from_open = price - open_price`
- `change_percent_from_open = (price - open_price) / open_price * 100`
- The watchlist "change %" column displays **`change_percent_from_open`**.
- Existing tick-to-tick `change` / `change_percent` / `direction` are **retained** and are
  used **only** to drive the green/red price-flash animation.

`open_price` resets when the process restarts. This is accepted and documented in the UI
as "session change", not "daily change".

## 3. Tracked Ticker Set  (resolves Q2, FEEDBACK #3)

**Tracked set = union(watchlist, tickers with an open position).**

- `DELETE /api/watchlist/{ticker}` removes the DB row, then **reconciles**: it calls
  `source.remove_ticker()` **only if** no open position remains for that ticker.
  Never call `remove_ticker()` unconditionally.
- `POST /api/watchlist` inserts the row, then calls `source.add_ticker()`.
- A buy of an untracked ticker calls `source.add_ticker()` as part of the flow.
- On startup the union is recomputed from the database and passed to `source.start()`.
- Holding a position in a ticker not on the watchlist is **legal and supported**.

## 4. Unknown Tickers  (resolves Q3, FEEDBACK correction #3)

- Validation: uppercase, `^[A-Z][A-Z.]{0,4}$`. Anything else → `400 invalid_ticker`.
- Simulator mode: any symbol passing validation is **accepted**; the existing
  `GBMSimulator._add_ticker_internal()` fallback (random seed 50–300, `DEFAULT_PARAMS`) stands.
- Massive mode: the symbol is accepted and subscribed, but if no quote arrives within
  `QUOTE_MAX_AGE_SECONDS` it simply reads as price-unavailable (§5). The two modes
  **are allowed to diverge** here; this is intentional and documented.

## 5. Quote Eligibility & Freshness  (resolves Q4, FEEDBACK #3)

Config `QUOTE_MAX_AGE_SECONDS`: default **10** in simulator mode, **90** in Massive mode.

A quote is **eligible** iff it exists in the cache AND `now - timestamp <= QUOTE_MAX_AGE_SECONDS`.

- **Trading** (manual *and* LLM-initiated, identical rules): ineligible quote →
  `409 {"error": "price_unavailable", "ticker": "..."}`. Never fill on a stale quote.
- **Valuation**: a held ticker with an ineligible quote is **not** valued at zero and
  **not** silently dropped. Its last known price is used, the position is marked
  `"stale": true`, and the portfolio response carries `"valuation_complete": false`.
- **Snapshots**: when `valuation_complete` is false, **skip** writing the snapshot rather
  than record an artificially low value. Prevents restart discontinuities.
- Quote freshness is **separate** from SSE connection health. Do not conflate them.

## 6. Trade Execution: Atomicity  (resolves FEEDBACK #1)

All trades — manual and LLM — go through **one** shared service:
`backend/app/services/trades.py :: execute_trade()`. No other module writes to
`positions`, `trades`, or `users_profile.cash_balance`.

Required sequence:
1. Validate input (§1) and ticker (§4).
2. Capture **one** eligible quote (§5). This single price is used for the whole operation.
3. `BEGIN IMMEDIATE` write transaction.
4. Re-read cash and holdings **inside** the transaction.
5. Validate sufficiency (buy: `cash >= qty*price`; sell: `held >= qty`).
6. Update cash, upsert/delete position, insert trade row, insert idempotency record.
7. `COMMIT`.

- An LLM/provider call must **never** happen inside this transaction.
- The post-trade portfolio snapshot is written **after** commit, in a separate transaction.
  A snapshot failure must not roll back the trade.
- Acceptance: competing buys cannot overspend; competing sells cannot oversell; an
  injected failure mid-transaction leaves zero trace.

## 7. Idempotency / Retry Safety  (resolves FEEDBACK #2)

New table `idempotency_keys` (§10). Every mutating request carries a client-generated
`request_id` (UUIDv4).

- `POST /api/portfolio/trade` and `POST /api/chat` accept `request_id` in the body.
- Same `request_id` + identical payload hash → return the **stored original response**, HTTP 200.
- Same `request_id` + different payload hash → `409 {"error": "request_id_reuse"}`.
- A row is inserted in the same transaction as the effect, so it commits atomically.
- In-progress duplicate (row exists, `response_json IS NULL`) → `409 {"error": "request_in_progress"}`.
- `request_id` is **optional** for backwards compatibility; when absent the request is not
  deduplicated. The frontend always sends one.

## 8. Application Lifecycle  (resolves FEEDBACK #4, I3, I4)

Startup, in this exact order, inside a FastAPI `lifespan` handler:
1. Resolve `DATABASE_PATH`; create parent directory.
2. Open SQLite; `PRAGMA journal_mode=WAL`, `PRAGMA foreign_keys=ON`, `PRAGMA busy_timeout=5000`.
3. Create schema if absent; apply schema version (`schema_version` table).
4. Seed **only if the user row is absent** — never reseed an existing user. An
   intentionally empty watchlist must survive restart (seed watchlist only when the
   user row itself is being created).
5. Compute tracked-ticker union (§3) from DB.
6. `await source.start(union)`.
7. Start the 30s snapshot task (§5 gating applies).

Shutdown: stop snapshot task, `await source.stop()`, close DB.

- **Exactly one Uvicorn worker.** Multiple workers would create independent caches and
  duplicate background tasks. This is enforced in the Dockerfile CMD and documented.
- Route registration order in `main.py`: **API routers first, static file mount last.**
  The static mount is a catch-all and will shadow `/api/*` if registered first.
- Next.js export produces real `.html` files; serve with `html=True` on `StaticFiles`.
  No SPA fallback rewrite needed for the single-page app, but a 404 handler should
  return `index.html` for non-`/api` paths.

## 9. Paths & Persistence  (resolves I1, I2)

- Schema/seed source code lives at **`backend/app/db/`**. (Not `backend/db/`.)
- The runtime SQLite file lives in **`data/`** at the project root. (Not `db/`.)
  `data/.gitkeep` is committed; `data/*.db*` is gitignored.
- **Bind mount, not a named volume**: `-v "$(pwd)/data:/app/data"`. Host-visible, which
  matters for a teaching repo — students can inspect and delete the file.
- `DATABASE_PATH` env var, default `./data/finally.db` locally, `/app/data/finally.db`
  in the container. Added to `.env.example`.
- Simulator prices **do reset** on restart while positions persist. Accepted; §5's
  snapshot gating prevents a bogus value spike being recorded.

## 10. Database Schema (authoritative)

As `PLAN.md` §7, with these additions/changes:

- `schema_version` — `version INTEGER PRIMARY KEY`, `applied_at TEXT`.
- `idempotency_keys` — `request_id TEXT PRIMARY KEY`, `user_id TEXT`, `endpoint TEXT`,
  `payload_hash TEXT`, `response_json TEXT NULL`, `created_at TEXT`.
- `positions`: rows are **deleted** at zero quantity (§1).
- `portfolio_snapshots`: seed **one row** at `total_value = 10000.0` during initial
  seeding so the P&L chart is never empty. (resolves C3)
- `chat_messages.actions`: JSON, shape fixed in §13.

Retention: `portfolio_snapshots` older than 7 days are pruned by the snapshot task.
`GET /api/portfolio/history` downsamples to at most **500 points**. (resolves "Bounded history")

## 11. P&L Definitions  (resolves C5, FEEDBACK correction #6)

Computed identically by backend and frontend — backend is the source of truth, frontend
displays what the API returns and does not recompute.

```
position_value      = qty * current_price
unrealized_pnl      = qty * (current_price - avg_cost)
unrealized_pnl_pct  = (current_price - avg_cost) / avg_cost * 100
positions_value     = Σ position_value
total_value         = cash_balance + positions_value
total_return        = total_value - 10000.0
total_return_pct    = total_return / 10000.0 * 100
realized_pnl        = Σ over sell trades of qty * (sell_price - avg_cost_at_sale)
```

`realized_pnl` **is** tracked: add a nullable `realized_pnl REAL` column to `trades`,
populated on sells (null on buys). This avoids recomputing history and settles the
labelling gap. The header shows **Total Value** and **Total Return**; the positions table
shows **Unrealized P&L**. Labels must say "unrealized" / "realized" explicitly — never a
bare "P&L".

## 12. SSE Contract  (resolves C1, S4, S6, FEEDBACK correction #9)

Endpoint `GET /api/stream/prices`, `text/event-stream`.

**Payload is all tickers in one event, keyed by symbol** (this is what the code already does):

```json
{"AAPL": {"ticker":"AAPL","price":190.5,"previous_price":190.4,"open_price":190.0,
          "timestamp":1757664000.123,"direction":"up",
          "change_percent_from_open":0.26,"stale":false}, "...": {}}
```

- Derived tick fields `change` / `change_percent` are **dropped from the wire payload**
  (client derives flash direction from `direction`). `open_price` is added. (S4)
- The stream is **change-triggered** — a version counter polled every 500ms — not a fixed
  heartbeat. In Massive mode a client sees roughly one event per poll interval.
- **Required fixes to `app/market/`** (Backend API Engineer owns these):
  - `PriceCache.remove()` **must** increment `_version`, so clients learn a ticker vanished.
  - The stream must **send an empty object `{}`** rather than suppress it, so the client
    can clear its local state when the last ticker is removed.
  - Emit a **keepalive comment `: ping`** every 15s when nothing changed, so proxies and
    the client's freshness heuristic (§14) behave.
  - `create_stream_router()` must build its `APIRouter` **inside** the factory, not at
    module scope — currently calling it twice double-registers the route, which breaks
    FastAPI test fixtures. (S6)
- On reconnect the client **replaces** its price map wholesale from the first event received.

## 13. Chat Contract  (resolves Q5, C7, C8, C9, C10, C13, FEEDBACK #5)

### Request
`POST /api/chat` → `{"message": "...", "request_id": "uuid"}`

### Model structured output
**One ordered action array**, not separate `trades` / `watchlist_changes` — adding a
symbol and buying it in one response requires ordering (FEEDBACK #5).

```json
{
  "message": "Conversational response describing INTENT",
  "actions": [
    {"type": "watchlist_add",    "ticker": "PYPL"},
    {"type": "watchlist_remove", "ticker": "NFLX"},
    {"type": "buy",  "ticker": "PYPL", "quantity": 10},
    {"type": "sell", "ticker": "AAPL", "quantity": 5}
  ]
}
```

- Maximum **10 actions** per response; excess is rejected before any effect runs.
- The **entire** structured response is validated (Pydantic) **before** any effect executes.
- Execution is **sequential, in array order, best-effort** — each action gets its own
  recorded outcome; a failure does not abort later actions.

### Backend-generated result (authoritative)
The model's `message` describes **intent only**. Execution truth is backend-generated.

```json
{
  "message": "I'll buy 10 PYPL for you.",
  "actions": [
    {"type":"buy","ticker":"PYPL","quantity":10,"status":"ok",
     "price":72.15,"total":721.50},
    {"type":"sell","ticker":"AAPL","quantity":5,"status":"error",
     "error":"insufficient_shares","detail":"Held 2, requested 5"}
  ],
  "portfolio_dirty": true
}
```

- The frontend renders each action inline, green for `ok`, red for `error`. The model is
  **not** called a second time. (Q5 option a)
- `portfolio_dirty: true` tells the frontend to refetch `/api/portfolio`. This is also how
  a tab learns cash/holdings changed — prices alone cannot signal that.
- This exact object is persisted to `chat_messages.actions` and is what future turns see
  as context, so the model learns what actually happened.

### Other chat rules
- History: last **20 messages**, additionally truncated to **8000 characters** total,
  oldest dropped first. (C8)
- `GET /api/chat/history?limit=50` — bounded read endpoint so the UI survives reload.
- Server-side timeout **30s** on the provider call → `504 {"error":"llm_timeout"}` with a
  friendly chat bubble. (C13)
- Structured Outputs via the `cerebras` skill contract:
  `model="openrouter/openai/gpt-oss-120b"`, `extra_body={"provider":{"order":["cerebras"]}}`,
  `response_format=<PydanticModel>`, `reasoning_effort="low"`.
  **Fallback required** (C10): if `response_format` is rejected or the reply fails to
  parse, retry **once** with prompt-instructed JSON + Pydantic validation. If that also
  fails, return a graceful error message and zero actions.
- Missing `OPENROUTER_API_KEY` and `LLM_MOCK != true`: chat returns
  `503 {"error":"llm_unavailable"}` and the UI shows a clear, non-blocking
  "Chat unavailable — no API key configured" state. **Trading and all other features
  continue to work fully.** (FEEDBACK "No-key experience")
- The system prompt must instruct: execute trades **only** on explicit user instruction or
  agreement. A pure analysis question must produce `actions: []`.

### LLM_MOCK contract (C9) — deterministic, keyword-driven
`LLM_MOCK=true` bypasses the provider entirely. Matching is case-insensitive substring,
checked in this order:

| Input contains | Mock response |
|---|---|
| `"buy"` | message `"Buying 1 share of AAPL."`, actions `[{"type":"buy","ticker":"AAPL","quantity":1}]` |
| `"sell"` | message `"Selling 1 share of AAPL."`, actions `[{"type":"sell","ticker":"AAPL","quantity":1}]` |
| `"watch"` | message `"Adding PYPL to your watchlist."`, actions `[{"type":"watchlist_add","ticker":"PYPL"}]` |
| `"error"` | message `"Attempting a large buy."`, actions `[{"type":"buy","ticker":"AAPL","quantity":999999}]` (exercises the failure path) |
| anything else | message `"Your portfolio is holding steady."`, actions `[]` |

Integration Tester and LLM Engineer both code against this table verbatim.

## 14. Frontend Contract  (resolves C2, C12, S2, and §13.6)

- **Charting: Recharts only.** One dependency covers all four visualizations
  (sparkline, main price chart, treemap heatmap, P&L line). Do not add Lightweight
  Charts. (S2)
- **Connection status** is defined by observed behavior, thresholded per mode. The mode
  and its `stale_after_seconds` come from `GET /api/health`, so Massive mode does not sit
  on yellow permanently: (C12)
  - **green** — an event or keepalive received within `stale_after_seconds`
  - **yellow** — `EventSource.readyState === CONNECTING`, or nothing received for longer
  - **red** — `readyState === CLOSED`
- **Sparklines** accumulate from SSE since page load and are **capped at 120 points**
  (ring buffer, drop oldest). Empty on first paint is expected and intentional.
- **Main chart** uses `GET /api/history/{ticker}` for backfill (§15) plus live SSE points.
  Cold server start legitimately returns few points — render an honest empty state, do
  not fabricate history. (FEEDBACK correction #5)
- **Default selected ticker**: the first watchlist entry, so the chart area is never empty.
- **Trade bar**: free-text ticker; it does **not** need to be on the watchlist. A
  successful buy of an untracked ticker **auto-adds it to the watchlist**. Validate
  against §4's regex client-side before submitting.
- **Prices come only from SSE.** REST responses carry a price snapshot for first paint
  only; once the first SSE event arrives, SSE wins for every ticker it contains. Never
  merge the two per-field.
- After any trade or `portfolio_dirty` chat response, refetch `/api/portfolio`.
- Tailwind CSS, dark theme, colors per `PLAN.md` §2.

## 15. API Surface (additions to PLAN.md §8)

| Method | Path | Notes |
|---|---|---|
| GET | `/api/health` | `{status, market_source:"simulator"\|"massive", source_running:bool, ticker_count:int, stale_after_seconds:int, llm_available:bool, schema_version:int}` (§13.6) |
| GET | `/api/history/{ticker}` | In-memory ring buffer, last **240** samples per ticker. No persistence, no schema change. Populated by the same task that writes the cache. (C2) |
| GET | `/api/chat/history` | Bounded, `?limit=50` |

`GET /api/watchlist` returns tickers **with a price snapshot** for first paint — but §14's
"SSE wins" rule makes SSE the single source of price truth. No separate `/api/state`
bootstrap endpoint; the existing endpoints are adequate. (S1 declined per FEEDBACK #8)

### Error envelope (uniform across all endpoints)
```json
{"error": "machine_readable_code", "detail": "Human readable explanation"}
```
Codes: `invalid_ticker`, `invalid_quantity`, `insufficient_cash`, `insufficient_shares`,
`price_unavailable`, `request_id_reuse`, `request_in_progress`, `llm_unavailable`,
`llm_timeout`, `not_found`.

## 16. Testing  (resolves S3, S5, FEEDBACK "Delivery and verification")

- **Playwright runs from the host**, against the running container. No
  `docker-compose.test.yml`, no second image. Better debugging (`--headed`, `--ui`),
  same isolation goal. (S3)
- E2E runs against a **dedicated disposable database path** (`data/e2e.db`), removed
  before each run.
- E2E runs with `LLM_MOCK=true` **and** a deterministic market mode:
  `SIM_FIXED_PRICES=true` freezes the simulator at seed prices so exact accounting
  assertions are possible. `LLM_MOCK` alone does not make the market deterministic.
  (Backend API Engineer implements `SIM_FIXED_PRICES`.)
- **SSE resilience test**: implemented via Playwright route interception (abort the
  `/api/stream/prices` request, assert the status dot goes yellow, restore, assert green).
  Specified concretely rather than dropped. (S5)
- Required E2E scenarios: `PLAN.md` §12 plus — concurrent trades, duplicate `request_id`,
  rollback on injected failure, removing a held ticker keeps it priced, stale/missing
  quote rejection, failed chat action rendered red, restart persistence.

## 17. Environment Variables (complete set for `.env.example`)

```bash
OPENROUTER_API_KEY=          # required for live chat; empty -> chat disabled, rest works
MASSIVE_API_KEY=             # empty -> GBM simulator (default, recommended)
LLM_MOCK=false               # true -> deterministic mock per §13
DATABASE_PATH=./data/finally.db
QUOTE_MAX_AGE_SECONDS=       # empty -> 10 (simulator) / 90 (massive)
SIM_FIXED_PRICES=false       # true -> simulator freezes at seed prices (E2E determinism)
LOG_LEVEL=INFO
```
