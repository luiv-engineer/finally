# Massive API — Research & Reference

**Purpose:** Everything the FinAlly backend needs to know about retrieving real-time and
end-of-day stock prices from Massive (formerly Polygon.io).

**Researched:** 2026-09-09. Verified against the live docs at `massive.com/docs`, the
`massive` PyPI package metadata, and the source of `massive==2.2.0` as installed in
`backend/.venv`.

**Companion docs:** [MARKET_INTERFACE.md](MARKET_INTERFACE.md) (the abstraction we build on
top of this) and [MARKET_SIMULATOR.md](MARKET_SIMULATOR.md) (the no-API-key default).

---

## 1. Orientation

Polygon.io rebranded to **Massive** in early 2026. It is the same platform: same endpoint
paths, same response shapes, same account. What changed:

| | Old | New |
|---|---|---|
| Docs | `polygon.io/docs` | `massive.com/docs` |
| REST base URL | `https://api.polygon.io` | `https://api.massive.com` |
| Python SDK | `polygon-api-client` (`import polygon`) | `massive` (`import massive`) |
| API key env var | `POLYGON_API_KEY` | `MASSIVE_API_KEY` |
| WebSocket host | `socket.polygon.io` | `socket.massive.com` |

Legacy Polygon hostnames still resolve, but **all new code should use the Massive names.**
The endpoint *paths* (`/v2/snapshot/...`, `/v2/aggs/...`) are unchanged — this is why every
Polygon tutorial on the internet still applies.

Massive covers US stocks, options, indices, forex, crypto and futures. FinAlly uses **US
stocks only**.

### Products

| Product | Shape | FinAlly uses it? |
|---|---|---|
| **REST API** | Request/response over HTTPS | ✅ Yes — this is our integration |
| **WebSocket API** | Persistent stream of trades/quotes/aggregates | ❌ No — see §8 |
| **Flat Files** | Bulk CSV on S3 for backtesting | ❌ No |

---

## 2. ⚠️ The single most important finding: snapshots are not on the free tier

**PLAN.md §6 currently says "Free tier (5 calls/min): poll every 15 seconds" against the
snapshot endpoint. That does not work.** The snapshot endpoints are gated to paid plans.

Verified plan matrix (from `massive.com/pricing` and the per-endpoint "Plan Access" tables):

| Plan | Price/mo | API calls | Recency | History | Trades | Quotes | **Snapshots** | WebSocket |
|---|---|---|---|---|---|---|---|---|
| **Stocks Basic** | $0 | **5/min** | **End-of-day** | 2 years | ❌ | ❌ | **❌** | ❌ |
| Stocks Starter | $29 | Unlimited | 15-min delayed | 5 years | ❌ | ❌ | ✅ | ✅ |
| Stocks Developer | $79 | Unlimited | 15-min delayed | 10 years | ✅ | ❌ | ✅ | ✅ |
| Stocks Advanced | $199 | Unlimited | Real-time | 20+ years | ✅ | ✅ | ✅ | ✅ |
| Stocks Business | Custom | Unlimited | Real-time | All | ✅ | ✅ | ✅ | ✅ |

Three consequences that shape the whole design:

1. **A free (Basic) key gets HTTP 403 from `get_snapshot_all()`.** The current
   `MassiveDataSource` will log `Massive poll failed: ...` on every cycle and the price
   cache will stay permanently empty. Aggregate endpoints must be used instead.
2. **`lastTrade` is empty below Developer.** A Starter key ($29) *can* call snapshots, but
   the `lastTrade` object — which the current implementation reads as
   `snap.last_trade.price` — requires the trades entitlement. On Starter, expect
   `last_trade is None` and an `AttributeError`, which the current code swallows as a
   warning and skips the ticker. **Never treat `last_trade.price` as the only price
   source.** Use the fallback chain in §5.3.
3. **Only Advanced ($199) is actually real-time.** Starter and Developer are 15 minutes
   delayed. "Live streaming prices" in FinAlly's Massive mode means "15-minute-delayed
   prices, repolled every N seconds", unless the user is on Advanced.

**Recommendation for the project:** keep the simulator as the default and the demo path.
Treat Massive mode as a correctness feature for users who happen to have a paid key, and
degrade gracefully (§9) rather than assuming any particular entitlement.

---

## 3. Authentication, base URL, rate limits

### Auth

Two equivalent forms. The Python SDK uses the header.

