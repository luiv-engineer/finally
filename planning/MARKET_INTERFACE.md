# Market Interface — Unified Price API

**Purpose:** The single Python abstraction FinAlly uses to get stock prices, regardless of
whether they come from the Massive API or the built-in simulator.

**Status:** The core of this design is implemented in `backend/app/market/` (8 modules,
73 passing tests). Sections marked **Δ** describe deltas from the current code — either
corrections forced by the Massive research or additions needed by downstream agents.

**Companion docs:** [MASSIVE_API.md](MASSIVE_API.md) (the real-data provider) and
[MARKET_SIMULATOR.md](MARKET_SIMULATOR.md) (the default provider).

---

## 1. The one rule

> **Producers write to the cache. Consumers read from the cache. Nothing else talks to a
> market data provider.**

Everything below is elaboration on that sentence. Trade execution does not call Massive.
The SSE endpoint does not call the simulator. Portfolio valuation does not know which
source is running. There is exactly one place where "where does a price come from" is
decided — `create_market_data_source()` — and it is decided once, at startup.

```
                    MASSIVE_API_KEY?
                           │
              ┌────────────┴────────────┐
              │                         │
   SimulatorDataSource          MassiveDataSource
   (GBM, ~500ms ticks)          (REST poll, 2–15s)
              │                         │
              └────────────┬────────────┘
                           ▼
                    ┌─────────────┐
                    │ PriceCache  │  ← the boundary
                    └──────┬──────┘
                           │
        ┌──────────────────┼──────────────────┬──────────────┐
        ▼                  ▼                  ▼              ▼
  SSE /api/stream    Portfolio value   Trade execution   /api/health
```

Why this shape: it means the simulator is not a "test double" bolted on beside the real
thing — both are first-class producers behind the same contract, so the code path
exercised in tests and demos is the code path that runs in production.

---

## 2. Module layout

`backend/app/market/` — all of it already exists:

| Module | Exports | Role |
|---|---|---|
| `models.py` | `PriceUpdate` | Immutable price snapshot |
| `interface.py` | `MarketDataSource` | The ABC both providers implement |
| `cache.py` | `PriceCache` | Thread-safe store + version counter |
| `simulator.py` | `GBMSimulator`, `SimulatorDataSource` | Default provider |
| `massive_client.py` | `MassiveDataSource` | Real-data provider |
| `factory.py` | `create_market_data_source` | Env-driven selection |
| `seed_prices.py` | seed prices, GBM params, correlations | Simulator config |
| `stream.py` | `create_stream_router` | SSE endpoint |

Public surface, from `app.market`:

```python
from app.market import (
    PriceUpdate,
    PriceCache,
    MarketDataSource,
    create_market_data_source,
    create_stream_router,
)
```

Downstream agents should import only these five names. `GBMSimulator`, `MassiveDataSource`
and the seed tables are internal.

---

## 3. `MarketDataSource` — the contract

```python
class MarketDataSource(ABC):
    """Contract for market data providers.

    Implementations push price updates into a shared PriceCache on their own
    schedule. Downstream code never calls the data source directly for prices —
    it reads from the cache.
    """

    @abstractmethod
    async def start(self, tickers: list[str]) -> None:
        """Begin producing updates. Starts a background task. Call exactly once."""

    @abstractmethod
    async def stop(self) -> None:
        """Stop the background task. Idempotent."""

    @abstractmethod
    async def add_ticker(self, ticker: str) -> None:
        """Add to the active set. No-op if present."""

    @abstractmethod
    async def remove_ticker(self, ticker: str) -> None:
        """Remove from the active set and from the cache. No-op if absent."""

    @abstractmethod
    def get_tickers(self) -> list[str]:
        """Currently tracked tickers."""
```

Five methods, all that is needed. Note what is deliberately *absent*: there is no
`get_price()` on the source. Asking a source for a price would let a caller bypass the
cache and reintroduce provider-specific latency and failure modes into request handling.

### Δ 3.1 — Add `describe()` for health and diagnostics

PLAN.md §13.6 asks `/api/health` to report the active source. Rather than have the route
sniff `isinstance()`, add a sixth method:

```python
@dataclass(frozen=True, slots=True)
class SourceStatus:
    source: str          # "simulator" | "massive"
    mode: str            # "gbm" | "snapshot" | "grouped_daily"
    running: bool
    ticker_count: int
    delayed: bool        # True for Massive below Advanced, False for the simulator
    last_update_age: float | None   # seconds since the last cache write, None if never

@abstractmethod
def describe(self) -> SourceStatus:
    """Current operational state, for /api/health and the demo."""
```

