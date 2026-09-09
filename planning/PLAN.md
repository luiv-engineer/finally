# FinAlly — AI Trading Workstation

## Project Specification

## 1. Vision

FinAlly (Finance Ally) is a visually stunning AI-powered trading workstation that streams live market data, lets users trade a simulated portfolio, and integrates an LLM chat assistant that can analyze positions and execute trades on the user's behalf. It looks and feels like a modern Bloomberg terminal with an AI copilot.

This is the capstone project for an agentic AI coding course. It is built entirely by Coding Agents demonstrating how orchestrated AI agents can produce a production-quality full-stack application. Agents interact through files in `planning/`.

## 2. User Experience

### First Launch

The user runs a single Docker command (or a provided start script). A browser opens to `http://localhost:8000`. No login, no signup. They immediately see:

- A watchlist of 10 default tickers with live-updating prices in a grid
- $10,000 in virtual cash
- A dark, data-rich trading terminal aesthetic
- An AI chat panel ready to assist

### What the User Can Do

- **Watch prices stream** — prices flash green (uptick) or red (downtick) with subtle CSS animations that fade
- **View sparkline mini-charts** — price action beside each ticker in the watchlist, accumulated on the frontend from the SSE stream since page load (sparklines fill in progressively)
- **Click a ticker** to see a larger detailed chart in the main chart area
- **Buy and sell shares** — market orders only, instant fill at current price, no fees, no confirmation dialog
- **Monitor their portfolio** — a heatmap (treemap) showing positions sized by weight and colored by P&L, plus a P&L chart tracking total portfolio value over time
- **View a positions table** — ticker, quantity, average cost, current price, unrealized P&L, % change
- **Chat with the AI assistant** — ask about their portfolio, get analysis, and have the AI execute trades and manage the watchlist through natural language
- **Manage the watchlist** — add/remove tickers manually or via the AI chat

### Visual Design

- **Dark theme**: backgrounds around `#0d1117` or `#1a1a2e`, muted gray borders, no pure black
- **Price flash animations**: brief green/red background highlight on price change, fading over ~500ms via CSS transitions
- **Connection status indicator**: a small colored dot (green = connected, yellow = reconnecting, red = disconnected) visible in the header
- **Professional, data-dense layout**: inspired by Bloomberg/trading terminals — every pixel earns its place
- **Responsive but desktop-first**: optimized for wide screens, functional on tablet

### Color Scheme
- Accent Yellow: `#ecad0a`
- Blue Primary: `#209dd7`
- Purple Secondary: `#753991` (submit buttons)

## 3. Architecture Overview

### Single Container, Single Port

```
┌─────────────────────────────────────────────────┐
│  Docker Container (port 8000)                   │
│                                                 │
│  FastAPI (Python/uv)                            │
│  ├── /api/*          REST endpoints             │
│  ├── /api/stream/*   SSE streaming              │
│  └── /*              Static file serving         │
│                      (Next.js export)            │
│                                                 │
│  SQLite database (volume-mounted)               │
│  Background task: market data polling/sim        │
└─────────────────────────────────────────────────┘
```

- **Frontend**: Next.js with TypeScript, built as a static export (`output: 'export'`), served by FastAPI as static files
- **Backend**: FastAPI (Python), managed as a `uv` project
- **Database**: SQLite, single file at `db/finally.db`, volume-mounted for persistence
- **Real-time data**: Server-Sent Events (SSE) — simpler than WebSockets, one-way server→client push, works everywhere
- **AI integration**: LiteLLM → OpenRouter (Cerebras for fast inference), with structured outputs for trade execution
- **Market data**: Environment-variable driven — simulator by default, real data via Massive API if key provided

### Why These Choices

| Decision | Rationale |
|---|---|
| SSE over WebSockets | One-way push is all we need; simpler, no bidirectional complexity, universal browser support |
| Static Next.js export | Single origin, no CORS issues, one port, one container, simple deployment |
| SQLite over Postgres | No auth = no multi-user = no need for a database server; self-contained, zero config |
| Single Docker container | Students run one command; no docker-compose for production, no service orchestration |
| uv for Python | Fast, modern Python project management; reproducible lockfile; what students should learn |
| Market orders only | Eliminates order book, limit order logic, partial fills — dramatically simpler portfolio math |

