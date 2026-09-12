"""Data models for market data."""

from __future__ import annotations

import time
from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class PriceUpdate:
    """Immutable snapshot of a single ticker's price at a point in time.

    Two independent baselines are carried (CONTRACTS.md §2):

    - ``previous_price`` — the prior tick. Drives ``direction``, which the frontend uses
      *only* for the green/red flash animation.
    - ``open_price`` — the session baseline (simulator seed price, or the Massive
      snapshot's session open). Drives the watchlist "change %" column.

    ``open_price`` defaults to ``price`` when not supplied, so the first observation of a
    ticker always has a zero change-from-open.
    """

    ticker: str
    price: float
    previous_price: float
    open_price: float | None = None
    timestamp: float = field(default_factory=time.time)  # Unix seconds

    def __post_init__(self) -> None:
        if self.open_price is None:
            object.__setattr__(self, "open_price", self.price)

    # --- Tick-to-tick (flash animation only) ---

    @property
    def change(self) -> float:
        """Absolute price change from previous update."""
        return round(self.price - self.previous_price, 4)

    @property
    def change_percent(self) -> float:
        """Percentage change from previous update."""
        if self.previous_price == 0:
            return 0.0
        return round((self.price - self.previous_price) / self.previous_price * 100, 4)

    @property
    def direction(self) -> str:
        """'up', 'down', or 'flat'."""
        if self.price > self.previous_price:
            return "up"
        elif self.price < self.previous_price:
            return "down"
        return "flat"

    # --- Session baseline (displayed "change %") ---

    @property
    def change_from_open(self) -> float:
        """Absolute price change from the session open."""
        return round(self.price - (self.open_price or 0.0), 4)

    @property
    def change_percent_from_open(self) -> float:
        """Percentage change from the session open."""
        if not self.open_price:
            return 0.0
        return round((self.price - self.open_price) / self.open_price * 100, 4)

    # --- Freshness ---

    def age(self, now: float | None = None) -> float:
        """Seconds since this quote was observed."""
        return (time.time() if now is None else now) - self.timestamp

    def is_stale(self, max_age: float, now: float | None = None) -> bool:
        """True when the quote is older than `max_age` seconds (CONTRACTS.md §5)."""
        return self.age(now) > max_age

    def to_dict(self, *, stale: bool = False) -> dict:
        """Serialize for the SSE wire payload (CONTRACTS.md §12).

        Tick-derived ``change`` / ``change_percent`` are deliberately omitted — the
        client derives its flash from ``direction`` and displays
        ``change_percent_from_open``.
        """
        return {
            "ticker": self.ticker,
            "price": self.price,
            "previous_price": self.previous_price,
            "open_price": self.open_price,
            "timestamp": self.timestamp,
            "direction": self.direction,
            "change_percent_from_open": self.change_percent_from_open,
            "stale": stale,
        }