Cheap to implement, and it makes the free-tier degradation described in MASSIVE_API.md §2
visible in the UI instead of mysterious.

### 3.2 Lifecycle rules

* `start()` **must seed the cache synchronously before returning.** Both implementations do
  this — the simulator writes initial seed prices, Massive performs one immediate poll.
  Without it, the first SSE event after boot is empty and the frontend paints a blank grid.
* `add_ticker()` **should populate a price as soon as it can.** The simulator can do it
  immediately. Massive cannot — the price appears on the next poll, up to 15s later. This
  asymmetry is the root of PLAN.md §13.1 Q4 and is handled in §7.2.
* `stop()` must be safe to call twice and must not raise on an already-cancelled task.
* Calling `start()` twice is undefined behavior. The app calls it once, in the lifespan
  handler.

---

## 4. `PriceUpdate` — the data model

```python
@dataclass(frozen=True, slots=True)
class PriceUpdate:
    ticker: str
    price: float
    previous_price: float
    timestamp: float          # Unix SECONDS
    open_price: float | None  # Δ session open — see below

    @property
    def change(self) -> float: ...            # vs previous tick
    @property
    def change_percent(self) -> float: ...    # vs previous tick
    @property
    def direction(self) -> str: ...           # "up" | "down" | "flat"

    # Δ new
    @property
    def day_change(self) -> float | None: ...        # price - open_price
    @property
    def day_change_percent(self) -> float | None: ...

    def to_dict(self) -> dict: ...
```

Frozen and slotted: it is created on the hot path (10 tickers × 2/sec) and shared across
threads, so immutability removes a whole class of race condition and `slots` keeps
allocation cheap.

### Δ 4.1 — `open_price` resolves the "daily change %" gap

PLAN.md §13.1 Q1 flags that the watchlist's daily-change column has no data source:
`change_percent` compares against the tick ~500ms ago, so it is near-zero noise. Adopting
**option (a)** from that review:

| Source | `open_price` |
|---|---|
| Simulator | the ticker's `SEED_PRICES` value — the day's notional open, fixed for the process lifetime |
| Massive (snapshot) | `day.open`, falling back to `prev_day.close` (MASSIVE_API.md §5.3 `extract_open`) |
| Massive (grouped daily) | the bar's `o` |
| Unknown ticker, simulator | the synthesized seed price |

`PriceCache.update()` accepts `open_price` and, once set for a ticker, **never overwrites
it with `None`** — a later poll that lacks the field must not erase a good value.

The frontend shows `day_change_percent` in the watchlist and `change`/`direction` for the
flash animation. Two different numbers for two different jobs; both are now well-defined.

### 4.2 Rounding

`PriceCache.update()` rounds `price` and `previous_price` to 2dp on write, so every
consumer sees the same value and no display layer has to re-round. This is deliberate and
has a consequence worth stating (PLAN.md §13.2 C6): **`avg_cost` in the positions table
carries more precision than any displayed price**, because it is an average of 2dp fills
divided by a possibly-fractional quantity. Round it for display only.

---

## 5. `PriceCache` — the boundary

```python
class PriceCache:
    def update(self, ticker, price, timestamp=None, open_price=None) -> PriceUpdate
    def get(self, ticker) -> PriceUpdate | None
    def get_all(self) -> dict[str, PriceUpdate]
    def get_price(self, ticker) -> float | None
    def remove(self, ticker) -> None
    @property
    def version(self) -> int
    def __len__(self) / __contains__(self, ticker)
```

Guarded by a `threading.Lock`, not an asyncio lock — the Massive provider writes from a
worker thread via `asyncio.to_thread`, so the primitive has to be thread-safe, not just
task-safe. Critical sections are a few dict operations; contention is not a concern at
10–50 tickers.

**The version counter is the SSE engine.** Every write bumps a monotonic integer. The SSE
generator polls `cache.version` and only serializes and emits when it changes. This means:

* In simulator mode the client gets ~2 events/sec (every tick changes every price).
* In Massive mode the client gets ~1 event per poll interval, not 2/sec of duplicates.
* A disconnected-and-reconnected client immediately gets a full snapshot on its first
  differing version.