---

## 4. Directory Structure

```
finally/
├── frontend/                 # Next.js TypeScript project (static export)
├── backend/                  # FastAPI uv project (Python)
│   └── db/                   # Schema definitions, seed data, migration logic
├── planning/                 # Project-wide documentation for agents
│   ├── PLAN.md               # This document
│   └── ...                   # Additional agent reference docs
├── scripts/
│   ├── start_mac.sh          # Launch Docker container (macOS/Linux)
│   ├── stop_mac.sh           # Stop Docker container (macOS/Linux)
│   ├── start_windows.ps1     # Launch Docker container (Windows PowerShell)
│   └── stop_windows.ps1      # Stop Docker container (Windows PowerShell)
├── test/                     # Playwright E2E tests + docker-compose.test.yml
├── db/                       # Volume mount target (SQLite file lives here at runtime)
│   └── .gitkeep              # Directory exists in repo; finally.db is gitignored
├── Dockerfile                # Multi-stage build (Node → Python)
├── docker-compose.yml        # Optional convenience wrapper
├── .env                      # Environment variables (gitignored, .env.example committed)
└── .gitignore
```

### Key Boundaries

- **`frontend/`** is a self-contained Next.js project. It knows nothing about Python. It talks to the backend via `/api/*` endpoints and `/api/stream/*` SSE endpoints. Internal structure is up to the Frontend Engineer agent.
- **`backend/`** is a self-contained uv project with its own `pyproject.toml`. It owns all server logic including database initialization, schema, seed data, API routes, SSE streaming, market data, and LLM integration. Internal structure is up to the Backend/Market Data agents.
- **`backend/db/`** contains schema SQL definitions and seed logic. The backend lazily initializes the database on first request — creating tables and seeding default data if the SQLite file doesn't exist or is empty.
- **`db/`** at the top level is the runtime volume mount point. The SQLite file (`db/finally.db`) is created here by the backend and persists across container restarts via Docker volume.
- **`planning/`** contains project-wide documentation, including this plan. All agents reference files here as the shared contract.
- **`test/`** contains Playwright E2E tests and supporting infrastructure (e.g., `docker-compose.test.yml`). Unit tests live within `frontend/` and `backend/` respectively, following each framework's conventions.
- **`scripts/`** contains start/stop scripts that wrap Docker commands.

---

## 5. Environment Variables

```bash
# Required: OpenRouter API key for LLM chat functionality
OPENROUTER_API_KEY=your-openrouter-api-key-here

# Optional: Massive (Polygon.io) API key for real market data
# If not set, the built-in market simulator is used (recommended for most users)
MASSIVE_API_KEY=

# Optional: Set to "true" for deterministic mock LLM responses (testing)
LLM_MOCK=false
```

### Behavior

- If `MASSIVE_API_KEY` is set and non-empty → backend uses Massive REST API for market data
- If `MASSIVE_API_KEY` is absent or empty → backend uses the built-in market simulator
- If `LLM_MOCK=true` → backend returns deterministic mock LLM responses (for E2E tests)
- The backend reads `.env` from the project root (mounted into the container or read via docker `--env-file`)

---

## 6. Market Data

### Two Implementations, One Interface

Both the simulator and the Massive client implement the same abstract interface. The backend selects which to use based on the environment variable. All downstream code (SSE streaming, price cache, frontend) is agnostic to the source.

### Simulator (Default)

- Generates prices using geometric Brownian motion (GBM) with configurable drift and volatility per ticker
- Updates at ~500ms intervals
- Correlated moves across tickers (e.g., tech stocks move together)
- Occasional random "events" — sudden 2-5% moves on a ticker for drama
- Starts from realistic seed prices (e.g., AAPL ~$190, GOOGL ~$175, etc.)
- Runs as an in-process background task — no external dependencies

### Massive API (Optional)

- REST API polling (not WebSocket) — simpler, works on all tiers
- Polls for the union of all watched tickers on a configurable interval
- Free tier (5 calls/min): poll every 15 seconds
- Paid tiers: poll every 2-15 seconds depending on tier
- Parses REST response into the same format as the simulator

### Shared Price Cache

