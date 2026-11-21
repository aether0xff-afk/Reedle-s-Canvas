from dataclasses import dataclass, field
import math
import os
from pathlib import Path

import httpx


DEFAULT_BAZE_URL = "https://factchat-cloud.mindlogic.ai/v1/gateway"


@dataclass(frozen=True)
class Settings:
    client_token: str = field(repr=False)
    provider_key: str = field(repr=False)
    provider_model: str
    completions_url: httpx.URL
    budget_db: Path
    daily_attempt_limit: int
    attempt_timeout: float
    max_attempts: int
    max_output_tokens: int
    reply_cache_seconds: int

    @classmethod
    def from_env(cls) -> "Settings":
        client_token = _token("REEDLE_CLIENT_TOKEN", 512)
        provider_key = _token("BAZE_API_KEY", 4096)
        if client_token == provider_key:
            raise RuntimeError("REEDLE_CLIENT_TOKEN and BAZE_API_KEY must be distinct")

        model = os.environ.get("BAZE_MODEL", "")
        if not model or not model.isprintable() or not model.strip() or len(model.encode("utf-8")) > 128:
            raise RuntimeError("BAZE_MODEL must be a visible model ID of at most 128 UTF-8 bytes")

        return cls(
            client_token=client_token,
            provider_key=provider_key,
            provider_model=model,
            completions_url=_completions_url(),
            budget_db=Path(os.environ.get("REEDLE_BUDGET_DB", ".reedle-attempts.sqlite3")).resolve(),
            daily_attempt_limit=_integer("REEDLE_DAILY_ATTEMPT_LIMIT", 100, 0, 100_000),
            attempt_timeout=_timeout(),
            max_attempts=_integer("REEDLE_PROVIDER_MAX_ATTEMPTS", 2, 1, 3),
            max_output_tokens=_integer("REEDLE_PROVIDER_MAX_OUTPUT_TOKENS", 1_200, 128, 8_192),
            reply_cache_seconds=_integer("REEDLE_REPLY_CACHE_SECONDS", 300, 0, 900),
        )


def _completions_url() -> httpx.URL:
    try:
        base = httpx.URL(os.environ.get("BAZE_BASE_URL", DEFAULT_BAZE_URL))
    except (ValueError, httpx.InvalidURL):
        raise RuntimeError("BAZE_BASE_URL must be an HTTPS URL or a local mock URL") from None
    loopback = base.host in {"localhost", "127.0.0.1", "::1"}
    valid_scheme = base.scheme == "https" or (base.scheme == "http" and loopback)
    if not valid_scheme or not base.host or base.userinfo or base.query or base.fragment:
        raise RuntimeError("BAZE_BASE_URL must be an HTTPS URL or a local mock URL")
    return base.copy_with(path=base.path.rstrip("/") + "/chat/completions/")


def _token(name: str, maximum: int) -> str:
    token = os.environ.get(name, "")
    if not 1 <= len(token) <= maximum or any(not "!" <= character <= "~" for character in token):
        raise RuntimeError(f"{name} must be a nonempty printable ASCII token")
    return token


def _integer(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
        if minimum <= value <= maximum:
            return value
    except ValueError:
        pass
    raise RuntimeError(f"{name} must be an integer between {minimum} and {maximum}")


def _timeout() -> float:
    try:
        value = float(os.environ.get("REEDLE_PROVIDER_TIMEOUT_SECONDS", "7"))
        if math.isfinite(value) and 0.1 <= value <= 20:
            return value
    except ValueError:
        pass
    raise RuntimeError("REEDLE_PROVIDER_TIMEOUT_SECONDS must be between 0.1 and 20")