Change-triggered, not heartbeat-driven. PLAN.md §6 describes a fixed 500ms cadence; the
implemented behavior is better and the plan should record it.

### Δ 5.1 — Optional: history ring buffer

PLAN.md §13.2 C2 notes that charts are empty on every page load because history only
accumulates client-side from SSE. If a populated chart on first paint matters, the cheapest
fix lives here — not in the database:

```python
class PriceCache:
    def __init__(self, history_size: int = 240) -> None:
        self._history: dict[str, deque[tuple[float, float]]] = {}  # (ts, price)

    def get_history(self, ticker: str) -> list[tuple[float, float]]:
        """Recent (timestamp, price) pairs, oldest first."""
```

240 points at 500ms is two minutes of tick history, or — if the source is Massive —
an hour of 15s polls. Memory is ~4KB per ticker. Serve it from `GET /api/history/{ticker}`
for first paint, then let SSE take over. No schema change, no persistence, and it survives
a browser refresh (which is the actual complaint) while resetting on container restart
(which nobody notices).

If the team prefers real history, MASSIVE_API.md §5.6 shows the `get_aggs()` backfill —
but that only works in Massive mode, so the ring buffer is still needed for the simulator.
**Recommendation: build the ring buffer, skip the backfill.**

---

## 6. Provider selection

```python
def create_market_data_source(price_cache: PriceCache) -> MarketDataSource:
    """MASSIVE_API_KEY set and non-empty → MassiveDataSource, else SimulatorDataSource.

    Returns an *unstarted* source. Caller must await source.start(tickers).
    """
    api_key = os.environ.get("MASSIVE_API_KEY", "").strip()
    if api_key:
        logger.info("Market data source: Massive API (real data)")
        return MassiveDataSource(api_key=api_key, price_cache=price_cache)
    logger.info("Market data source: GBM Simulator")
    return SimulatorDataSource(price_cache=price_cache)
```

`.strip()` matters: `MASSIVE_API_KEY=` in a `.env` file yields `""`, and an accidental
`MASSIVE_API_KEY=" "` should not route a student to a provider they cannot use.

### Environment variables

| Variable | Default | Effect |
|---|---|---|
| `MASSIVE_API_KEY` | unset | Set → Massive; unset/empty → simulator |
| `MASSIVE_POLL_INTERVAL` | `15.0` | **Δ** Seconds between polls. 15 is safe on the 5/min free tier; 2–5 on paid |
| `SIM_UPDATE_INTERVAL` | `0.5` | **Δ** Simulator tick period in seconds |
| `SIM_EVENT_PROBABILITY` | `0.001` | **Δ** Per-tick, per-ticker chance of a 2–5% shock |

The three Δ variables are already constructor parameters with these defaults; they just are
not wired to the environment yet. Wiring them costs three lines in the factory and makes
the demo tunable without a code change.

---

## 7. Wiring into FastAPI

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI
from app.market import PriceCache, create_market_data_source, create_stream_router

@asynccontextmanager
async def lifespan(app: FastAPI):
    cache = PriceCache()
    source = create_market_data_source(cache)

    tickers = load_tracked_tickers()          # see §7.1
    await source.start(tickers)               # returns with the cache already seeded

    app.state.price_cache = cache
    app.state.market_source = source
    try:
        yield
    finally:
        await source.stop()

app = FastAPI(lifespan=lifespan)
app.include_router(create_stream_router(app.state.price_cache))   # API routes first
# ... other /api routers ...
# app.mount("/", StaticFiles(...))                                # static mount LAST
```

Registration order matters — a catch-all static mount registered before the API routers
shadows them (PLAN.md §13.3 I4).

### Δ 7.1 — The tracked set is `watchlist ∪ open positions`

PLAN.md §13.1 Q2 asks whether a position can exist off-watchlist. Adopting **option (a)**,
because it is the only one that cannot produce an unvaluable portfolio:

```python
def load_tracked_tickers() -> list[str]:
    return sorted(set(db.get_watchlist()) | set(db.get_position_tickers()))

async def remove_from_watchlist(ticker: str) -> None:
    db.delete_watchlist_entry(ticker)
    if not db.has_position(ticker):        # ← the guard
        await source.remove_ticker(ticker)  # only now drop the price
