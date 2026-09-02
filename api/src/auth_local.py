"""Local username/password auth helpers.

Used by the public open-core build (and available in "both" mode) so Sanctum
can run without an external OIDC provider. Sessions themselves are unchanged —
a local login mints the same `Session` row + `session_id` cookie the Authentik
callback does, and `get_current_user` doesn't care which path created it.
"""
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, InvalidHashError

_ph = PasswordHasher()

# Synthetic authentik_uid prefix for local accounts (the column is NOT NULL and
# uniquely indexed; "local:<username>" keeps both constraints satisfied without
# a schema change).
LOCAL_UID_PREFIX = "local:"


def local_uid(username: str) -> str:
    return f"{LOCAL_UID_PREFIX}{username.lower()}"


def hash_password(password: str) -> str:
    return _ph.hash(password)


def verify_password(hash_: str, password: str) -> bool:
    try:
        _ph.verify(hash_, password)
        return True
    except (VerifyMismatchError, InvalidHashError, TypeError):
        return False