- A single background task (simulator or Massive poller) writes to an in-memory price cache
- The cache holds the latest price, previous price, and timestamp for each ticker
- SSE streams read from this cache and push updates to connected clients
- This architecture supports future multi-user scenarios without changes to the data layer

### SSE Streaming

- Endpoint: `GET /api/stream/prices`
- Long-lived SSE connection; client uses native `EventSource` API
- Server pushes price updates for all tickers known to the system at a regular cadence (~500ms) — in the single-user model this is equivalent to the user's watchlist
- Each SSE event contains ticker, price, previous price, timestamp, and change direction
- Client handles reconnection automatically (EventSource has built-in retry)

---

## 7. Database

### SQLite with Lazy Initialization

The backend checks for the SQLite database on startup (or first request). If the file doesn't exist or tables are missing, it creates the schema and seeds default data. This means:

- No separate migration step
- No manual database setup
- Fresh Docker volumes start with a clean, seeded database automatically

### Schema

All tables include a `user_id` column defaulting to `"default"`. This is hardcoded for now (single-user) but enables future multi-user support without schema migration.

**users_profile** — User state (cash balance)
- `id` TEXT PRIMARY KEY (default: `"default"`)
- `cash_balance` REAL (default: `10000.0`)
- `created_at` TEXT (ISO timestamp)

**watchlist** — Tickers the user is watching
- `id` TEXT PRIMARY KEY (UUID)
- `user_id` TEXT (default: `"default"`)
- `ticker` TEXT
- `added_at` TEXT (ISO timestamp)
- UNIQUE constraint on `(user_id, ticker)`

**positions** — Current holdings (one row per ticker per user)
- `id` TEXT PRIMARY KEY (UUID)
- `user_id` TEXT (default: `"default"`)
- `ticker` TEXT
- `quantity` REAL (fractional shares supported)
- `avg_cost` REAL
- `updated_at` TEXT (ISO timestamp)
- UNIQUE constraint on `(user_id, ticker)`

**trades** — Trade history (append-only log)
- `id` TEXT PRIMARY KEY (UUID)
- `user_id` TEXT (default: `"default"`)
- `ticker` TEXT
- `side` TEXT (`"buy"` or `"sell"`)
- `quantity` REAL (fractional shares supported)
- `price` REAL
- `executed_at` TEXT (ISO timestamp)

**portfolio_snapshots** — Portfolio value over time (for P&L chart). Recorded every 30 seconds by a background task, and immediately after each trade execution.
- `id` TEXT PRIMARY KEY (UUID)
- `user_id` TEXT (default: `"default"`)
- `total_value` REAL
- `recorded_at` TEXT (ISO timestamp)

**chat_messages** — Conversation history with LLM
- `id` TEXT PRIMARY KEY (UUID)
- `user_id` TEXT (default: `"default"`)
- `role` TEXT (`"user"` or `"assistant"`)
- `content` TEXT
- `actions` TEXT (JSON — trades executed, watchlist changes made; null for user messages)
- `created_at` TEXT (ISO timestamp)

### Default Seed Data

- One user profile: `id="default"`, `cash_balance=10000.0`
- Ten watchlist entries: AAPL, GOOGL, MSFT, AMZN, TSLA, NVDA, META, JPM, V, NFLX

---

## 8. API Endpoints

### Market Data
| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/stream/prices` | SSE stream of live price updates |

### Portfolio
| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/portfolio` | Current positions, cash balance, total value, unrealized P&L |
| POST | `/api/portfolio/trade` | Execute a trade: `{ticker, quantity, side}` |
| GET | `/api/portfolio/history` | Portfolio value snapshots over time (for P&L chart) |

### Watchlist
| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/watchlist` | Current watchlist tickers with latest prices |
| POST | `/api/watchlist` | Add a ticker: `{ticker}` |
| DELETE | `/api/watchlist/{ticker}` | Remove a ticker |

### Chat
| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/chat` | Send a message, receive complete JSON response (message + executed actions) |

### System
| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Health check (for Docker/deployment) |

---

## 9. LLM Integration

When writing code to make calls to LLMs, use cerebras-inference skill to use LiteLLM via OpenRouter to the `openrouter/openai/gpt-oss-120b` model with Cerebras as the inference provider. Structured Outputs should be used to interpret the results.

There is an OPENROUTER_API_KEY in the .env file in the project root.

### How It Works

