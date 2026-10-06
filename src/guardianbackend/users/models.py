from datetime import datetime

from pydantic import BaseModel, field_validator


class AuthenticatedUser(BaseModel):
    user_id: str
    email: str
    email_verified: bool = True
    name: str | None = None
    picture: str | None = None
    auth_provider: str = "dummy"


class AppUser(BaseModel):
    user_id: str
    email: str
    name: str | None = None
    picture: str | None = None
    role: str = "user"
    vm_id: str | None = None
    compiler_vm_id: str | None = None
    linux_username: str | None = None
    runtime_workspace_path: str | None = None
    compiler_workspace_path: str | None = None
    runtime_workspace_state: str = "pending"
    compiler_workspace_state: str = "pending"
    terminal_ssh_public_key: str | None = None
    auth_provider: str = "dummy"
    infra_last_bootstrapped_at: datetime | None = None
    infra_last_bootstrap_error: str | None = None
    created_at: datetime
    updated_at: datetime
    last_seen_at: datetime


class UpdateTerminalSshKeyRequest(BaseModel):
    public_key: str

    @field_validator("public_key")
    @classmethod
    def validate_public_key(cls, value: str) -> str:
        normalized = value.strip()
        parts = normalized.split()
        allowed_prefixes = {
            "ssh-ed25519",
            "ssh-rsa",
            "ecdsa-sha2-nistp256",
            "ecdsa-sha2-nistp384",
            "ecdsa-sha2-nistp521",
            "sk-ssh-ed25519@openssh.com",
            "sk-ecdsa-sha2-nistp256@openssh.com",
        }
        if len(parts) < 2 or parts[0] not in allowed_prefixes:
            raise ValueError("public_key must be a valid OpenSSH public key")
        return normalized