```bash
# Header (preferred)
curl -H "Authorization: Bearer $MASSIVE_API_KEY" \
  "https://api.massive.com/v2/aggs/ticker/AAPL/prev"

# Query string (handy for browser debugging; leaks the key into logs)
curl "https://api.massive.com/v2/aggs/ticker/AAPL/prev?apiKey=$MASSIVE_API_KEY"
```

The SDK reads `MASSIVE_API_KEY` from the environment automatically if you construct
`RESTClient()` with no arguments — which is exactly the variable name PLAN.md §5 already
specifies. Convenient, but FinAlly passes it explicitly so the factory stays testable.

### Rate limits

* **Basic: 5 requests/minute.** Hard. Exceeding it returns `429`.
* **Starter and above: unlimited** (fair-use).

A 5/min budget means **one API call every 12 seconds at most**. The existing 15-second
default poll interval fits with margin — but only if each poll is *a single request for all
tickers*, never one request per ticker. Both the snapshot endpoint and the grouped-daily
endpoint satisfy that; per-ticker endpoints like `/v2/aggs/ticker/{t}/prev` do not.

The SDK's `urllib3` retry strategy already includes `429` in its `status_forcelist` with
`retries=3` by default, so short bursts are retried transparently with backoff. That is
helpful but not a substitute for a correct poll interval.

### Errors

| Status | Meaning | What FinAlly should do |
|---|---|---|
| `200` | OK | Parse |
| `401` | Missing/invalid key | Log loudly once, fall back to the simulator |
| `403` `NOT_AUTHORIZED` | Valid key, plan lacks this endpoint/data | Downgrade to an endpoint the plan allows (§9) |
| `429` | Rate limited | Back off; increase poll interval |
| `5xx` | Massive-side | Retry on the next poll cycle |

The SDK raises on any non-200:

```python
from massive.exceptions import AuthError, BadResponse
# AuthError   -> empty or malformed API key (raised client-side, before the request)
# BadResponse -> non-200 response; the exception message is the raw response body
```

Note `BadResponse` carries only the decoded body string, not the status code. To
distinguish 403 from 429 you must either substring-match the body (`"NOT_AUTHORIZED"`) or
bypass the SDK's error handling with `raw=True`. §9 shows the pragmatic version.

---

## 4. The Python SDK

```toml
# backend/pyproject.toml — already present
dependencies = [
    "massive>=1.0.0",   # 2.2.0 installed; 2.8.0 is current as of May 2026
]
```

* Package: `massive` — "Official Massive (formerly Polygon.io) REST and Websocket client."
* Repo: `github.com/massive-com/client-python`
* Requires Python ≥3.9. Dependencies: `certifi`, `urllib3`, `websockets`.

### Client construction

```python
from massive import RESTClient

client = RESTClient(
    api_key=api_key,        # defaults to os.getenv("MASSIVE_API_KEY")
    connect_timeout=10.0,
    read_timeout=10.0,
    num_pools=10,
    retries=3,              # urllib3 Retry; forcelist includes 429, 413, 503
    base="https://api.massive.com",
    pagination=True,
    verbose=False,
)
```

### ⚠️ The SDK is synchronous

`RESTClient` is built on `urllib3` and blocks. FinAlly's backend is FastAPI/asyncio, so
**every SDK call must be wrapped**:

```python
snapshots = await asyncio.to_thread(client.get_snapshot_all, "stocks", tickers)
```

The current `MassiveDataSource._poll_once()` already does this correctly via
`asyncio.to_thread(self._fetch_snapshots)`. Preserve that pattern — a blocking 10-second
read timeout on the event loop would stall every SSE stream simultaneously.

### Naming convention: snake_case models over camelCase JSON

The SDK deserializes into dataclass-like model objects and renames fields. This trips
people up constantly, so here is the mapping for everything FinAlly touches:

