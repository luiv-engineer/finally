# Market Simulator — Approach & Code Structure

**Purpose:** How FinAlly generates believable live stock prices with no API key, no network,
and no external dependency.

**Status:** Implemented in `backend/app/market/simulator.py` and `seed_prices.py`
(27 passing tests, 98% coverage). Sections marked **Δ** are proposed changes.

**Companion docs:** [MARKET_INTERFACE.md](MARKET_INTERFACE.md) (the contract this satisfies)
and [MASSIVE_API.md](MASSIVE_API.md) (the alternative provider).

---

## 1. Why the simulator is the default, not the fallback

It is tempting to read "simulator" as "the degraded mode you get without a key." For
FinAlly the opposite is true, and the Massive research (MASSIVE_API.md §2) makes the case
concrete:

| | Simulator | Massive free tier | Massive paid |
|---|---|---|---|
| Cost | $0 | $0 | $29–199/mo |
| Setup | none | signup + key | signup + card |
| Update cadence | 500ms | 15s (rate-limited) | 2–5s |
| Data recency | instant | **end-of-day** | 15-min delayed / real-time |
| Prices move on a Saturday | ✅ | ❌ | ❌ |
| Prices move at 2am | ✅ | ❌ | ❌ |
| Deterministic for tests | ✅ (seeded) | ❌ | ❌ |

A student running the capstone at 11pm on a Sunday with a free key sees a **frozen screen**.
The same student with no key at all sees a live, flickering trading terminal. The simulator
is the demo path, the test path, and the CI path. Massive mode exists for users who want
their portfolio to reflect reality.

Design goal, stated plainly: **look convincing to a human watching for thirty seconds, and
be boringly deterministic when seeded.**

---

## 2. The model: Geometric Brownian Motion

### 2.1 Why GBM

GBM is the standard model for equity prices — the basis of Black-Scholes — and it is the
right choice here for three properties, not because it is fancy:

1. **Prices cannot go negative.** The update is multiplicative (`S *= exp(...)`), so `S`
   asymptotically approaches zero but never crosses it. A random-walk-on-price model needs
   an explicit clamp and still looks wrong near zero.
2. **Volatility scales with price.** A $800 NVDA moves in dollars; a $50 stock moves in
   cents. That falls out of the model for free and is a large part of why the output
   *looks* real.
3. **It is calibrated in the units traders use.** `sigma` is annualized volatility —
   22% for AAPL, 50% for TSLA — so tuning the simulator means writing down numbers you can
   look up, not dimensionless fudge factors.

What GBM does not model, and we do not care: mean reversion, volatility clustering, fat
tails, bid-ask spread, volume, market microstructure. FinAlly is a UI demo, not a
backtester. §2.4 adds the one non-GBM behavior that earns its place.

### 2.2 The discrete step

```
S(t+dt) = S(t) · exp( (μ − σ²/2)·dt  +  σ·√dt·Z )
```

| Symbol | Meaning |
|---|---|
| `S(t)` | current price |
| `μ` | annualized drift (expected return) |
| `σ` | annualized volatility |
| `dt` | time step as a fraction of a trading year |
| `Z` | standard normal draw, **correlated across tickers** (§3) |

The `−σ²/2` term is the Itô correction. Without it the *median* path drifts down relative
to the intended `μ`, because `E[exp(X)] > exp(E[X])`. It is one term and it makes the drift
parameter mean what it says.

```python
drift     = (mu - 0.5 * sigma**2) * self._dt
diffusion = sigma * math.sqrt(self._dt) * z_correlated[i]
self._prices[ticker] *= math.exp(drift + diffusion)
```

### 2.3 Calibrating `dt` — and why the numbers work out

```python
TRADING_SECONDS_PER_YEAR = 252 * 6.5 * 3600   # 5,896,800
DEFAULT_DT = 0.5 / TRADING_SECONDS_PER_YEAR   # ≈ 8.48e-8
```

252 trading days × 6.5 hours × 3600 seconds. A 500ms tick is therefore ~8.5×10⁻⁸ of a
trading year. Worth verifying the end-to-end result rather than trusting the algebra:

For AAPL (`S=190`, `σ=0.22`):

