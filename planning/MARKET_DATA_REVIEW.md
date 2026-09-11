# Market Data Backend — Code Review (Follow-up)

**Date:** 2026-09-11
**Scope:** `backend/app/market/` (8 source files, ~350 statements) and `backend/tests/market/` (6 test files, 73 tests)
**Context:** A prior review (`planning/archive/MARKET_DATA_REVIEW.md`, 2026-02-10) found 7 issues, all reportedly fixed per `planning/MARKET_DATA_SUMMARY.md`. This review starts from that fixed state, re-verifies the fixes, runs the suite fresh, and looks for regressions or anything missed.

---

## 1. Test Results

**73 tests collected, 73 passed, 0 failed.** (`uv run --extra dev pytest -v`)

The `massive` package installs cleanly and is used directly — none of the fragility from the prior review (lazy-import patch targets, `massive` missing from the test env) is present anymore. `uv sync --extra dev` and the build itself also succeed without the `ValueError: Unable to determine which files to ship` error the prior review hit; `[tool.hatch.build.targets.wheel] packages = ["app"]` is in place in `pyproject.toml`.

**Lint (`ruff check app/ tests/`):** All checks passed. No unused imports remain.

**Coverage (`pytest --cov=app --cov-report=term-missing`):** 91% overall (up from 84%, since `massive` is now actually installed and exercised rather than being mocked around).

| Module | Coverage | Missing |
|---|---|---|
| `__init__.py` (market) | 100% | |
| `cache.py` | 100% | |
| `factory.py` | 100% | |
| `interface.py` | 100% | |
| `models.py` | 100% | |
| `seed_prices.py` | 100% | |
| `massive_client.py` | 94% | 85-87 (poll-loop sleep/re-poll cycle), 125 (`_fetch_snapshots` body itself, by design — real network call) |
| `simulator.py` | 98% | 149 (duplicate-add guard in `_add_ticker_internal`), 268-269 (exception log line in `_run_loop`) |
| `stream.py` | 33% | 26-48, 62-87 — the whole SSE generator has no dedicated test |

---

## 2. Verification of Prior Fixes

All 7 issues from the archived review were checked against current source and confirmed fixed:

1. **Build config** — `[tool.hatch.build.targets.wheel] packages = ["app"]` present; `uv sync` succeeds. ✅
2. **Lazy imports removed** — `massive_client.py` now imports `RESTClient` and `SnapshotMarketType` at module level. `factory.py` also imports `MassiveDataSource` unconditionally. Tests that `patch("app.market.massive_client.RESTClient")` now target a real name. ✅
3. **SSE return type** — `_generate_events` is annotated `-> AsyncGenerator[str, None]`. ✅
4. **Public `get_tickers()`** — `GBMSimulator.get_tickers()` exists; `SimulatorDataSource.get_tickers()` calls it instead of reaching into `self._sim._tickers`. ✅
5. **`DEFAULT_CORR` removed** — `seed_prices.py` no longer defines it; `_pairwise_correlation` falls through to `CROSS_GROUP_CORR` for unmatched pairs, which is the correct and now-unambiguous name. ✅
6. **Unused test imports** — none flagged by ruff. ✅
7. **Massive test mocks** — all 13 tests in `test_massive.py` pass, including the two that previously failed on `patch("...RESTClient")`. ✅

---

## 3. Finding: `PriceCache.remove()` Didn't Bump the Version Counter — FIXED

**Severity: Medium. Status: Fixed** (`backend/app/market/cache.py`, plus two new regression tests in `backend/tests/market/test_cache.py`). Originally a regression relative to the documented design (`planning/MARKET_DATA_DESIGN.md` §4 shows `remove()` incrementing `self._version`), and not caught by the test suite at the time.

`backend/app/market/cache.py`:

```python
def remove(self, ticker: str) -> None:
    """Remove a ticker from the cache (e.g., when removed from watchlist)."""
    with self._lock:
        self._prices.pop(ticker, None)
```

No `self._version += 1`. The SSE endpoint (`stream.py`) only serializes and pushes a new payload when `price_cache.version != last_version`, so a ticker removal is invisible to already-connected SSE clients until *something else* happens to bump the version.

**Confirmed by direct reproduction:**

```
cache.update('AAPL', 190.0); cache.update('GOOGL', 175.0)
cache.remove('GOOGL')
# version before: 2, version after: 2  (unchanged — should be 3)
```

**Concretely demonstrated end-to-end** with `SimulatorDataSource`: removing the *last* tracked ticker leaves the cache version frozen forever afterward, because `GBMSimulator.step()` returns `{}` for zero tickers and nothing else ever calls `cache.update()`:

```
await source.start(['AAPL']); ...
v_before = cache.version         # 5
await source.remove_ticker('AAPL')
... (0.3s / several loop ticks pass) ...
v_after = cache.version          # still 5 — never advances
```

**Impact:**
- **Simulator source, non-empty watchlist:** self-heals almost immediately — any other ticker's next tick bumps the shared version counter, so the removed ticker drops out of the next SSE payload within ~500ms. Low practical impact for the common case.
- **Simulator source, last ticker removed (empty watchlist):** the stale, now-deleted ticker is served to already-connected SSE clients indefinitely — the loop keeps running but never writes to the cache again, so `version` is frozen. A *new* connection is unaffected (its `last_version` starts at `-1`, so it sends once immediately — with an empty payload, since `get_all()` is correctly empty).
- **Massive source:** poll interval is 15s (free tier) or more, so any watchlist removal is invisible to live SSE clients for up to a full poll cycle longer than necessary — worse than the simulator case since ticker-level updates are far less frequent.