When the user sends a chat message, the backend:

1. Loads the user's current portfolio context (cash, positions with P&L, watchlist with live prices, total portfolio value)
2. Loads recent conversation history from the `chat_messages` table
3. Constructs a prompt with a system message, portfolio context, conversation history, and the user's new message
4. Calls the LLM via LiteLLM → OpenRouter, requesting structured output, using the cerebras-inference skill
5. Parses the complete structured JSON response
6. Auto-executes any trades or watchlist changes specified in the response
7. Stores the message and executed actions in `chat_messages`
8. Returns the complete JSON response to the frontend (no token-by-token streaming — Cerebras inference is fast enough that a loading indicator is sufficient)

### Structured Output Schema

The LLM is instructed to respond with JSON matching this schema:

```json
{
  "message": "Your conversational response to the user",
  "trades": [
    {"ticker": "AAPL", "side": "buy", "quantity": 10}
  ],
  "watchlist_changes": [
    {"ticker": "PYPL", "action": "add"}
  ]
}
```

- `message` (required): The conversational text shown to the user
- `trades` (optional): Array of trades to auto-execute. Each trade goes through the same validation as manual trades (sufficient cash for buys, sufficient shares for sells)
- `watchlist_changes` (optional): Array of watchlist modifications

### Auto-Execution

Trades specified by the LLM execute automatically — no confirmation dialog. This is a deliberate design choice:
- It's a simulated environment with fake money, so the stakes are zero
- It creates an impressive, fluid demo experience
- It demonstrates agentic AI capabilities — the core theme of the course

If a trade fails validation (e.g., insufficient cash), the error is included in the chat response so the LLM can inform the user.

### System Prompt Guidance

The LLM should be prompted as "FinAlly, an AI trading assistant" with instructions to:
- Analyze portfolio composition, risk concentration, and P&L
- Suggest trades with reasoning
- Execute trades when the user asks or agrees
- Manage the watchlist proactively
- Be concise and data-driven in responses
- Always respond with valid structured JSON

### LLM Mock Mode

When `LLM_MOCK=true`, the backend returns deterministic mock responses instead of calling OpenRouter. This enables:
- Fast, free, reproducible E2E tests
- Development without an API key
- CI/CD pipelines

---

## 10. Frontend Design

### Layout

The frontend is a single-page application with a dense, terminal-inspired layout. The specific component architecture and layout system is up to the Frontend Engineer, but the UI should include these elements:

- **Watchlist panel** — grid/table of watched tickers with: ticker symbol, current price (flashing green/red on change), daily change %, and a sparkline mini-chart (accumulated from SSE since page load)
- **Main chart area** — larger chart for the currently selected ticker, with at minimum price over time. Clicking a ticker in the watchlist selects it here.
- **Portfolio heatmap** — treemap visualization where each rectangle is a position, sized by portfolio weight, colored by P&L (green = profit, red = loss)
- **P&L chart** — line chart showing total portfolio value over time, using data from `portfolio_snapshots`
- **Positions table** — tabular view of all positions: ticker, quantity, avg cost, current price, unrealized P&L, % change
- **Trade bar** — simple input area: ticker field, quantity field, buy button, sell button. Market orders, instant fill.
- **AI chat panel** — docked/collapsible sidebar. Message input, scrolling conversation history, loading indicator while waiting for LLM response. Trade executions and watchlist changes shown inline as confirmations.
- **Header** — portfolio total value (updating live), connection status indicator, cash balance

### Technical Notes

- Use `EventSource` for SSE connection to `/api/stream/prices`
- Canvas-based charting library preferred (Lightweight Charts or Recharts) for performance
- Price flash effect: on receiving a new price, briefly apply a CSS class with background color transition, then remove it
- All API calls go to the same origin (`/api/*`) — no CORS configuration needed
- Tailwind CSS for styling with a custom dark theme

---

## 11. Docker & Deployment

### Multi-Stage Dockerfile

```
Stage 1: Node 20 slim
  - Copy frontend/
  - npm install && npm run build (produces static export)

Stage 2: Python 3.12 slim
  - Install uv
  - Copy backend/
  - uv sync (install Python dependencies from lockfile)
  - Copy frontend build output into a static/ directory
  - Expose port 8000
  - CMD: uvicorn serving FastAPI app
```