```

Without that guard, removing NVDA from the watchlist while holding 10 shares deletes its
cached price, and total portfolio value silently becomes wrong. The watchlist is a *view*;
the tracked set is a *requirement*.

Correspondingly, `POST /api/watchlist` calls `source.add_ticker()` and
`DELETE /api/watchlist/{ticker}` calls `source.remove_ticker()` subject to the guard. PLAN.md
§8 should say so — right now the API and market-data sections don't reference each other.

### Δ 7.2 — "No price yet" is a real state

`cache.get_price(t)` returns `None` when a ticker was just added and no update has landed —
guaranteed for up to `MASSIVE_POLL_INTERVAL` seconds in Massive mode. Every consumer needs
an answer (PLAN.md §13.1 Q4):

| Consumer | Behavior on `None` |
|---|---|
| Trade execution | `409 {"error": "price_unavailable", "ticker": "PYPL"}` — do not fill at a guessed price |
| LLM-initiated trade | Same guard; record `{"status": "error", "error": "price not available yet"}` in the action payload |
| Portfolio valuation | Value the position at `avg_cost` and flag `stale: true` rather than dropping it |
| Watchlist row | Render a `—` placeholder; the row appears, the price fills in |
| SSE | Ticker is simply absent from the payload until it has a price |

### Δ 7.3 — Unknown tickers

PLAN.md §13.1 Q3: the LLM can and will invent symbols. The two providers behave
differently and the interface should not pretend otherwise:

* **Simulator:** accepts anything. `_add_ticker_internal` synthesizes a seed price via
  `random.uniform(50, 300)` and applies `DEFAULT_PARAMS`. `APPL` becomes a tradeable stock.
* **Massive:** a bogus symbol is simply absent from the snapshot response — no error, no
  row. It will never get a price, and per §7.2 it will never be tradeable.

**Recommendation:** validate at the API layer, not in the source. `POST /api/watchlist`
checks the ticker against a regex (`^[A-Z]{1,5}$`) and, in Massive mode, against a
single-ticker snapshot probe; reject with `400` on failure. In simulator mode accept any
well-formed symbol — a student typing `ACME` and getting a chart is a feature, not a bug.
Document the divergence rather than forcing the simulator to maintain an allowlist it has
no way to keep accurate.

---

## 8. The SSE contract

```
GET /api/stream/prices        Content-Type: text/event-stream
```

The stream emits **one event containing every tracked ticker**, not one event per ticker:

```
retry: 1000

data: {"AAPL": {"ticker":"AAPL","price":190.50,"previous_price":190.42,
                "timestamp":1757433600.123,"open_price":190.00,
                "change":0.08,"change_percent":0.042,"direction":"up",
                "day_change":0.50,"day_change_percent":0.263}, "GOOGL": {...}}
```

PLAN.md §6 describes a per-ticker event shape; the implemented (and correct) shape is the
batched dict above. One event per tick beats ten, and the frontend wants to apply all
updates in one render pass anyway.

* `retry: 1000` is sent first, so `EventSource` reconnects after 1s.
* Emission is change-triggered off `cache.version`, polled every 500ms.
* Client disconnect is detected via `request.is_disconnected()` and ends the generator.

### Δ 8.1 — Connection status thresholds

PLAN.md §13.2 C12 notes that `EventSource` never reports "disconnected" because it retries
forever. Define status by *observed data*, with the threshold scaled to the source — which
the frontend can learn from `/api/health`:

| Status | Condition |
|---|---|
| 🟢 green | An event arrived within `2 × expected_interval` |
| 🟡 yellow | No event for longer than that, or `readyState === CONNECTING` |
| 🔴 red | `readyState === CLOSED` |

`expected_interval` is 0.5s in simulator mode and `MASSIVE_POLL_INTERVAL` in Massive mode.
Without this, Massive mode sits on yellow permanently.

### Δ 8.2 — Build the router inside the factory

`stream.py` decorates a module-level `router`, so calling `create_stream_router()` twice
registers the route twice on a shared object — which is exactly what a pytest fixture that
builds a fresh app per test does. Move `APIRouter(...)` inside the factory. Two-line fix
(PLAN.md §13.4 S6).

### Δ 8.3 — On payload size

PLAN.md §13.4 S4 proposes dropping `change`/`change_percent`/`direction` as
client-derivable. Keep them. At 10 tickers × 2/sec the payload is ~2KB/s on localhost, the
frontend needs `direction` on every single tick for the flash animation, and having the
server compute it once guarantees the flash matches the number displayed. Optimizing this
trades a real correctness guarantee for bandwidth nobody is paying for. Revisit at 100+
tickers.

---

## 9. Consumer usage

```python
from app.market import PriceCache, create_market_data_source

