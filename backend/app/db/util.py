"""Small helpers shared by the persistence layer."""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone


def utc_now() -> datetime:
    """Timezone-aware current UTC time."""
    return datetime.now(timezone.utc)


def utc_now_iso() -> str:
    """ISO-8601 UTC timestamp, e.g. '2026-09-12T14:03:11.123456+00:00'."""
    return utc_now().isoformat()


def iso_days_ago(days: int) -> str:
    """ISO-8601 UTC timestamp `days` in the past (for retention cutoffs)."""
    return (utc_now() - timedelta(days=days)).isoformat()


def new_id() -> str:
    """Fresh UUID4 primary key."""
    return str(uuid.uuid4())
</content>
</invoke>