**Fix applied:**

```python
def remove(self, ticker: str) -> None:
    with self._lock:
        if self._prices.pop(ticker, None) is not None:
            self._version += 1
```

(Guarding on whether something was actually removed avoids bumping the version — and thus triggering a wasted SSE payload — for a no-op removal of an unknown ticker.)

**Regression tests added** in `test_cache.py`: `test_remove_increments_version` (removing a known ticker bumps `version` by exactly 1) and `test_remove_nonexistent_does_not_bump_version` (removing an unknown ticker is a true no-op). The original last-ticker-removal repro from this review was re-run post-fix and now shows the version advancing immediately on removal (5→6) instead of freezing.

Full suite re-run after the fix: **75/75 tests pass** (73 original + 2 new), `ruff check` still clean.

---

## 4. Other Observations (carried forward, still true)

- **`stream.py` has no dedicated test**, still at 33% coverage. This is the primary consumer of `PriceCache` and the one place the version-counter bug above would actually be observed end-to-end. A basic `httpx.ASGITransport`-based test (start a source, hit `/api/stream/prices`, read one or two SSE frames, assert shape) would cover both the endpoint and catch regressions like the one above. Given the module is small and this is the least-tested piece of the subsystem, this is worth doing before the SSE endpoint gets wired into the rest of the app.
- **`PriceCache.version` reads without the lock.** Fine under CPython's GIL for a single `int` read; still slightly inconsistent with the rest of the class. Unchanged from the prior review's assessment — no action needed unless the project ever targets free-threaded Python.
- **Cholesky decomposition stress-tested beyond the existing unit tests**: ran `GBMSimulator` with all 10 default tickers, with a 50-ticker mixed set (defaults + 40 unrecognized tickers falling back to `DEFAULT_PARAMS`/`CROSS_GROUP_CORR`), and with a finance-only pair. All built and stepped without error. The design checklist item "Verify Cholesky decomposition works for all 10 default tickers" is satisfied in practice, though there's still no automated test asserting this — worth a quick `test_full_default_watchlist_builds_cholesky` in `test_simulator.py` since a future correlation-structure change could silently break positive-semi-definiteness for some ticker combination.
- **No `.env.example` at the project root yet.** `MASSIVE_API_KEY` is documented in `backend/README.md` and `backend/CLAUDE.md`, but the top-level `.env.example` the main `PLAN.md` calls for doesn't exist yet. This is almost certainly deferred to whichever agent wires up the FastAPI app/lifespan and other env vars (`OPENROUTER_API_KEY`, `LLM_MOCK`) rather than being in scope for the market-data module alone — flagging so it isn't dropped.
- **No CI workflow runs the backend test suite.** The three `.github/workflows/*.yml` files in the repo are all Claude Code Action integrations (issue/PR responses, code review bot); none run `pytest`. Out of scope for this module-level review, but worth putting on the list before merging further work.

---

## 5. Design/Architecture Assessment

Unchanged from the prior review — still accurate on re-reading the current code:

- Clean strategy pattern: `MarketDataSource` ABC with `SimulatorDataSource` / `MassiveDataSource`, both writing into a single shared `PriceCache`. Downstream code (SSE, and eventually portfolio/trade code) only ever touches the cache.
- `PriceUpdate` as a frozen, slotted dataclass is the right call — cheap to construct at simulator tick rate, safe to hand out without copying.
- GBM math is correct (`S(t+dt) = S(t) * exp((mu - 0.5σ²)dt + σ√dt·Z)`), and per-ticker `sigma`/`mu` tuning (TSLA 0.50 vs. V 0.17, NVDA's stronger drift) is a nice touch for a demo.
- Cholesky-correlated draws for sector grouping are mathematically sound and confirmed stable across ticker-count/composition stress tests (§4).
- Both background loops (`_run_loop`, `_poll_loop`/`_poll_once`) catch and log exceptions per-iteration rather than dying — correct for a long-running background task.
- The factory's env-var switch (`MASSIVE_API_KEY` set → Massive, else simulator) is simple and well tested (7/7 factory tests, including whitespace-only key handling).
- SSE endpoint format, `retry:` directive, and `X-Accel-Buffering: no` header are all sensible defaults for a proxied deployment.

---

## 6. Verdict

The market data backend remains solid, well-tested, and ready to integrate with the rest of the app. All build/lint/test failures from the prior review are gone, and the fixes it recommended are genuinely in place.

**Fixed in this pass:**
1. ~~`PriceCache.remove()` doesn't bump `_version` (§3)~~ — fixed, with regression tests. This was the one real correctness bug found; it directly affected the watchlist-removal → SSE-stream interaction the rest of the app will depend on.

**Should fix soon, not blocking:**
2. Add at least one SSE integration test for `stream.py` (still the least-covered module, and the one place the bug in §3 was externally visible).
3. Add a test asserting the full 10-ticker default watchlist (and/or a larger mixed set) builds a valid Cholesky matrix, to guard the correlation structure against future changes.

**Nice to have:**
4. Add `.env.example` at the project root once the rest of the env-var surface (`OPENROUTER_API_KEY`, `LLM_MOCK`) is known.
5. Add a CI workflow that runs `uv run --extra dev pytest` and `ruff check` on PRs touching `backend/`.