| Horizon | Ticks | Price σ | As % |
|---|---|---|---|
| 1 tick (0.5s) | 1 | $0.012 | 0.006% |
| 1 minute | 120 | $0.135 | 0.07% |
| 1 hour | 7,200 | $1.04 | 0.55% |
| 1 session (6.5h) | 46,800 | $2.64 | **1.39%** |

And 1.39% × √252 = **22.1% annualized** — which is the `σ=0.22` we asked for. The
calibration is correct, and the per-tick move is ~1 cent, which is exactly the granularity
that makes a price flash animation look alive rather than either frozen or seizing.

**Δ Known edge case — low-priced tickers tick slowly.** Per-tick standard deviation is
`S·σ·√dt`. At `σ=0.25` that is `S × 7.28e-5`, so a cent of movement needs `S ≳ $69` to be a
one-tick event. A $50 ticker changes its displayed (2dp) price roughly every 8 ticks — about
4 seconds. This is *not* a bug: the internal `self._prices[ticker]` is kept unrounded and
accumulates correctly; only the visible 2dp value steps less often. But it does mean a
cheap stock looks sleepy next to NVDA. If that matters visually, either raise `σ` for
low-priced tickers or keep synthesized seed prices above ~$70 (§5.2).

### 2.4 Random shock events

Pure GBM at these parameters is *too* smooth — it never does anything a demo audience
notices. One deliberate deviation:

```python
if random.random() < self._event_prob:          # 0.001 per tick per ticker
    shock_magnitude = random.uniform(0.02, 0.05)
    shock_sign = random.choice([-1, 1])
    self._prices[ticker] *= 1 + shock_magnitude * shock_sign
```

Arrival rate: 10 tickers × 2 ticks/sec × 0.001 = **0.02 events/sec ≈ one every 50 seconds**.
Frequent enough that a viewer sees one, rare enough that it reads as an event rather than
noise. Magnitude 2–5% is large against a 1.39% daily σ — unmistakable on a sparkline.

This is the knob to reach for when someone says "the demo looks boring."

---

## 3. Correlation — the detail that sells it

Ten independent random walks look wrong. Real tech stocks move together; when NVDA gaps
up, AAPL and MSFT usually drift up too. Independent walks produce a watchlist where half
the rows are green and half red at all times, which reads as noise rather than a market.

### 3.1 Cholesky decomposition

To draw correlated normals with target correlation matrix `C`:

1. Factor `C = L·Lᵀ` where `L` is lower-triangular (Cholesky).
2. Draw `n` independent standard normals `Z`.
3. `L·Z` has exactly correlation `C`, and each component is still standard normal.

```python
z_independent = np.random.standard_normal(n)
z_correlated  = self._cholesky @ z_independent
```

Two lines on the hot path. `L` is recomputed only when the ticker set changes.

### 3.2 The correlation structure

```python
CORRELATION_GROUPS = {
    "tech":    {"AAPL", "GOOGL", "MSFT", "AMZN", "META", "NVDA", "NFLX"},
    "finance": {"JPM", "V"},
}
INTRA_TECH_CORR    = 0.6   # tech stocks move together
INTRA_FINANCE_CORR = 0.5   # finance stocks move together
CROSS_GROUP_CORR   = 0.3   # between sectors, and for unknown tickers
TSLA_CORR          = 0.3   # TSLA does its own thing
```

Resolution order in `_pairwise_correlation`:

```
TSLA involved?      → 0.3   (checked first; TSLA is in the tech set but overridden)
both tech?          → 0.6
both finance?       → 0.5
otherwise           → 0.3
```

TSLA is deliberately decoupled — it is in the tech set for grouping purposes but the
override runs first, so it drifts on its own. This is both realistic and useful: it
guarantees that at any moment at least one row is moving against the pack, so the watchlist
never looks like a single blinking organism.

Unknown tickers land at 0.3 against everything, which is a reasonable market-beta default.

### 3.3 Δ Positive-definiteness is not guaranteed

`np.linalg.cholesky` raises `LinAlgError` on a matrix that is not positive definite. The
current 10-ticker matrix factors fine, but the rules are ad-hoc pairwise assignments, not a
factor model — there is no theorem protecting an arbitrary ticker set from producing an
indefinite matrix. Since the LLM can add tickers at runtime (PLAN.md §9), a
`LinAlgError` inside `_rebuild_cholesky()` would propagate out of `add_ticker()` and take
down a chat request.

