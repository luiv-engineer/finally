# Plan review

Reviewed 2026-09-08 against `planning/PLAN.md`, including its existing §13 review notes, and the implemented market subsystem in `backend/app/market/`.

The single-container architecture and simulated trading scope are coherent. The main remaining risk is inconsistent state across trades, market data, and chat. Resolve the contracts below before implementing those features. These are recommendations, not changes to the specification. Provider capabilities and deployment services were not externally verified in this review.

## High priority

### 1. Make trade validation and execution one atomic operation (§7–9)

The plan specifies sufficient-cash/share validation but not its transaction boundary. Two simultaneous buys can both pass validation against the same balance; a crash between updating cash and inserting the trade can leave an inconsistent ledger. One user can still issue concurrent requests from chat, the trade bar, or multiple tabs.

Specify a shared trade service that captures one eligible quote, opens a write transaction, reads and validates current holdings/cash, updates both, inserts the trade, and commits together. Define how the immediate portfolio snapshot participates. Never hold that transaction open during an LLM/provider request. WAL or separate connections alone do not establish these guarantees.

Acceptance checks: competing buys cannot overspend; competing sells cannot oversell; an injected failure rolls back all trade effects.

### 2. Define retry safety for both manual and chat trades (§8–9)

A trade may commit even when the client loses the HTTP response. Retrying `/api/portfolio/trade` or `/api/chat` can execute it again. A disabled submit button cannot handle this case.

Add a client-generated request ID with a database uniqueness constraint and persist the result. Reusing an ID with the same payload returns the original result; a different payload is rejected. For chat, persist action identifiers and outcomes so retrying a request does not regenerate or repeat completed actions. State the behavior for requests still in progress and interrupted batches.

Acceptance check: retry after a committed trade with a lost response produces exactly one ledger entry and one balance change.

### 3. Define quote eligibility and incomplete valuation (§6–8; extends Q2/Q4)

Missing prices are only one case. `massive_client.py` logs polling failures and leaves old cache entries available indefinitely. A connected SSE client can therefore display or trade an old quote. Define maximum quote age, unavailable/delayed/closed-market behavior, and the timestamp used to assess freshness. Keep connection health separate from quote freshness.

Track the union of watchlist symbols and open positions, restoring that union at startup. If a held ticker lacks a usable quote, expose an incomplete or stale valuation; do not value it at zero or silently omit it from portfolio totals and snapshots. Apply identical quote rules to manual and chat trades.

Acceptance checks: removing a held ticker preserves pricing; provider failure disables ineligible fills; restarting with holdings never records an artificially reduced portfolio value while the cache warms.

### 4. Specify startup order and process count (§3–7, §11)

The plan alternates between initialization at startup and on first request. Background pricing and snapshots need persisted state before requests arrive. The source interface also says `start()` must run exactly once, while cache and tasks are process-local.

Use an explicit lifecycle: initialize/version the schema, seed only new state, load watched and held tickers, start one market source, then start snapshot recording when valuation is available. Stop tasks on shutdown. Specify one Uvicorn worker for this architecture; extra workers would create independent caches and duplicate background tasks. Define readiness separately from basic process health.

Acceptance checks: restarts preserve balances and an intentionally empty watchlist; initialization does not reseed existing users; exactly one source and snapshot task run.

### 5. Make chat results describe actual execution (§9; extends Q5/C7)

The assistant writes its message before execution, so it can claim success for a rejected trade. Specify that the initial message describes intent, while backend-generated action results are authoritative. Persist those results for future conversation context.

Choose sequential, best-effort execution with an outcome for every action, or explicitly choose a different policy. The separate `trades` and `watchlist_changes` arrays also need cross-array ordering: adding a symbol and buying it in one response depends on subscription and price availability. Consider one ordered action array if interleaving is required.

Validate the complete structured response before beginning effects, bound the number of actions, and execute trades only on user instructions or agreement as already stated in the system-prompt guidance. Analysis-only requests should produce no trades. A schema-valid model response does not establish execution success.

## Contract decisions to settle next