| Raw JSON | SDK attribute | Model |
|---|---|---|
| `ticker` | `.ticker` | `TickerSnapshot` |
| `todaysChange` | `.todays_change` | `TickerSnapshot` |
| `todaysChangePerc` | `.todays_change_percent` | `TickerSnapshot` |
| `updated` | `.updated` (ns) | `TickerSnapshot` |
| `lastTrade` | `.last_trade` | `LastTrade` |
| `lastQuote` | `.last_quote` | `LastQuote` |
| `day` / `prevDay` | `.day` / `.prev_day` | `Agg` |
| `min` | `.min` | `MinuteSnapshot` |
| `fmv` | `.fair_market_value` | `TickerSnapshot` |
| `o`/`h`/`l`/`c` | `.open`/`.high`/`.low`/`.close` | `Agg`, `MinuteSnapshot` |
| `v` / `vw` / `n` / `t` | `.volume`/`.vwap`/`.transactions`/`.timestamp` | `Agg` |
| `T` (in grouped) | `.ticker` | `GroupedDailyAgg` |
| `p` (in lastTrade) | `.price` | `LastTrade` |
| `t` (in lastTrade) | `.sip_timestamp` ⚠️ | `LastTrade` |

**⚠️ `LastTrade` has no `.timestamp` attribute.** The verified field list is:

```python
LastTrade(ticker, trf_timestamp, sequence_number, sip_timestamp, participant_timestamp,
          conditions, correction, id, price, trf_id, size, exchange, tape)
```

The current `massive_client.py` reads `snap.last_trade.timestamp`, which raises
`AttributeError` — caught by the `except (AttributeError, TypeError)` handler, so **every
ticker is silently skipped and the cache never fills, even on a Developer key.** Use
`.sip_timestamp` (see §5.3). This is a live bug, not a hypothetical:

```
>>> lt = LastTrade.from_dict({"p": 120.47, "t": 1605195918306274000})
>>> lt.sip_timestamp
1605195918306274000
>>> lt.timestamp
AttributeError: 'LastTrade' object has no attribute 'timestamp'
```

**Why 73 passing tests do not catch it:** `tests/market/test_massive.py` builds snapshots
from `MagicMock()`, and a `MagicMock` auto-creates any attribute you ask for — including
`.timestamp`. The mock is more permissive than the real model, so the test asserts a code
path that cannot execute against the SDK. Fixtures for this client should use real
`TickerSnapshot.from_dict()` objects built from the sample JSON in §5.1, not `MagicMock`.

### Timestamp units are not uniform

| Field | Unit |
|---|---|
| `LastTrade.sip_timestamp` | **nanoseconds** |
| `TickerSnapshot.updated` | **nanoseconds** |
| `Agg.timestamp` (day/prevDay/bars) | **milliseconds** |
| `MinuteSnapshot.timestamp` | **milliseconds** |

`PriceCache.update()` expects Unix **seconds**. The current code divides by `1000.0`, which
is correct for `Agg` but off by 10⁶ for a trade timestamp. Divide by `1e9` for
nanosecond fields.

---

## 5. Endpoints FinAlly cares about

### 5.1 Full Market Snapshot — the primary path (Starter+)

```
GET /v2/snapshot/locale/us/markets/stocks/tickers
```

| Param | Type | Notes |
|---|---|---|
| `tickers` | csv string | Case-sensitive. Empty → **all ~10,000 US tickers** |
| `include_otc` | bool | Default `false` |

Response:

```json
{
  "count": 1,
  "status": "OK",
  "tickers": [{
    "ticker": "AAPL",
    "todaysChange": 0.98,
    "todaysChangePerc": 0.82,
    "updated": 1605195918306274000,
    "day":      {"o": 119.62, "h": 120.53, "l": 118.81, "c": 120.4229, "v": 28727868, "vw": 119.725},
    "prevDay":  {"o": 117.19, "h": 119.63, "l": 116.44, "c": 119.49,   "v": 110597265, "vw": 118.4998},
    "min":      {"av": 28724441, "o": 120.435, "h": 120.468, "l": 120.37, "c": 120.4201,
                 "v": 270796, "vw": 120.4129, "n": 762, "t": 1684428720000},
    "lastTrade":{"p": 120.47, "s": 236, "t": 1605195918306274000, "x": 10, "c": [14, 41], "i": "4046"},
    "lastQuote":{"p": 120.46, "s": 8, "P": 120.47, "S": 4, "t": 1605195918507251700}
  }]
}
```

**Why this endpoint is the right one:** N tickers in *one* HTTP call, and it carries
`todaysChangePerc` — a genuine day-over-day change, which is precisely the data source
PLAN.md §13.1 Q1 says is missing for the watchlist's "daily change %" column.

Caveats:
* `day` is **zeroed before the session opens.** Snapshot data is cleared at 12am ET and
  repopulates from ~4am ET. Pre-market, `day.close` is `0`, and `todaysChangePerc` is `0`.
