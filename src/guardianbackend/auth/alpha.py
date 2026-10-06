import base64
import hashlib
import hmac
import json

from guardianbackend.users.models import AuthenticatedUser


def _urlsafe_b64encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("utf-8").rstrip("=")


def _urlsafe_b64decode(raw: str) -> bytes:
    padding = "=" * (-len(raw) % 4)
    return base64.urlsafe_b64decode(raw + padding)


def issue_dummy_user_token(
    *,
    signing_key: str,
    user_id: str,
    email: str,
    name: str | None = None,
    picture: str | None = None,
) -> str:
    payload = {
        "user_id": user_id,
        "email": email,
        "email_verified": True,
        "name": name,
        "picture": picture,
        "auth_provider": "dummy",
    }
    payload_b64 = _urlsafe_b64encode(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    signature = hmac.new(
        signing_key.encode("utf-8"), payload_b64.encode("utf-8"), hashlib.sha256
    ).digest()
    return f"guardian-dummy.{payload_b64}.{_urlsafe_b64encode(signature)}"


def verify_dummy_user_token(token: str, signing_key: str) -> AuthenticatedUser | None:
    prefix = "guardian-dummy."
    if not token.startswith(prefix):
        return None
    remainder = token[len(prefix) :]
    try:
        payload_b64, signature_b64 = remainder.split(".", 1)
    except ValueError:
        return None
    expected_signature = hmac.new(
        signing_key.encode("utf-8"), payload_b64.encode("utf-8"), hashlib.sha256
    ).digest()
    provided_signature = _urlsafe_b64decode(signature_b64)
    if not hmac.compare_digest(expected_signature, provided_signature):
        return None
    payload = json.loads(_urlsafe_b64decode(payload_b64).decode("utf-8"))
    return AuthenticatedUser.model_validate(payload)