FastAPI serves the static frontend files and all API routes on port 8000.

### Docker Volume

The SQLite database persists via a named Docker volume:

```bash
docker run -v finally-data:/app/db -p 8000:8000 --env-file .env finally
```

The `db/` directory in the project root maps to `/app/db` in the container. The backend writes `finally.db` to this path.

### Start/Stop Scripts

**`scripts/start_mac.sh`** (macOS/Linux):
- Builds the Docker image if not already built (or if `--build` flag passed)
- Runs the container with the volume mount, port mapping, and `.env` file
- Prints the URL to access the app
- Optionally opens the browser

**`scripts/stop_mac.sh`** (macOS/Linux):
- Stops and removes the running container
- Does NOT remove the volume (data persists)

**`scripts/start_windows.ps1`** / **`scripts/stop_windows.ps1`**: PowerShell equivalents for Windows.

All scripts should be idempotent — safe to run multiple times.

### Optional Cloud Deployment

The container is designed to deploy to AWS App Runner, Render, or any container platform. A Terraform configuration for App Runner may be provided in a `deploy/` directory as a stretch goal, but is not part of the core build.

---

## 12. Testing Strategy

### Unit Tests (within `frontend/` and `backend/`)

**Backend (pytest)**:
- Market data: simulator generates valid prices, GBM math is correct, Massive API response parsing works, both implementations conform to the abstract interface
- Portfolio: trade execution logic, P&L calculations, edge cases (selling more than owned, buying with insufficient cash, selling at a loss)
- LLM: structured output parsing handles all valid schemas, graceful handling of malformed responses, trade validation within chat flow
- API routes: correct status codes, response shapes, error handling

**Frontend (React Testing Library or similar)**:
- Component rendering with mock data
- Price flash animation triggers correctly on price changes
- Watchlist CRUD operations
- Portfolio display calculations
- Chat message rendering and loading state

### E2E Tests (in `test/`)

**Infrastructure**: A separate `docker-compose.test.yml` in `test/` that spins up the app container plus a Playwright container. This keeps browser dependencies out of the production image.

**Environment**: Tests run with `LLM_MOCK=true` by default for speed and determinism.

**Key Scenarios**:
- Fresh start: default watchlist appears, $10k balance shown, prices are streaming
- Add and remove a ticker from the watchlist
- Buy shares: cash decreases, position appears, portfolio updates
- Sell shares: cash increases, position updates or disappears
- Portfolio visualization: heatmap renders with correct colors, P&L chart has data points
- AI chat (mocked): send a message, receive a response, trade execution appears inline
- SSE resilience: disconnect and verify reconnection

---

## 13. Review Notes — Questions, Clarifications & Simplifications

*Added by a documentation review pass on 2026-09-08. Grounded against the plan as written and the market data subsystem already built in `backend/app/market/`. Items are grouped by how much they block downstream agents. Nothing here has been changed in the spec above — these are proposals and questions for the plan's owner.*

### 13.1 Blocking Decisions (a downstream agent cannot proceed without an answer)

**Q1 — "Daily change %" has no data source.**
§2 and §10 both require a daily change % in the watchlist, but the price model that exists (`PriceUpdate` in `backend/app/market/models.py`) only computes `change` / `change_percent` against the *previous tick* — roughly 500ms ago in the simulator, 15s ago via Massive. Those numbers will be near-zero noise, not a daily change. There is no stored session open or previous close anywhere in the schema or the cache.

Three options, please pick one:
- (a) Add `open_price` to `PriceUpdate` / `PriceCache`. Simulator uses `SEED_PRICES` as the day's open; Massive uses the snapshot's `todaysChangePerc` / previous-close field. Change % = change from open. **Recommended** — matches user expectation and is a small change to an already-tested module.
- (b) Capture the first price the process ever sees per ticker as the session baseline. Cheaper, but "daily" change resets whenever the container restarts.
- (c) Drop "daily" from the spec and display tick-to-tick change. Simplest, but the column will read 0.00% almost always.