* `lastTrade`/`lastQuote` are present only with the matching entitlement (§2).
* Requesting a ticker that does not exist returns *nothing for that ticker* — no error, no
  placeholder. The response array is simply shorter than the request list. This is how
  FinAlly can detect a bogus symbol the LLM invented (PLAN.md §13.1 Q3).

```python
from massive import RESTClient
from massive.rest.models import SnapshotMarketType

client = RESTClient(api_key=api_key)
snapshots = client.get_snapshot_all(
    market_type=SnapshotMarketType.STOCKS,
    tickers=["AAPL", "GOOGL", "MSFT"],
)
for s in snapshots:
    print(s.ticker, s.last_trade.price if s.last_trade else s.day.close,
          s.todays_change_percent)
```

### 5.2 Single Ticker Snapshot

```
GET /v2/snapshot/locale/us/markets/stocks/tickers/{stocksTicker}
```

Same payload for one ticker, returned as `{"ticker": {...}}` rather than a list. SDK:
`client.get_snapshot_ticker("stocks", "AAPL")`. Same plan gating as §5.1.

FinAlly should **not** use this for polling — N tickers means N calls. It is only useful as
a validation probe when a single new ticker is added to the watchlist.

### 5.3 Extracting one price from a snapshot — the fallback chain

Given the entitlement matrix, no single field is reliable. Prefer freshest-available:

```python
def extract_price(snap) -> float | None:
    """Freshest available price from a TickerSnapshot, degrading by entitlement."""
    if snap.last_trade and snap.last_trade.price:        # Developer+ : actual last trade
        return snap.last_trade.price
    if snap.min and snap.min.close:                      # Starter+   : last minute bar
        return snap.min.close
    if snap.day and snap.day.close:                      # any        : today's close-so-far
        return snap.day.close
    if snap.prev_day and snap.prev_day.close:            # pre-market fallback
        return snap.prev_day.close
    return None


def extract_timestamp(snap) -> float | None:
    """Unix SECONDS. Note the differing source units."""
    if snap.last_trade and snap.last_trade.sip_timestamp:
        return snap.last_trade.sip_timestamp / 1e9      # nanoseconds
    if snap.min and snap.min.timestamp:
        return snap.min.timestamp / 1e3                 # milliseconds
    if snap.updated:
        return snap.updated / 1e9                       # nanoseconds
    return None


def extract_open(snap) -> float | None:
    """Session open, for a true daily-change %. Falls back to prior close."""
    if snap.day and snap.day.open:
        return snap.day.open
    if snap.prev_day and snap.prev_day.close:
        return snap.prev_day.close
    return None
```

`extract_open()` is what lets the watchlist show a real "daily change %" instead of
tick-to-tick noise. See MARKET_INTERFACE.md §4.

### 5.4 Daily Market Summary (grouped daily) — the free-tier path

```
GET /v2/aggs/grouped/locale/us/market/stocks/{date}
```

| Param | Type | Notes |
|---|---|---|
| `date` | `YYYY-MM-DD` (path) | The trading day |
| `adjusted` | bool | Default `true` |
| `include_otc` | bool | Default `false` |

Returns **every US ticker's OHLCV for that day in one response**, ~10,000 rows:

```json
{"status":"OK","adjusted":true,"queryCount":9852,"resultsCount":9852,
 "results":[{"T":"AAPL","o":115.55,"h":117.59,"l":114.13,"c":115.97,
             "v":131704427,"vw":116.3058,"t":1605042000000,"n":95246}]}
```

**Available on every plan including Basic** — this is the free-tier escape hatch. One call
per poll cycle, well inside 5/min, and it yields both a price (`c`) and a session open
(`o`) for every watchlist ticker at once.

```python
from datetime import date, timedelta

bars = client.get_grouped_daily_aggs(date="2026-09-08", adjusted=True)
wanted = {"AAPL", "GOOGL", "MSFT"}
prices = {b.ticker: b.close for b in bars if b.ticker in wanted}
```

Two gotchas:
* **Empty on non-trading days.** A weekend or holiday date returns `resultsCount: 0`. Walk
  back day by day (up to ~5) until you get results.
* **`GroupedDailyAgg` maps `T` → `.ticker`**, unlike plain `Agg`, which has no ticker field
  at all.

Caveat: the values are end-of-day, so nothing moves. In free-tier Massive mode the FinAlly
UI is *correct* but *static*. That is the honest trade-off, and another reason the
simulator is the better default for a live-looking demo.

