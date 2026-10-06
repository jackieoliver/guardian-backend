import pytest
from fastapi.security import HTTPAuthorizationCredentials

from guardianbackend.api.deps import require_authenticated_user
from guardianbackend.auth.google import verify_google_user_token
from guardianbackend.config import Settings


def test_verify_google_user_token_accepts_matching_audience(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    observed_audiences: list[str] = []

    def fake_verify(token: str, request: object, audience: str) -> dict[str, object]:
        del request
        observed_audiences.append(audience)
        assert token == "google-token"
        if audience != "mac-client-id":
            raise ValueError("wrong audience")
        return {
            "sub": "google-sub-123",
            "email": "person@example.com",
            "email_verified": True,
            "name": "Example Person",
            "picture": "https://example.com/avatar.png",
        }

    monkeypatch.setattr(
        "guardianbackend.auth.google.google_id_token.verify_oauth2_token",
        fake_verify,
    )

    user = verify_google_user_token(
        "google-token",
        client_ids=["server-client-id", "mac-client-id"],
    )

    assert user is not None
    assert observed_audiences == ["server-client-id", "mac-client-id"]
    assert user.user_id == "google-sub-123"
    assert user.email == "person@example.com"
    assert user.auth_provider == "google"


def test_require_authenticated_user_accepts_google_token(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_verify(token: str, *, client_ids: list[str], allowed_emails: list[str]) -> object:
        assert token == "real-google-token"
        assert client_ids == ["mac-client-id", "server-client-id"]
        assert allowed_emails == []
        from guardianbackend.users import AuthenticatedUser

        return AuthenticatedUser(
            user_id="google-sub-123",
            email="person@example.com",
            email_verified=True,
            name="Example Person",
            auth_provider="google",
        )

    monkeypatch.setattr(
        "guardianbackend.api.deps.verify_google_user_token",
        fake_verify,
    )

    user = require_authenticated_user(
        HTTPAuthorizationCredentials(scheme="Bearer", credentials="real-google-token"),
        Settings(
            google_oauth_client_ids="mac-client-id,server-client-id",
        ),
    )

    assert user.user_id == "google-sub-123"
    assert user.email == "person@example.com"
    assert user.auth_provider == "google"
