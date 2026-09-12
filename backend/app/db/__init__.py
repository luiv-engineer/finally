"""Persistence layer: schema, connections, seeding.

    from app.db import Database, init_database, get_database, DEFAULT_USER_ID
"""

from __future__ import annotations

from .connection import Database, get_database, set_database
from .constants import (
    DEFAULT_DATABASE_PATH,
    DEFAULT_USER_ID,
    DEFAULT_WATCHLIST,
    MAX_CHAT_HISTORY_CHARS,
    MAX_CHAT_HISTORY_MESSAGES,
    MAX_HISTORY_POINTS,
    MAX_QUANTITY,
    MIN_QUANTITY,
    SCHEMA_VERSION,
    SNAPSHOT_RETENTION_DAYS,
    STARTING_CASH,
)
from .init import get_schema_version, init_database, resolve_database_path
from .util import new_id, utc_now, utc_now_iso

__all__ = [
    "DEFAULT_DATABASE_PATH",
    "DEFAULT_USER_ID",
    "DEFAULT_WATCHLIST",
    "MAX_CHAT_HISTORY_CHARS",
    "MAX_CHAT_HISTORY_MESSAGES",
    "MAX_HISTORY_POINTS",
    "MAX_QUANTITY",
    "MIN_QUANTITY",
    "SCHEMA_VERSION",
    "SNAPSHOT_RETENTION_DAYS",
    "STARTING_CASH",
    "Database",
    "get_database",
    "get_schema_version",
    "init_database",
    "new_id",
    "resolve_database_path",
    "set_database",
    "utc_now",
    "utc_now_iso",
]
</content>
</invoke>