Defensive fix, ~6 lines:

```python
def _rebuild_cholesky(self) -> None:
    ...
    try:
        self._cholesky = np.linalg.cholesky(corr)
    except np.linalg.LinAlgError:
        # Nudge toward the identity until it factors; worst case, uncorrelated.
        logger.warning("Correlation matrix not positive definite; damping")
        for damping in (0.9, 0.7, 0.5, 0.0):
            damped = damping * corr + (1 - damping) * np.eye(n)
            try:
                self._cholesky = np.linalg.cholesky(damped)
                return
            except np.linalg.LinAlgError:
                continue
        self._cholesky = None      # fall back to independent draws
```

Degrading to uncorrelated prices is a cosmetic loss. Crashing a chat turn is not.

---

## 4. Code structure

Two classes, deliberately split.

```
seed_prices.py          data only — no logic
    SEED_PRICES         {ticker: starting price}
    TICKER_PARAMS       {ticker: {sigma, mu}}
    DEFAULT_PARAMS      for unknown tickers
    CORRELATION_GROUPS  sector membership
    *_CORR constants    correlation coefficients

simulator.py
    GBMSimulator        pure, synchronous math. No asyncio, no cache, no I/O.
    SimulatorDataSource MarketDataSource impl. Owns the asyncio task and the cache write.
```

### 4.1 `GBMSimulator` — the math, in isolation

```python
class GBMSimulator:
    TRADING_SECONDS_PER_YEAR = 252 * 6.5 * 3600
    DEFAULT_DT = 0.5 / TRADING_SECONDS_PER_YEAR

    def __init__(self, tickers: list[str], dt: float = DEFAULT_DT,
                 event_probability: float = 0.001) -> None: ...

    def step(self) -> dict[str, float]:   # advance all tickers once; hot path
    def add_ticker(self, ticker: str) -> None:      # rebuilds Cholesky
    def remove_ticker(self, ticker: str) -> None:   # rebuilds Cholesky
    def get_price(self, ticker: str) -> float | None
    def get_tickers(self) -> list[str]
```

State: `_tickers` (ordered — the Cholesky row order depends on it), `_prices` (unrounded
floats), `_params`, `_cholesky`.

Keeping this class free of asyncio and free of `PriceCache` is the single most useful
structural decision here. `step()` is a pure-ish function of internal state: a test can
call it 46,800 times in a fraction of a second and assert the realized volatility matches
`σ`, with no event loop, no sleeping, and no mocking.

### 4.2 `SimulatorDataSource` — the plumbing

```python
class SimulatorDataSource(MarketDataSource):
    def __init__(self, price_cache: PriceCache,
                 update_interval: float = 0.5,
                 event_probability: float = 0.001) -> None: ...

    async def start(self, tickers):     # build sim, seed cache, spawn task
    async def stop(self):               # cancel task, swallow CancelledError
    async def add_ticker(self, t):      # sim.add + immediate cache write
    async def remove_ticker(self, t):   # sim.remove + cache.remove
    def get_tickers(self): ...

    async def _run_loop(self):
        while True:
            try:
                prices = self._sim.step()
                for ticker, price in prices.items():
                    self._cache.update(ticker=ticker, price=price)
            except Exception:
                logger.exception("Simulator step failed")   # never kill the loop
            await asyncio.sleep(self._interval)
```

Three things this gets right and that any rewrite must preserve:

* **`start()` seeds the cache before returning.** The first SSE event after boot has data.
* **`add_ticker()` writes a price immediately.** Unlike Massive, the simulator has no
  reason to make a newly-added ticker unpriceable for 15 seconds, so it doesn't.
* **The loop catches and logs rather than dying.** A background task that raises
  disappears silently and the whole app goes quiet with no error surfaced anywhere.

### 4.3 Δ Timing drift

`await asyncio.sleep(0.5)` after the work means the true period is `0.5 + step_time`, so
ticks drift slowly late. At ~50µs per step for 10 tickers this is invisible. If the ticker
count ever grows enough to matter, switch to deadline scheduling:

