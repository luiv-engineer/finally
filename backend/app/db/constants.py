"""Constants for the persistence layer (CONTRACTS.md §1, §9, §10)."""

from __future__ import annotations

# Single-user model: every row carries this user_id (PLAN.md §7).
DEFAULT_USER_ID = "default"

# Starting cash for a freshly seeded profile, and the baseline for total_return.
STARTING_CASH = 10000.0

# Bumped whenever schema.sql changes in a way that needs a migration.
SCHEMA_VERSION = 1

# Seeded only when the user row itself is created (CONTRACTS.md §8 step 4).
DEFAULT_WATCHLIST: tuple[str, ...] = (
    "AAPL",
    "GOOGL",
    "MSFT",
    "AMZN",
    "TSLA",
    "NVDA",
    "META",
    "JPM",
    "V",
    "NFLX",
)

# CONTRACTS.md §9 — runtime SQLite file lives in data/ at the project root.
DEFAULT_DATABASE_PATH = "./data/finally.db"

# CONTRACTS.md §1 — numeric policy.
MIN_QUANTITY = 0.0001
MAX_QUANTITY = 1_000_000.0

# CONTRACTS.md §10 — snapshot retention and history downsampling.
SNAPSHOT_RETENTION_DAYS = 7
MAX_HISTORY_POINTS = 500

# CONTRACTS.md §13 — chat history bounds.
MAX_CHAT_HISTORY_MESSAGES = 20
MAX_CHAT_HISTORY_CHARS = 8000
</content>
</invoke>
