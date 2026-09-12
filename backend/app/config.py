"""Typed application settings loaded from the environment.

Per CONTRACTS.md §17. The backend runs from `backend/` in local development and from
`/app` inside the container, so the project root is resolved from this file's location
rather than from the current working directory.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from dotenv import load_dotenv

logger = logging.getLogger(__name__)

# backend/app/config.py -> backend/app -> backend -> <project root>
PROJECT_ROOT = Path(__file__).resolve().parents[2]

# Defaults for QUOTE_MAX_AGE_SECONDS when the env var is unset (CONTRACTS.md §5)
DEFAULT_QUOTE_MAX_AGE_SIMULATOR = 10
DEFAULT_QUOTE_MAX_AGE_MASSIVE = 90

_TRUE_VALUES = {"1", "true", "yes", "on"}


def _load_dotenv_once() -> None:
    """Load the project-root `.env`, falling back to a cwd-relative one.

    `override=False` so real environment variables (Docker `--env-file`, CI, the test
    harness) always win over the file on disk.
    """
    root_env = PROJECT_ROOT / ".env"
    if root_env.is_file():
        load_dotenv(root_env, override=False)
    else:
        # Local runs from an unexpected cwd, or a container without the root mounted.
        load_dotenv(override=False)


def _env_str(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _env_bool(name: str, default: bool = False) -> bool:
    raw = _env_str(name)
    if not raw:
        return default
    return raw.lower() in _TRUE_VALUES


def _env_int(name: str) -> int | None:
    raw = _env_str(name)
    if not raw:
        return None
    try:
        return int(raw)
    except ValueError:
        logger.warning("Ignoring non-integer %s=%r", name, raw)
        return None


@dataclass(frozen=True, slots=True)
class Settings:
    """Immutable snapshot of the process configuration."""

    openrouter_api_key: str
    massive_api_key: str
    llm_mock: bool
    database_path: Path
    quote_max_age_seconds: int
    sim_fixed_prices: bool
    log_level: str

    @property
    def market_source(self) -> str:
        """`"massive"` when a Massive key is configured, otherwise `"simulator"`."""
        return "massive" if self.massive_api_key else "simulator"

    @property
    def llm_available(self) -> bool:
        """Chat works when mocked, or when a real provider key is present (§13)."""
        return self.llm_mock or bool(self.openrouter_api_key)


def load_settings() -> Settings:
    """Build a `Settings` from the current environment (loading `.env` first)."""
    _load_dotenv_once()

    massive_api_key = _env_str("MASSIVE_API_KEY")
    explicit_max_age = _env_int("QUOTE_MAX_AGE_SECONDS")
    if explicit_max_age is not None and explicit_max_age > 0:
        quote_max_age = explicit_max_age
    elif massive_api_key:
        quote_max_age = DEFAULT_QUOTE_MAX_AGE_MASSIVE
    else:
        quote_max_age = DEFAULT_QUOTE_MAX_AGE_SIMULATOR

    raw_path = _env_str("DATABASE_PATH") or "./data/finally.db"
    database_path = Path(raw_path)
    if not database_path.is_absolute():
        database_path = (PROJECT_ROOT / database_path).resolve()

    return Settings(
        openrouter_api_key=_env_str("OPENROUTER_API_KEY"),
        massive_api_key=massive_api_key,
        llm_mock=_env_bool("LLM_MOCK", False),
        database_path=database_path,
        quote_max_age_seconds=quote_max_age,
        sim_fixed_prices=_env_bool("SIM_FIXED_PRICES", False),
        log_level=_env_str("LOG_LEVEL", "INFO").upper() or "INFO",
    )


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Process-wide cached settings. Call `get_settings.cache_clear()` in tests."""
    return load_settings()
