"""Typed service errors mapping to CONTRACTS.md §15's error envelope.

The service layer never raises `HTTPException` — that is the API layer's job.
Each error carries a machine-readable `code`, a human `detail`, and the HTTP
status the API layer should use:

    try:
        result = execute_trade(...)
    except ServiceError as exc:
        raise HTTPException(status_code=exc.http_status, detail=exc.to_dict())
"""

from __future__ import annotations

from typing import Any


class ServiceError(Exception):
    """Base class for every expected service-layer failure."""

    code: str = "internal_error"
    http_status: int = 500

    def __init__(self, detail: str, **extra: Any) -> None:
        super().__init__(detail)
        self.detail = detail
        self.extra = extra

    def to_dict(self) -> dict[str, Any]:
        """Error envelope per CONTRACTS.md §15."""
        return {"error": self.code, "detail": self.detail, **self.extra}


class InvalidTicker(ServiceError):
    """Symbol failed the `^[A-Z][A-Z.]{0,4}$` check (CONTRACTS.md §4)."""

    code = "invalid_ticker"
    http_status = 400


class InvalidQuantity(ServiceError):
    """Quantity was non-finite, <= 0, below 0.0001, or above 1,000,000 (§1)."""

    code = "invalid_quantity"
    http_status = 400


class InsufficientCash(ServiceError):
    """Buy would drive cash negative."""

    code = "insufficient_cash"
    http_status = 409


class InsufficientShares(ServiceError):
    """Sell exceeds the held quantity."""

    code = "insufficient_shares"
    http_status = 409


class PriceUnavailable(ServiceError):
    """No quote, or the cached quote is older than QUOTE_MAX_AGE_SECONDS (§5)."""

    code = "price_unavailable"
    http_status = 409

    def __init__(self, detail: str, ticker: str) -> None:
        super().__init__(detail, ticker=ticker)
        self.ticker = ticker


class RequestIdReuse(ServiceError):
    """Same request_id replayed with a different payload (§7)."""

    code = "request_id_reuse"
    http_status = 409


class RequestInProgress(ServiceError):
    """A request with this request_id is still running (§7)."""

    code = "request_in_progress"
    http_status = 409


class NotFound(ServiceError):
    """Requested row does not exist."""

    code = "not_found"
    http_status = 404


__all__ = [
    "InsufficientCash",
    "InsufficientShares",
    "InvalidQuantity",
    "InvalidTicker",
    "NotFound",
    "PriceUnavailable",
    "RequestIdReuse",
    "RequestInProgress",
    "ServiceError",
]
</content>
</invoke>