**Q2 — Can the user hold a position in a ticker that is not on the watchlist?**
The plan never says. This matters because `remove_ticker()` in the existing `MarketDataSource` contract *also removes the ticker from the PriceCache*. So today, removing NVDA from the watchlist while holding 10 shares of NVDA silently deletes its price, and the portfolio can no longer be valued. Options:
- (a) The set of tracked tickers is `union(watchlist, open positions)`. Watchlist removal only removes from the cache if no position is held. **Recommended.**
- (b) Reject watchlist removal while a position is open (`409`).
- (c) Force-close the position on removal. (Surprising; not recommended.)

Whichever is chosen, §8 should state explicitly that `POST /api/watchlist` calls `source.add_ticker()` and `DELETE /api/watchlist/{ticker}` calls `source.remove_ticker()` — right now the API section and the market data section don't reference each other at all.

**Q3 — What happens when an unknown ticker is added?**
`seed_prices.py` only has parameters for the 10 default tickers. If the user (or the LLM, via `watchlist_changes`) adds `PYPL` — the plan's own example — or a typo like `APPL`, what happens in simulator mode? Is there a validation list, or does an unknown ticker get a randomly generated seed price and default GBM params? The LLM can invent symbols, so this path *will* be hit in the demo. Please specify: reject with a `400` against an allowlist, or accept anything and synthesize a seed. Note this behavior also differs by data source (Massive would return nothing for a bogus symbol), so the plan should say whether the two modes are allowed to diverge here.

**Q4 — Trade execution when no price is cached.**
Market orders fill "instantly at current price". If a ticker was just added and `PriceCache.get_price()` returns `None` (guaranteed for up to 15s in Massive mode), what does `POST /api/portfolio/trade` do? Suggest an explicit `409` with a "price not available yet" message, and the same guard on LLM-initiated trades.

**Q5 — The LLM error-reporting loop is not closed.**
§9 says "If a trade fails validation, the error is included in the chat response so the LLM can inform the user." But by the time trades execute (step 6), the LLM has already produced its message (step 4) — there is no second call. So the LLM cannot inform the user about a failure it never saw. Pick one:
- (a) The failure is returned as structured data in the `actions` payload and the **frontend** renders it inline (e.g. a red "Buy 10 AAPL — failed: insufficient cash" row). **Recommended** — no extra latency or token cost.
- (b) A second LLM round-trip on failure, so the assistant can apologize and re-plan. Doubles worst-case latency.

Related: if the LLM returns multiple trades, is execution **ordered** (a sell funding a subsequent buy) and is it **all-or-nothing or best-effort**? Please state both. Suggest: sequential in array order, best-effort, each result recorded individually.

### 13.2 Clarifications Needed (unblocked, but ambiguous enough to cause rework)

**C1 — SSE payload shape.** §6 describes an event as containing "ticker, price, previous price, timestamp, and change direction" — singular. The implemented endpoint emits **all tickers in one event**, as `{"AAPL": {...}, "GOOGL": {...}}`. The plan should record the actual shape, since the Frontend agent will code against this text. Also worth documenting: the stream is **change-triggered** (a version counter is polled every 500ms), not a fixed 500ms heartbeat, so in Massive mode a client sees roughly one event every 15 seconds.

**C2 — Chart history has no source, and the plan may be underestimating this.** §2 states sparklines accumulate on the frontend from SSE "since page load", and §10 asks for a main chart of "price over time" for the selected ticker. There is no price-history table and no history endpoint. Consequences as specified: every page refresh empties every chart, the "larger detailed chart" is blank for the first minute, and in Massive mode it gains 4 points per minute. If a populated chart on first paint matters to the demo, the cheapest fix is a server-side ring buffer (last N prices per ticker, in memory alongside `PriceCache`) plus `GET /api/history/{ticker}` — no schema change, no persistence. Please confirm whether empty-on-load is acceptable or the buffer should be added.

**C3 — P&L chart on a fresh database.** Snapshots are written every 30s and after each trade, so a brand-new user stares at a chart with zero or one point. Suggest seeding one snapshot at `total_value = 10000.0` during DB initialization.

**C4 — Position lifecycle on a full sell.** §7 says one row per ticker; the E2E scenarios say a position "updates or disappears". Pick one: delete the row at quantity 0, or keep it at 0 and filter in the API. This changes both the positions table and the heatmap.

