from __future__ import annotations

from datetime import UTC, datetime, timedelta

from ..models import User


def utc_now() -> datetime:
    return datetime.now(UTC)


def as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


def is_locked(user: User, now: datetime) -> bool:
    return user.locked_until is not None and as_utc(user.locked_until) > as_utc(now)


def record_login_failure(
    user: User,
    *,
    now: datetime,
    max_failures: int,
    lockout_minutes: int,
) -> bool:
    user.failed_login_count += 1
    if user.failed_login_count < max_failures:
        return False
    user.locked_until = as_utc(now) + timedelta(minutes=lockout_minutes)
    return True


def clear_login_failures(user: User) -> None:
    user.failed_login_count = 0
    user.locked_until = None