```python
next_tick = time.monotonic()
while True:
    ...
    next_tick += self._interval
    await asyncio.sleep(max(0, next_tick - time.monotonic()))
```

Noted for completeness; not worth doing today.

---

## 5. Seed data

### 5.1 The default ten

```python
SEED_PRICES = {"AAPL": 190.00, "GOOGL": 175.00, "MSFT": 420.00, "AMZN": 185.00,
               "TSLA": 250.00, "NVDA": 800.00, "META": 500.00, "JPM": 195.00,
               "V": 280.00, "NFLX": 600.00}
```

Roughly realistic, and — more importantly — **spread across a wide range** ($175 to $800).
That spread is what makes the portfolio treemap and the positions table look like real
data instead of ten variations on $100.

```python
TICKER_PARAMS = {
    "AAPL":  {"sigma": 0.22, "mu": 0.05},
    "GOOGL": {"sigma": 0.25, "mu": 0.05},
    "MSFT":  {"sigma": 0.20, "mu": 0.05},
    "AMZN":  {"sigma": 0.28, "mu": 0.05},
    "TSLA":  {"sigma": 0.50, "mu": 0.03},   # high vol, low drift
    "NVDA":  {"sigma": 0.40, "mu": 0.08},   # high vol, strong drift
    "META":  {"sigma": 0.30, "mu": 0.05},
    "JPM":   {"sigma": 0.18, "mu": 0.04},   # low vol (bank)
    "V":     {"sigma": 0.17, "mu": 0.04},   # low vol (payments)
    "NFLX":  {"sigma": 0.35, "mu": 0.05},
}
DEFAULT_PARAMS = {"sigma": 0.25, "mu": 0.05}
```

The σ spread (0.17 → 0.50) is doing visible work: JPM and V barely move while TSLA and NVDA
jump around. A viewer reads that as "different kinds of stock" without being told.

`μ` is nearly irrelevant over a demo session — at `μ=0.05`, expected drift over a 6.5-hour
session is 0.02%, buried under a 1.39% σ. It exists so that a container left running
overnight trends gently upward instead of random-walking to zero.

### 5.2 Δ Unknown tickers should be deterministic

```python
self._prices[ticker] = SEED_PRICES.get(ticker, random.uniform(50.0, 300.0))
```

`random.uniform` means `ACME` is $73 on one restart and $284 on the next — and if a
position in it survives in the SQLite volume, its P&L jumps wildly across restarts for no
reason the user can see. Derive it from the symbol instead:

```python
def _seed_price_for(ticker: str) -> float:
    if ticker in SEED_PRICES:
        return SEED_PRICES[ticker]
    h = int(hashlib.sha256(ticker.encode()).hexdigest()[:8], 16)
    return round(80.0 + (h % 22000) / 100.0, 2)     # deterministic, $80–$300
```

The $80 floor also sidesteps the slow-tick issue from §2.3. Same ticker, same price, every
run — which additionally makes E2E tests that add a ticker assertable.

### 5.3 Δ Session open, for the daily-change column

MARKET_INTERFACE.md §4.1 adopts `open_price` on `PriceUpdate` to give the watchlist a real
daily change %. The simulator's answer is trivial: **the seed price *is* the session open.**

```python
async def start(self, tickers):
    self._sim = GBMSimulator(tickers, event_probability=self._event_prob)
    for ticker in tickers:
        price = self._sim.get_price(ticker)
        if price is not None:
            self._cache.update(ticker=ticker, price=price, open_price=price)
```

`open_price` is written once and never changed, so `day_change_percent` becomes "how far
has this moved since the app started" — which is exactly what a viewer of a running demo
expects the number to mean.

---

## 6. Tuning guide

The knob to turn when someone reports a symptom:

| Symptom | Knob | Direction |
|---|---|---|
| "Nothing is moving" | `SIM_UPDATE_INTERVAL` | ↓ toward 0.25s |
| "Prices barely change" | `TICKER_PARAMS[t]["sigma"]` | ↑ (0.4–0.8 is dramatic) |
| "Too jumpy / seizure-inducing" | `sigma` | ↓, or `update_interval` ↑ |
| "It's boring, nothing happens" | `event_probability` | ↑ to 0.003 (~1 event / 17s) |
| "Everything moves as one block" | `INTRA_TECH_CORR` | ↓ toward 0.4 |
| "It looks like pure noise" | `INTRA_TECH_CORR` | ↑ toward 0.75 |
| "Portfolio always loses money" | `mu` | ↑ (but σ dominates over a demo) |
| "CPU is high" | `SIM_UPDATE_INTERVAL` | ↑ |