**C5 — P&L definitions.** The plan only ever mentions *unrealized* P&L. If a user buys, the price rises, and they sell everything, that gain becomes cash and disappears from every P&L display. Please define the header figure explicitly — suggest `total_value = cash + Σ(qty × price)` and `total_return = total_value − 10000`, stated in the spec so the Backend and Frontend agents compute the same number. Also confirm no `realized_pnl` is being tracked (the schema has no column for it).

**C6 — Numeric rules.** Fractional shares are supported, so please state: minimum trade quantity (reject `0` and negatives?), rounding of cash (2dp?), and rounding of quantity. `PriceCache` already rounds prices to 2dp, which is worth noting in §6 since it means `avg_cost` will carry more precision than any displayed price.

**C7 — `chat_messages.actions` JSON shape is undefined.** The frontend renders these inline, so the shape is a cross-agent contract and belongs in §9 next to the request schema. Suggest including per-action status, e.g. `{"trades": [{"ticker": "AAPL", "side": "buy", "quantity": 10, "price": 190.12, "status": "ok"}], "watchlist_changes": [{"ticker": "PYPL", "action": "add", "status": "error", "error": "unknown ticker"}]}`.

**C8 — Conversation history is unbounded.** §9 step 2 says "recent conversation history" without a limit; over a long demo this grows without bound. Suggest an explicit cap (last 20 messages) written into the spec.

**C9 — `LLM_MOCK=true` needs a defined contract.** The E2E scenario "send a message, receive a response, trade execution appears inline" requires the mock to actually *return a trade*, which means it must be keyed off the input rather than returning one constant. Suggest specifying a small keyword table (e.g. a message containing "buy" returns a buy of 1 share of the first watchlist ticker) so the Testing and Backend agents agree.

**C10 — Structured output support on the chosen route.** §9 mandates Structured Outputs via `openrouter/openai/gpt-oss-120b` with Cerebras. Please confirm that route supports a JSON-schema `response_format`; if it only honors JSON mode, the spec should name the fallback (prompt-instructed JSON + Pydantic validation + one retry on parse failure). Worth pinning now because "always respond with valid structured JSON" in §9 is currently an instruction, not a guarantee.

**C11 — SQLite concurrency.** SSE connections, trade requests, and the 30-second snapshot task all touch the database from different threads/tasks. The plan should state the access rule — suggest WAL mode enabled at init, and either a single connection guarded by a lock or a connection per request. This is a classic source of `database is locked` errors under exactly this shape of workload.

**C12 — Connection status semantics.** Green/yellow/red is specified but `EventSource` only exposes `CONNECTING`/`OPEN`/`CLOSED`, and it retries indefinitely — so "red = disconnected" may never trigger. Suggest defining it in terms of observed behavior: green = event received within the last N seconds, yellow = `CONNECTING` or no event for N seconds, red = `CLOSED`. Note the "no event received" threshold has to differ between simulator (~500ms) and Massive (~15s) modes, or Massive mode will sit on yellow permanently.

**C13 — Chat request timeout.** §9 relies on Cerebras being "fast enough that a loading indicator is sufficient", but no timeout is specified for `POST /api/chat` on either side. Suggest a server-side timeout with a graceful error message.

### 13.3 Internal Inconsistencies

**I1 — The Docker volume section contradicts itself.** §11 says "The `db/` directory in the project root maps to `/app/db`", but the command directly above it mounts a **named volume** (`-v finally-data:/app/db`), which does *not* map the project's `db/` directory — the file would live inside Docker's volume storage and never appear in the repo. §4 compounds this by calling root `db/` the "volume mount target" with a `.gitkeep`. Please pick one and make all three places agree: a bind mount (`-v "$(pwd)/db:/app/db"`, host-visible, matches §4) or a named volume (delete the root `db/` directory from §4).

**I2 — Two different directories named `db`.** `backend/db/` (schema SQL and seed logic — source code) and root `db/` (the runtime SQLite file) will be a recurring source of confusion for both agents and students. Suggest renaming: schema/seed to `backend/app/db/`, runtime directory to `data/`.

**I3 — The database path needs to be configurable.** §7 hardcodes `db/finally.db`, but the backend runs from `backend/` in local development and from `/app` in the container, so a single relative path can't work in both. Add a `DATABASE_PATH` environment variable to §5 with a sensible default.

