-- FinAlly schema (CONTRACTS.md §10). Every statement is IF NOT EXISTS so the
-- whole script is safe to re-run on every startup.

CREATE TABLE IF NOT EXISTS schema_version (
    version    INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS users_profile (
    id           TEXT PRIMARY KEY DEFAULT 'default',
    cash_balance REAL NOT NULL DEFAULT 10000.0 CHECK (cash_balance >= 0),
    created_at   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS watchlist (
    id       TEXT PRIMARY KEY,
    user_id  TEXT NOT NULL DEFAULT 'default'
             REFERENCES users_profile (id) ON DELETE CASCADE,
    ticker   TEXT NOT NULL,
    added_at TEXT NOT NULL,
    UNIQUE (user_id, ticker)
);

-- One row per held ticker. Rows are DELETED at zero quantity (CONTRACTS.md §1).
CREATE TABLE IF NOT EXISTS positions (
    id         TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL DEFAULT 'default'
               REFERENCES users_profile (id) ON DELETE CASCADE,
    ticker     TEXT NOT NULL,
    quantity   REAL NOT NULL CHECK (quantity > 0),
    avg_cost   REAL NOT NULL CHECK (avg_cost >= 0),
    updated_at TEXT NOT NULL,
    UNIQUE (user_id, ticker)
);

-- Append-only ledger. realized_pnl is populated on sells, NULL on buys (§11).
CREATE TABLE IF NOT EXISTS trades (
    id           TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL DEFAULT 'default'
                 REFERENCES users_profile (id) ON DELETE CASCADE,
    ticker       TEXT NOT NULL,
    side         TEXT NOT NULL CHECK (side IN ('buy', 'sell')),
    quantity     REAL NOT NULL CHECK (quantity > 0),
    price        REAL NOT NULL CHECK (price > 0),
    realized_pnl REAL,
    executed_at  TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_trades_user_time
    ON trades (user_id, executed_at);

CREATE TABLE IF NOT EXISTS portfolio_snapshots (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL DEFAULT 'default'
                REFERENCES users_profile (id) ON DELETE CASCADE,
    total_value REAL NOT NULL,
    recorded_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_snapshots_user_time
    ON portfolio_snapshots (user_id, recorded_at);

CREATE TABLE IF NOT EXISTS chat_messages (
    id         TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL DEFAULT 'default'
               REFERENCES users_profile (id) ON DELETE CASCADE,
    role       TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
    content    TEXT NOT NULL,
    actions    TEXT,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_chat_user_time
    ON chat_messages (user_id, created_at);

-- Retry safety (CONTRACTS.md §7). response_json IS NULL means "in progress".
CREATE TABLE IF NOT EXISTS idempotency_keys (
    request_id    TEXT PRIMARY KEY,
    user_id       TEXT NOT NULL DEFAULT 'default',
    endpoint      TEXT NOT NULL,
    payload_hash  TEXT NOT NULL,
    response_json TEXT,
    created_at    TEXT NOT NULL
);
</content>
</invoke>
