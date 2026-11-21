import asyncio
from collections import OrderedDict
from collections.abc import Awaitable, Callable
from contextlib import closing
from dataclasses import dataclass
from datetime import UTC, datetime, time, timedelta
from math import ceil
from pathlib import Path
import sqlite3
from time import monotonic
from typing import Generic, TypeVar


class GatewayProblem(Exception):
    def __init__(self, status: int, code: str, retry_after: int | None = None):
        super().__init__(code)
        self.status = status
        self.code = code
        self.retry_after = retry_after


class AttemptBudget:
    def __init__(self, path: Path, daily_limit: int):
        self.path = path
        self.daily_limit = daily_limit
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with closing(self._connect()) as db, db:
                db.execute("CREATE TABLE IF NOT EXISTS daily_attempts (day TEXT PRIMARY KEY, attempts INTEGER NOT NULL)")
        except (OSError, sqlite3.Error):
            raise RuntimeError("Could not initialize the Reedle attempt budget") from None

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self.path, timeout=1)

    def consume(self) -> None:
        now = datetime.now(UTC)
        day = now.date().isoformat()
        if self.daily_limit > 0:
            try:
                with closing(self._connect()) as db, db:
                    cursor = db.execute(
                        """
                        INSERT INTO daily_attempts (day, attempts) VALUES (?, 1)
                        ON CONFLICT(day) DO UPDATE SET attempts = attempts + 1
                        WHERE attempts < ?
                        """,
                        (day, self.daily_limit),
                    )
                    db.execute("DELETE FROM daily_attempts WHERE day < ?", (day,))
                    if cursor.rowcount == 1:
                        return
            except sqlite3.Error:
                raise GatewayProblem(503, "daily_attempt_budget_unavailable") from None
        midnight = datetime.combine(now.date() + timedelta(days=1), time.min, tzinfo=UTC)
        raise GatewayProblem(429, "daily_attempt_budget_exhausted", ceil((midnight - now).total_seconds()))


T = TypeVar("T")


@dataclass
class PendingReply(Generic[T]):
    fingerprint: bytes
    task: asyncio.Task[T]
    waiters: int = 0


class ReplyCache(Generic[T]):
    def __init__(self, ttl: float = 300, capacity: int = 128, max_pending: int = 16):
        self.ttl = ttl
        self.capacity = capacity
        self.max_pending = max_pending
        self.cached: OrderedDict[str, tuple[float, bytes, T]] = OrderedDict()
        self.pending: dict[str, PendingReply[T]] = {}
        self.expiry: asyncio.TimerHandle | None = None

    async def resolve(self, key: str, fingerprint: bytes, operation: Callable[[], Awaitable[T]]) -> T:
        # All cache bookkeeping runs on the app's event loop before yielding.
        self._drop_expired()

        cached = self.cached.get(key)
        if cached is not None:
            _, original, reply = cached
            self._check_fingerprint(original, fingerprint)
            return reply

        pending = self.pending.get(key)
        if pending is not None:
            self._check_fingerprint(pending.fingerprint, fingerprint)
        else:
            if len(self.pending) >= self.max_pending:
                raise GatewayProblem(503, "tutor_busy", 1)
            task = asyncio.create_task(self._resolve_new(key, fingerprint, operation))
            task.add_done_callback(self._report_unobserved_result)
            pending = PendingReply(fingerprint, task)
            self.pending[key] = pending
        pending.waiters += 1
        try:
            return await asyncio.shield(pending.task)
        finally:
            pending.waiters -= 1
            if pending.waiters == 0 and not pending.task.done() and self.pending.get(key) is pending:
                del self.pending[key]
                pending.task.cancel()
                await asyncio.gather(pending.task, return_exceptions=True)

    @staticmethod
    def _check_fingerprint(original: bytes, fingerprint: bytes) -> None:
        if fingerprint != original:
            raise GatewayProblem(409, "request_id_conflict")

    async def _resolve_new(self, key: str, fingerprint: bytes, operation: Callable[[], Awaitable[T]]) -> T:
        owner = self.pending.get(key)
        try:
            reply = await operation()
            if self.ttl > 0 and self.pending.get(key) is owner:
                self.cached[key] = monotonic() + self.ttl, fingerprint, reply
                if len(self.cached) > self.capacity:
                    self.cached.popitem(last=False)
                self._schedule_expiry()
            return reply
        finally:
            if owner is not None and self.pending.get(key) is owner:
                del self.pending[key]

    @staticmethod
    def _report_unobserved_result(task: asyncio.Task[T]) -> None:
        # A disconnected caller may leave no waiter for this shared task.
        if not task.cancelled():
            task.exception()

    def _drop_expired(self) -> None:
        now = monotonic()
        while self.cached and next(iter(self.cached.values()))[0] <= now:
            self.cached.popitem(last=False)

    def _schedule_expiry(self) -> None:
        if self.expiry is None and self.cached:
            seconds = max(0.0, next(iter(self.cached.values()))[0] - monotonic())
            self.expiry = asyncio.get_running_loop().call_later(seconds, self._expire)

    def _expire(self) -> None:
        self.expiry = None
        self._drop_expired()
        self._schedule_expiry()

    async def close(self) -> None:
        tasks = [entry.task for entry in self.pending.values()]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        if self.expiry is not None:
            self.expiry.cancel()
            self.expiry = None
        self.cached.clear()


class CircuitBreaker:
    def __init__(self, threshold: int = 3, cooldown: float = 30):
        self.threshold = threshold
        self.cooldown = cooldown
        self.failures = 0
        self.open_until = 0.0
        self.probe_active = False
        self.generation = 0

    def enter(self) -> int:
        if self.open_until > monotonic() or self.probe_active:
            raise GatewayProblem(503, "tutor_provider_unavailable", self.retry_after() or 1)
        if self.open_until:
            self.probe_active = True
        return self.generation

    def succeed(self, generation: int) -> None:
        if generation == self.generation:
            self.failures = 0
            self.open_until = 0
            self.probe_active = False

    def fail(self, generation: int, retry_after: float | None) -> None:
        if generation != self.generation:
            return
        self.failures += 1
        delay = retry_after or 0
        if self.probe_active or self.failures >= self.threshold:
            delay = max(delay, self.cooldown)
        if delay > 0:
            self.open_until = monotonic() + delay
            self.probe_active = False
            self.generation += 1

    def abandon(self, generation: int) -> None:
        if generation == self.generation:
            self.probe_active = False

    def retry_after(self) -> int | None:
        return max(0, ceil(self.open_until - monotonic())) or None
