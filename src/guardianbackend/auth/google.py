from __future__ import annotations

from typing import Any

from google.auth.exceptions import GoogleAuthError
from google.auth.transport.requests import Request
from google.oauth2 import id_token as google_id_token

from guardianbackend.users.models import AuthenticatedUser

_GOOGLE_REQUEST = Request()


def verify_google_user_token(
    token: str,
    *,
    client_ids: list[str],
    allowed_emails: list[str] | None = None,
) -> AuthenticatedUser | None:
    if not client_ids:
        return None

    payload: dict[str, Any] | None = None
    for client_id in client_ids:
        try:
            verified = google_id_token.verify_oauth2_token(
                token,
                _GOOGLE_REQUEST,
                audience=client_id,
            )  # type: ignore[no-untyped-call]
        except (GoogleAuthError, ValueError):
            continue
        if isinstance(verified, dict):
            payload = verified
            break

    if payload is None:
        return None

    email = payload.get("email")
    sub = payload.get("sub")
    if not isinstance(email, str) or not email or not isinstance(sub, str) or not sub:
        return None

    normalized_allowed_emails = {item.lower() for item in (allowed_emails or [])}
    if normalized_allowed_emails and email.lower() not in normalized_allowed_emails:
        return None

    return AuthenticatedUser(
        user_id=sub,
        email=email,
        email_verified=bool(payload.get("email_verified", False)),
        name=payload.get("name") if isinstance(payload.get("name"), str) else None,
        picture=payload.get("picture") if isinstance(payload.get("picture"), str) else None,
        auth_provider="google",
    )