cache: PriceCache = request.app.state.price_cache

update = cache.get("AAPL")            # PriceUpdate | None
price  = cache.get_price("AAPL")      # float | None
snap   = cache.get_all()              # dict[str, PriceUpdate]

# Portfolio valuation — the canonical formula (PLAN.md §13.2 C5)
def total_value(cash: float, positions: list[Position]) -> float:
    return cash + sum(p.quantity * (cache.get_price(p.ticker) or p.avg_cost)
                      for p in positions)

total_return = total_value(cash, positions) - 10_000.0
```

Stated once here so the Backend and Frontend agents compute the same number: **`total_value
= cash + Σ(qty × price)`** and **`total_return = total_value − 10000`**. There is no
`realized_pnl` column in the schema and none is tracked; a realized gain simply becomes
cash and shows up in `total_return`.

---

## 10. Testing

The interface is designed to be testable without network or wall-clock waits.

| Target | Approach |
|---|---|
| `PriceCache` | Direct — no async, no I/O. Assert version bumps, rounding, `open_price` stickiness |
| `PriceUpdate` | Pure property math, including the zero-`previous_price` and `None`-`open_price` guards |
| `GBMSimulator` | Seed `random`/`numpy`, call `step()` in a loop, assert prices stay positive and correlations hold |
| `SimulatorDataSource` | Real asyncio task with `update_interval=0.01`; a 100ms sleep gives ~10 ticks |
| `MassiveDataSource` | **Δ** Build fixtures with real `TickerSnapshot.from_dict()`, not `MagicMock` — see below. Cover a Basic-tier `403`, a Starter snapshot with `last_trade=None`, and a snapshot missing a requested ticker |
| Factory | `monkeypatch.setenv` — key present, absent, empty, whitespace |
| SSE | `httpx.AsyncClient` against a test app; read two events and assert the batched dict shape |

The current suite has 73 tests at 84% coverage. `massive_client.py` sits at 56% because the
API calls are mocked — the Δ fixtures above are the gap worth closing, since they cover the
failure modes a real free-tier user will actually hit.

**The `MagicMock` trap, concretely.** `test_massive.py` builds snapshots as `MagicMock()`
and sets `snap.last_trade.timestamp = ...`. A `MagicMock` invents any attribute on demand,
so the test passes against an attribute the real `LastTrade` model does not have
(MASSIVE_API.md §4). That is how delta #1 in §11 shipped green. The rule worth adopting for
any provider client: **mock the transport, not the model.** Patch `_fetch_snapshots` to
return real `TickerSnapshot.from_dict(sample_json)` objects, so the deserialization
contract is exercised rather than assumed.

---

## 11. Summary of deltas from the current implementation

Ordered by consequence:

| # | Change | Why | Effort |
|---|---|---|---|
| 1 | `last_trade.timestamp` → `.sip_timestamp`, `/1e9` | Live `AttributeError`; the cache never fills in Massive mode | 2 lines |
| 2 | Price fallback chain instead of `last_trade.price` | `last_trade` is absent below the Developer plan | ~10 lines |
| 3 | Capability probe → grouped-daily fallback on `403` | The free tier has no snapshot access at all | ~30 lines |
| 4 | `open_price` on `PriceUpdate`/`PriceCache` | Makes the daily-change % column real (Q1) | ~20 lines |
| 5 | `union(watchlist, positions)` tracked set + removal guard | Prevents unvaluable portfolios (Q2) | ~10 lines |
| 6 | `None`-price guards in trade paths | Prevents fills at guessed prices (Q4) | ~10 lines |
| 7 | `describe()` → `/api/health` | Makes the active mode and delay visible | ~25 lines |
| 8 | `APIRouter` inside `create_stream_router()` | Double registration under test fixtures | 2 lines |
| 9 | History ring buffer + `/api/history/{ticker}` | Charts populated on first paint (C2) | ~40 lines |
| 10 | Env-wire the interval/probability constructor params | Tunable demo without a rebuild | 3 lines |

Items 1–3 are corrections: without them Massive mode does not work at all. Items 4–8 close
questions PLAN.md §13 raises as blocking. Items 9–10 are improvements that can wait.
