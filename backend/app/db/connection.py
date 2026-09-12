"""SQLite connection management.

Concurrency model (CONTRACTS.md §8 step 2)
------------------------------------------
* **One connection per thread**, created lazily and cached in a `threading.local`.
  FastAPI runs sync route handlers and `run_in_threadpool` work on worker threads,
  and the 30s snapshot task runs on its own thread/executor, so each of those gets
  an independent connection. No connection object is ever shared between threads.
* Connections are opened with ``isolation_level=None`` (autocommit). Write
  transactions are opened **explicitly** with ``BEGIN IMMEDIATE`` via
  :meth:`Database.write`, which takes SQLite's write lock up front. That is what
  makes "re-read balance inside the transaction" actually safe: two competing
  buys serialize on the write lock instead of both reading the same stale cash.
* ``PRAGMA journal_mode=WAL`` lets readers (SSE, valuation) proceed while a write
  transaction is open. ``PRAGMA busy_timeout=5000`` makes a blocked writer wait up
  to 5s instead of failing instantly with "database is locked".
* ``check_same_thread=False`` is set only so that shutdown can close connections
  owned by other threads; it is never used to share a live connection.
"""

from __future__ import annotations

import sqlite3
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

BUSY_TIMEOUT_MS = 5000


class Database:
    """A SQLite database with per-thread connections and explicit write locking."""

    def __init__(self, path: str | Path) -> None:
        self._path = Path(path)
        self._local = threading.local()
        self._connections: list[sqlite3.Connection] = []
        self._connections_lock = threading.Lock()

    @property
    def path(self) -> Path:
        """Filesystem location of the SQLite file."""
        return self._path

    def connect(self) -> sqlite3.Connection:
        """Return this thread's connection, opening and configuring it if needed."""
        conn: sqlite3.Connection | None = getattr(self._local, "conn", None)
        if conn is not None:
            return conn

        conn = sqlite3.connect(
            self._path,
            timeout=BUSY_TIMEOUT_MS / 1000,
            isolation_level=None,  # autocommit; transactions are explicit
            check_same_thread=False,
        )
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute(f"PRAGMA busy_timeout={BUSY_TIMEOUT_MS}")
        conn.execute("PRAGMA synchronous=NORMAL")

        self._local.conn = conn
        self._local.depth = 0
        with self._connections_lock:
            self._connections.append(conn)
        return conn

    @contextmanager
    def read(self) -> Iterator[sqlite3.Connection]:
        """Autocommit read access. No transaction is opened."""
        yield self.connect()

    @contextmanager
    def write(self) -> Iterator[sqlite3.Connection]:
        """Run a `BEGIN IMMEDIATE` transaction; commit on success, roll back on error.

        Re-entrant: a nested `write()` on the same thread joins the outer
        transaction rather than starting a second one, so the whole nest commits
        or rolls back together.
        """
        conn = self.connect()
        depth = getattr(self._local, "depth", 0)
        if depth:
            self._local.depth = depth + 1
            try:
                yield conn
            finally:
                self._local.depth = depth
            return

        conn.execute("BEGIN IMMEDIATE")
        self._local.depth = 1
        try:
            yield conn
        except BaseException:
            self._local.depth = 0
            self._rollback(conn)
            raise
        else:
            self._local.depth = 0
            conn.execute("COMMIT")

    @staticmethod
    def _rollback(conn: sqlite3.Connection) -> None:
        try:
            conn.execute("ROLLBACK")
        except sqlite3.Error:  # pragma: no cover - transaction already gone
            pass

    def executescript(self, script: str) -> None:
        """Run a multi-statement DDL script (implicitly commits; use outside write())."""
        self.connect().executescript(script)

    def close(self) -> None:
        """Close every connection handed out by this Database. Safe to call twice."""
        with self._connections_lock:
            connections, self._connections = self._connections, []
        for conn in connections:
            try:
                conn.close()
            except sqlite3.Error:  # pragma: no cover
                pass
        self._local = threading.local()


_database: Database | None = None
_database_lock = threading.Lock()


def set_database(db: Database | None) -> None:
    """Install (or clear) the process-wide Database instance."""
    global _database
    with _database_lock:
        _database = db


def get_database() -> Database:
    """Return the process-wide Database. Raises if `init_database()` has not run."""
    db = _database
    if db is None:
        raise RuntimeError("Database not initialized; call app.db.init_database() first")
    return db
</content>
</invoke>