Per MARKET_INTERFACE.md §6, `SIM_UPDATE_INTERVAL` and `SIM_EVENT_PROBABILITY` should be
environment-wired so this table can be applied without a rebuild.

---

## 7. Testing

The point of splitting `GBMSimulator` out is that the interesting assertions need no async
machinery.

**Statistical properties** — seed the RNG, run many steps, assert on the distribution:

```python
def test_realized_volatility_matches_sigma():
    np.random.seed(42); random.seed(42)
    sim = GBMSimulator(["AAPL"], event_probability=0.0)   # shocks off
    prices = [sim.get_price("AAPL")]
    for _ in range(46_800):                                # one trading session
        prices.append(sim.step()["AAPL"])
    log_returns = np.diff(np.log(prices))
    annualized = log_returns.std() * np.sqrt(GBMSimulator.TRADING_SECONDS_PER_YEAR / 0.5)
    assert 0.18 < annualized < 0.26                        # target 0.22
```

Turn `event_probability` to `0.0` for any statistical test — the 2–5% shocks are by design
far outside the GBM distribution and will blow up the variance estimate.

**Correlation:**

```python
def test_tech_stocks_correlate():
    sim = GBMSimulator(["AAPL", "MSFT", "JPM"], event_probability=0.0)
    series = {t: [] for t in ["AAPL", "MSFT", "JPM"]}
    for _ in range(20_000):
        for t, p in sim.step().items():
            series[t].append(p)
    r = lambda a, b: np.corrcoef(np.diff(np.log(series[a])), np.diff(np.log(series[b])))[0, 1]
    assert r("AAPL", "MSFT") > r("AAPL", "JPM")     # 0.6 vs 0.3
```

**Invariants** — cheap and worth having: prices stay strictly positive over 100k steps;
`step()` returns exactly the tracked ticker set; `add`/`remove` keep `_tickers`, `_prices`,
`_params` and the Cholesky dimension in agreement; removing an untracked ticker is a no-op.

**`SimulatorDataSource`** — construct with `update_interval=0.01`, `await asyncio.sleep(0.1)`,
assert ~10 ticks landed in the cache and the version counter advanced. Fast enough for CI.

**Δ Add:** a `LinAlgError` regression test for §3.3, and a determinism test for §5.2 asserting
the same unknown ticker yields the same seed price across two `GBMSimulator` instances.

Current coverage: 27 tests, `simulator.py` at 98%.

---

## 8. Performance

Per tick with 10 tickers: one `numpy.random.standard_normal(10)`, one 10×10 matrix-vector
product, then ten `math.exp` calls and ten dict writes. Roughly **50µs**, twice a second —
about 0.01% of one core. The `PriceCache` writes take a `threading.Lock` ten times per
tick, uncontended.

Cost is `O(n)` per tick and `O(n³)` on the Cholesky rebuild, which happens only on ticker
add/remove. At `n=50` the rebuild is still sub-millisecond. Nothing here needs optimizing at
FinAlly's scale; the numbers are recorded so nobody optimizes it anyway.

---

## 9. Summary of deltas

| # | Change | Why | Effort |
|---|---|---|---|
| 1 | `LinAlgError` guard in `_rebuild_cholesky` | An LLM-added ticker could crash a chat turn | ~6 lines |
| 2 | Deterministic seed price for unknown tickers | Stable P&L and assertable E2E tests across restarts | ~8 lines |
| 3 | Pass `open_price` on the initial cache seed | Makes the daily-change % column real | 1 line |
| 4 | Env-wire `SIM_UPDATE_INTERVAL` / `SIM_EVENT_PROBABILITY` | Apply the §6 tuning table without a rebuild | 2 lines |
| 5 | Deadline-based tick scheduling | Removes slow drift; only matters at high ticker counts | ~4 lines |

Items 1–3 are worth doing. Item 4 is a convenience. Item 5 is a note for the future.