- **Numeric representation (§7; C6):** Define finite positive quantities, precision, minimum order size, maximum values, rounding, and full-sell behavior. SQLite `REAL` plus display rounding is not a monetary arithmetic policy. Choose fixed-point units or a documented decimal storage/calculation strategy, and test repeated fractional buys/sells for residual shares or negative cash.
- **API examples (§8):** Publish request/response and error examples, including timestamps, unavailable prices, action outcomes, and the SSE snapshot shape. Define refresh behavior after chat changes and changes from another tab; prices alone cannot notify a tab that its cash or holdings changed.
- **Chat history (§7–10):** History is persisted but no read endpoint is specified. Add a bounded history endpoint or explicitly make previous messages unavailable in the UI after reload. Bound the model context by size as well as message count.
- **No-key experience (§2, §5):** State whether missing `OPENROUTER_API_KEY` disables chat while trading still works, or requires mock mode. Provide an actionable UI state and a committed `.env.example`. The referenced `cerebras-inference` skill is not in this session's available skills; make that dependency available or document the necessary integration contract directly.
- **Persistence (§4, §11):** Choose named volume versus bind mount and specify an absolute/configurable database path. Retain schema versioning even if migrations run automatically. Define whether simulator prices reset on restart; persisted positions combined with reset quotes can cause discontinuities in portfolio history.
- **Bounded history (§6–8, §10):** Cap frontend sparkline points and define snapshot retention or history pagination/downsampling. Both currently grow with runtime. Empty and one-point chart states should be explicit acceptance cases.

## Corrections to the existing §13 review

1. **Q1 mixes two baselines.** Its recommendation names `open_price` but also references previous close. These produce different percentages. Choose one baseline and label it explicitly; if using previous close, encode that name and formula in the contract. Tick-to-tick movement remains separate for price flashes.
2. **Q2's final instruction conflicts with its recommended union.** Deleting a watchlist entry must not unconditionally call `source.remove_ticker()` when a position still needs the quote. Reconcile subscriptions after the database change.
3. **Q3 already has an implementation answer.** `GBMSimulator._add_ticker_internal()` assigns unknown symbols a random price between 50 and 300 and `DEFAULT_PARAMS`. The decision is whether to retain or restrict this behavior, not whether a fallback exists.
4. **Q4 overstates the timing guarantee.** Newly added Massive symbols wait until a subsequent successful poll. Failures can extend that wait indefinitely; it is not guaranteed to finish within 15 seconds.
5. **C2's ring buffer does not populate a cold start.** It helps page reloads after the server has accumulated samples. It cannot supply history immediately after server startup without persistence, a historical source, or explicitly labeled generated history. Empty-on-load sparklines are already an intentional requirement.
6. **C5 overstates lost gains.** Realized gains remain in cash and therefore in the specified total-value chart. The missing contract is how return and realized/unrealized P&L are labeled, not whether total value retains gains.
7. **C11 misstates the current SSE path.** `stream.py` reads the in-memory cache, not SQLite. Database concurrency still matters for trades, chat, and snapshots.
8. **S1 does not inherently resolve stale state.** A bootstrap response still races with SSE unless timestamps or revisions establish ordering. Existing endpoints are adequate if their shared price/state contract is clear; another endpoint is optional.
9. **C1 should cover removals and empty snapshots.** `PriceCache.remove()` does not increment its version, and the stream suppresses empty dictionaries. Define how clients learn that the last ticker disappeared and how a reconnect replaces stale local state.

## Delivery and verification

Treat the existing §13 alternatives as proposals until accepted decisions are incorporated into the relevant specification sections. Otherwise implementers can reasonably follow conflicting instructions.

Build in dependency order: lifecycle/database and contracts; portfolio transactions; REST/SSE integration; frontend; chat using the same services; packaged E2E verification. Keep optional history backfill, cloud deployment, and endpoint consolidation outside the first complete vertical slice.

Extend §12 with concurrent requests, duplicate requests, rollback, held-symbol removal, stale/missing quotes, failed chat actions, and restart persistence. Use fixed prices and controllable time for exact accounting assertions: `LLM_MOCK=true` alone does not make the random market simulator deterministic. Run E2E tests against a dedicated disposable database volume.

This was a documentation and source review. No application code was changed and no runtime tests were run.