**I4 — Static file serving order is unspecified.** §3 shows `/*` serving the Next.js export and `/api/*` serving the API. With a catch-all mount, registration order determines whether API routes are shadowed. Worth one sentence in §11: API routers registered first, static mount last, plus how Next.js client-side routes resolve (the export produces `.html` files; confirm whether a SPA-style fallback to `index.html` is needed).

### 13.4 Simplification Opportunities

**S1 — Add one bootstrap endpoint; drop prices from the watchlist response.** Today a page load needs `/api/watchlist` + `/api/portfolio` + `/api/portfolio/history`, and every trade invalidates two of them. A single `GET /api/state` returning cash, positions, watchlist, and total value collapses that to one call on load and one after each trade. Simultaneously, having `/api/watchlist` return "latest prices" (§8) creates a second source of price truth alongside SSE, with no rule for which wins. Suggest: prices come **only** from SSE, and `/api/state` returns a one-time price snapshot purely for first paint. Net effect: fewer endpoints and one fewer class of stale-data bug.

**S2 — Commit to a single charting library.** §10 offers "Lightweight Charts or Recharts". These aren't interchangeable for this UI: the portfolio heatmap is a treemap, which Lightweight Charts does not provide. Naming one library that covers all four visualizations (watchlist sparkline, main price chart, treemap, P&L line) avoids shipping two charting dependencies. Recharts covers all four; Lightweight Charts would need a second library for the treemap.

**S3 — Run Playwright from the host instead of a second container.** §12 specifies a `docker-compose.test.yml` spinning up the app plus a Playwright container. Running Playwright on the host against the already-running app container achieves the same isolation goal (browser deps stay out of the production image) with no compose file, no second image to build, and a much better local debugging story (`--headed`, `--ui`). The compose file is only worth it if CI cannot install browsers, which is worth confirming before building it.

**S4 — Drop derived fields from the SSE payload.** Each event currently carries `change`, `change_percent`, and `direction` alongside `price` and `previous_price` — all three are trivially derivable client-side, and they're sent for every ticker on every tick. Minor, but it roughly shrinks the payload by a third on the hottest path in the app. (If Q1 lands on option (a), `open_price` should be added *instead of* these.)

**S5 — Specify the "SSE resilience" test concretely, or cut it.** "Disconnect and verify reconnection" is meaningfully hard to drive from Playwright (it needs CDP network manipulation or route interception). Either specify the mechanism in §12 or drop it to a manual smoke check — as written it's the scenario most likely to burn an agent's time for the least demo value.

**S6 — `create_stream_router()` currently uses a module-level router.** In `backend/app/market/stream.py` the factory decorates a router defined at module scope, so calling it twice would register the route twice on a shared object. Only matters if the app is ever constructed more than once in a process — which is exactly what a FastAPI test fixture does. Cheap fix: build the `APIRouter` inside the factory. Flagged here because §6 is the spec for that module.

### 13.5 Doc / Repo Drift

These aren't errors in the plan — the plan is the target — but the gaps are worth stating so nobody assumes they exist:

- §4's tree shows `frontend/`, `scripts/`, `test/`, and root `db/`. **None exist yet**; only `backend/` has been built. §4 is aspirational and should probably say so.
- §5 and §4 refer to a committed `.env.example`. **It does not exist.** Worth creating early, since it's the first thing a student touches.
- `backend/db/` (schema and seed logic, per §4) **does not exist yet** — the database layer is entirely unbuilt.
- `backend/pyproject.toml` does not yet include `litellm` or a dotenv loader, both of which §5 and §9 require.
- `MARKET_DATA_SUMMARY.md` documents `PriceUpdate` as carrying a `change` field; it is a computed property, not a stored field. Harmless, but the summary reads as though it's stored.

### 13.6 Smaller Suggestions

- **`GET /api/health` could carry more.** Returning the active market data source (`"simulator"` / `"massive"`), whether the background task is alive, and the ticker count makes the mode instantly visible during a demo and gives the E2E suite something cheap to assert.
- **State the trade-input validation surface.** The trade bar takes a free-text ticker; specify whether it must already be on the watchlist, and whether a successful trade auto-adds it. (This interacts with Q2.)
- **Selecting a ticker for the main chart** — worth stating the default selection on first load (suggest: first watchlist entry) so the chart area is never empty.
