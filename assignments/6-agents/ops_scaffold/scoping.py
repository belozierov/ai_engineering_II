"""Domain-separated opaque scope derivation from trusted runtime identifiers."""

from __future__ import annotations

import hashlib
import hmac

_MIN_SECRET_BYTES = 32
_MAX_SECRET_BYTES = 1_024


def validate_scope_secret(value: bytes) -> bytes:
    if not isinstance(value, bytes) or not _MIN_SECRET_BYTES <= len(value) <= _MAX_SECRET_BYTES:
        raise ValueError("scope secret must be injected bounded bytes")
    return value


def derive_opaque_scope(
    secret: bytes,
    domain: str,
    *identifiers: str,
    prefix: str,
) -> str:
    """Return a non-reversible stable scope key with unambiguous framing."""

    key = validate_scope_secret(secret)
    if not domain.isascii() or not domain or len(domain) > 64:
        raise ValueError("scope domain must be a bounded constant")
    if (
        not prefix.isascii()
        or not prefix
        or len(prefix) > 16
        or not prefix.replace("-", "").isalnum()
    ):
        raise ValueError("scope prefix must be a bounded constant")
    framed = bytearray(domain.encode("ascii"))
    for identifier in identifiers:
        if not isinstance(identifier, str):
            raise TypeError("scope identifiers must be trusted strings")
        encoded = identifier.encode("utf-8")
        framed.extend(len(encoded).to_bytes(4, "big"))
        framed.extend(encoded)
    digest = hmac.new(key, bytes(framed), hashlib.sha256).hexdigest()
    return f"{prefix}-{digest}"
