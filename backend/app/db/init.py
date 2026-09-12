"""Database initialization and first-run seeding (CONTRACTS.md §8 steps 1-4)."""

from __future__ import annotations

import logging
import os
import sqlite3
from pathlib import Path

from .connection import Database, set_database
from .constants import (
    DEFAULT_DATABASE_PATH,
    DEFAULT_USER_ID,
    DEFAULT_WATCHLIST,
    SCHEMA_VERSION,
    STARTING_CASH,
)
from .util import new_id, utc_now_iso

logger = logging.getLogger(__name__)

SCHEMA_PATH = Path(__file__).with_name("schema.sql")


def resolve_database_path(path: str | os.PathLike[str] | None = None) -> Path:
    """Resolve the SQLite path and create its parent directory.

    Precedence: explicit argument > ``DATABASE_PATH`` env var > ``./data/finally.db``.
    """
    raw = str(path) if path is not None else (os.environ.get("DATABASE_PATH") or "").strip()
    resolved = Path(raw or DEFAULT_DATABASE_PATH).expanduser()
    resolved.parent.mkdir(parents=True, exist_ok=True)
    return resolved


def init_database(
    path: str | os.PathLike[str] | None = None,
    *,
    register: bool = True,
) -> Database:
    """Open the database, create the schema if absent, and seed a new user once.

    Idempotent: re-running against an existing file creates nothing and reseeds
    nothing. An intentionally empty watchlist survives restart, because the
    watchlist is only seeded in the same branch that creates the user row.
    """
    db = Database(resolve_database_path(path))
    db.executescript(SCHEMA_PATH.read_text())

    with db.write() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO schema_version (version, applied_at) VALUES (?, ?)",
            (SCHEMA_VERSION, utc_now_iso()),
        )
        existing = conn.execute(
            "SELECT id FROM users_profile WHERE id = ?", (DEFAULT_USER_ID,)
        ).fetchone()
        if existing is None:
            _seed_new_user(conn, DEFAULT_USER_ID)
            logger.info("Seeded new user '%s' at %s", DEFAULT_USER_ID, db.path)

    if register:
        set_database(db)
    return db


def _seed_new_user(conn: sqlite3.Connection, user_id: str) -> None:
    """Insert the profile, the default watchlist, and one baseline snapshot."""
    now = utc_now_iso()
    conn.execute(
        "INSERT INTO users_profile (id, cash_balance, created_at) VALUES (?, ?, ?)",
        (user_id, STARTING_CASH, now),
    )
    conn.executemany(
        "INSERT INTO watchlist (id, user_id, ticker, added_at) VALUES (?, ?, ?, ?)",
        [(new_id(), user_id, ticker, now) for ticker in DEFAULT_WATCHLIST],
    )
    # One baseline point so the P&L chart is never empty (CONTRACTS.md §10).
    conn.execute(
        "INSERT INTO portfolio_snapshots (id, user_id, total_value, recorded_at) "
        "VALUES (?, ?, ?, ?)",
        (new_id(), user_id, STARTING_CASH, now),
    )


def get_schema_version(db: Database) -> int:
    """Highest applied schema version, or 0 if the table is empty."""
    with db.read() as conn:
        row = conn.execute("SELECT MAX(version) AS v FROM schema_version").fetchone()
    return int(row["v"]) if row and row["v"] is not None else 0
</content>
</invoke>
