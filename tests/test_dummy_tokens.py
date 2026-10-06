from guardianbackend.auth import issue_dummy_user_token, verify_dummy_user_token


def test_dummy_token_round_trip() -> None:
    token = issue_dummy_user_token(
        signing_key="test-signing-key",
        user_id="user_test123",
        email="test-user@guardian.local",
        name="Test User",
        picture="https://example.com/avatar.png",
    )

    user = verify_dummy_user_token(token, "test-signing-key")

    assert user is not None
    assert user.user_id == "user_test123"
    assert user.email == "test-user@guardian.local"
    assert user.auth_provider == "dummy"


def test_dummy_token_rejects_tampering() -> None:
    token = issue_dummy_user_token(
        signing_key="test-signing-key",
        user_id="user_test123",
        email="test-user@guardian.local",
    )
    prefix, payload_b64, signature_b64 = token.split(".", 2)
    replacement = "A" if signature_b64[-1] != "A" else "B"
    tampered = f"{prefix}.{payload_b64}.{signature_b64[:-1]}{replacement}"

    user = verify_dummy_user_token(tampered, "test-signing-key")

    assert user is None