### 5.5 Previous Day Bar

```
GET /v2/aggs/ticker/{stocksTicker}/prev?adjusted=true
```

```python
bars = client.get_previous_close_agg("AAPL", adjusted=True)
prev_close = bars[0].close
```

All plans. One ticker per call, so it burns the 5/min budget fast — use it only for
single-ticker validation, never for polling a watchlist.

### 5.6 Custom Bars (OHLC) — chart history backfill

```
GET /v2/aggs/ticker/{stocksTicker}/range/{multiplier}/{timespan}/{from}/{to}
```

| Param | Notes |
|---|---|
| `multiplier` | integer, e.g. `5` |
| `timespan` | `second`, `minute`, `hour`, `day`, `week`, `month`, `quarter`, `year` |
| `from` / `to` | `YYYY-MM-DD` or millisecond epoch |
| `adjusted` | default `true` |
| `sort` | `asc` \| `desc` |
| `limit` | max 50000, default 5000 |

```python
bars = client.get_aggs("AAPL", 5, "minute", "2026-09-08", "2026-09-09", limit=500)
series = [{"t": b.timestamp / 1000, "price": b.close} for b in bars]
```

All plans (Basic capped at 2 years of history). **This is the answer to PLAN.md §13.2 C2** —
if the main price chart should be populated on first paint rather than accumulating from
SSE, `get_aggs(ticker, 5, "minute", today, today)` backfills it in one call per ticker.
Use `list_aggs()` instead of `get_aggs()` when you want the SDK's auto-pagination.

### 5.7 Unified Snapshot (v3) — noted, not recommended

```
GET /v3/snapshot?ticker.any_of=AAPL,GOOGL&limit=250
```

`client.list_universal_snapshots(type="stocks", ticker_any_of=[...], limit=250)`. Handles
up to 250 tickers, spans asset classes, returns a paginating iterator. Also **unavailable
on Basic**. It offers nothing over §5.1 for a 10-ticker watchlist, and its paginated
iterator complicates the `asyncio.to_thread` wrapper. Skip it.

---

## 6. Endpoint decision table for FinAlly

| Need | Endpoint | SDK call | Calls per poll | Min plan |
|---|---|---|---|---|
| Live-ish prices for the watchlist | Full Market Snapshot | `get_snapshot_all` | **1** | Starter |
| Prices on a free key | Grouped Daily | `get_grouped_daily_aggs` | **1** | Basic |
| Daily change % | (in snapshot) `todaysChangePerc` | — | 0 | Starter |
| Daily change % on free key | Grouped Daily `o` vs `c` | — | 0 | Basic |
| Chart history backfill | Custom Bars | `get_aggs` | 1/ticker, once | Basic |
| Validate an unknown ticker | Full Market Snapshot | absent from response | 0 | Starter |

---

## 7. Market hours

| Session | ET | Snapshot behavior |
|---|---|---|
| Overnight | 12:00am–4:00am | `day` cleared to zeros |
| Pre-market | 4:00am–9:30am | Populates as trades arrive |
| Regular | 9:30am–4:00pm | Fully live (subject to plan delay) |
| After-hours | 4:00pm–8:00pm | Continues updating |
| Weekend/holiday | — | Frozen at Friday's close |

Nothing in FinAlly's UI should assume prices change. In Massive mode outside market hours
the price flash animation simply never fires and the sparklines are flat lines. Worth
surfacing in `/api/health` (§9) so a demo doesn't look broken when it is merely Saturday.

---

## 8. WebSocket — why we are not using it

Massive offers `wss://socket.massive.com/stocks` with `T` (trades), `Q` (quotes), `A`
(per-second aggregates), `AM` (per-minute aggregates), and the SDK ships a
`WebSocketClient`. Feed hosts are enumerated in `massive.websocket.models.common.Feed`
(`RealTime = "socket.massive.com"`, `Delayed = "delayed.massive.com"`, plus per-plan hosts).

We use REST polling anyway because:

1. **It is not on the free tier**, so it cannot be the only path — we'd need the REST
   fallback regardless, and two code paths is worse than one.
2. FinAlly's own client-facing transport is SSE at ~500ms. A per-second aggregate stream
   adds no perceptible fidelity over a 2–15s poll.
3. REST polling has no connection lifecycle, no resubscription on watchlist change, no
   heartbeat handling. PLAN.md §3 explicitly chose the simpler transport at every layer;
   the same reasoning applies here.

Documented so nobody re-litigates it later; revisit only if FinAlly grows a real-time
requirement the simulator cannot fake.

---

## 9. Recommended client behavior for FinAlly

Concrete deltas from the current `backend/app/market/massive_client.py`:

1. **Fix `.timestamp` → `.sip_timestamp`** and divide by `1e9`. (§4 — this is the bug that
   would empty the cache even on a fully-entitled key.)
2. **Use the `extract_price` fallback chain** (§5.3) rather than `last_trade.price` alone.
3. **Capability probe on `start()`.** First poll determines the mode:
   ```python
   async def _probe(self) -> str:
       try:
           await asyncio.to_thread(self._fetch_snapshots)
           return "snapshot"
       except BadResponse as e:
           if "NOT_AUTHORIZED" in str(e):
               logger.warning("Massive key lacks snapshot access (Basic plan); "
                              "falling back to end-of-day grouped aggregates")
               return "grouped_daily"
           raise
   ```
   Then poll via the chosen strategy. Log the resolved mode once at startup.
4. **Don't swallow every exception identically.** `401` should surface as a startup error
   (the key is wrong — the user wants to know). `429`/`5xx` should be a debug-level retry.
   The current blanket `except Exception: logger.error(...)` makes a bad key look like a
   transient blip forever.
5. **Poll interval by plan.** Default 15s (safe on Basic). Allow override via
   `MASSIVE_POLL_INTERVAL`; on a paid key 2–5s is fine.
6. **Expose mode in `/api/health`**: `{"source": "massive", "mode": "snapshot",
   "delayed": true, "tickers": 10, "last_poll_age_s": 3.2}`. PLAN.md §13.6 asks for this
   and it makes the free-tier degradation visible instead of mysterious.
7. **Never call with an empty `tickers` list.** `get_snapshot_all("stocks", [])` sends no
   `tickers` param, which means *all ~10,000 US tickers* — a multi-megabyte response. The
   current `_poll_once()` guards with `if not self._tickers: return`; keep that guard.

---

## 10. Quick reference

```python
import asyncio
from massive import RESTClient
from massive.rest.models import SnapshotMarketType
from massive.exceptions import AuthError, BadResponse

client = RESTClient(api_key=..., retries=3)

# All watchlist prices in one call (Starter+)
snaps = await asyncio.to_thread(
    client.get_snapshot_all, SnapshotMarketType.STOCKS, ["AAPL", "MSFT"])

# All US tickers' EOD bars in one call (Basic)
bars = await asyncio.to_thread(client.get_grouped_daily_aggs, "2026-09-08")

# Intraday history for one ticker (Basic)
hist = await asyncio.to_thread(client.get_aggs, "AAPL", 5, "minute",
                               "2026-09-08", "2026-09-09")

# Previous close for one ticker (Basic)
prev = await asyncio.to_thread(client.get_previous_close_agg, "AAPL")
```

| Constant | Value |
|---|---|
| REST base | `https://api.massive.com` |
| Env var | `MASSIVE_API_KEY` |
| SDK package | `massive` (2.2.0 pinned; 2.8.0 current) |
| Free-tier limit | 5 req/min |
| Safe poll interval | 15s free, 2–5s paid |
| Snapshot max tickers | unbounded csv (v2) / 250 (v3) |
| Bars max limit | 50,000 |

## Sources

- [Massive API Docs](https://massive.com/docs)
- [Stocks REST API Overview](https://massive.com/docs/rest/stocks/overview)
- [Full Market Snapshot](https://massive.com/docs/rest/stocks/snapshots/full-market-snapshot)
- [Single Ticker Snapshot](https://massive.com/docs/rest/stocks/snapshots/single-ticker-snapshot)
- [Unified Snapshot](https://massive.com/docs/rest/stocks/snapshots/unified-snapshot)
- [Custom Bars (OHLC)](https://massive.com/docs/rest/stocks/aggregates/custom-bars)
- [Daily Market Summary](https://massive.com/docs/rest/stocks/aggregates/daily-market-summary)
- [Previous Day Bar](https://massive.com/docs/rest/stocks/aggregates/previous-day-bar)
- [Pricing](https://massive.com/pricing)
- [massive on PyPI](https://pypi.org/project/massive/) · [client-python on GitHub](https://github.com/massive-com/client-python)
