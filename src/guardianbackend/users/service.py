import re

from guardianbackend.config import Settings
from guardianbackend.domain import utc_now

from .models import AppUser, AuthenticatedUser
from .repository import UserRepository


class UserService:
    def __init__(self, repository: UserRepository, settings: Settings | None = None) -> None:
        self._repository = repository
        self._settings = settings or Settings()

    def _build_linux_username(self, user_id: str) -> str:
        sanitized = re.sub(r"[^a-z0-9]", "", user_id.lower())
        suffix = sanitized[:24] or "user"
        return f"gdn_{suffix}"

    def _build_runtime_workspace_path(self, user_id: str) -> str:
        return f"{self._settings.runtime_workspace_root}/{user_id}"

    def _build_compiler_workspace_path(self, user_id: str) -> str:
        return f"{self._settings.compiler_workspace_root}/{user_id}"

    def _apply_infra_defaults(self, user: AppUser) -> AppUser:
        return user.model_copy(
            update={
                "vm_id": user.vm_id or self._settings.default_runtime_vm_id,
                "compiler_vm_id": user.compiler_vm_id or self._settings.default_compiler_vm_id,
                "linux_username": user.linux_username or self._build_linux_username(user.user_id),
                "runtime_workspace_path": user.runtime_workspace_path
                or self._build_runtime_workspace_path(user.user_id),
                "compiler_workspace_path": user.compiler_workspace_path
                or self._build_compiler_workspace_path(user.user_id),
                "runtime_workspace_state": user.runtime_workspace_state or "pending",
                "compiler_workspace_state": user.compiler_workspace_state or "pending",
            }
        )

    def should_bootstrap_user(self, user: AppUser) -> bool:
        return (
            user.runtime_workspace_state in {"pending", "error"}
            or user.compiler_workspace_state in {"pending", "error"}
        )

    def ensure_user_for_auth(self, authenticated_user: AuthenticatedUser) -> AppUser:
        now = utc_now()
        existing = self._repository.get_user(authenticated_user.user_id)
        if existing is None:
            user = self._apply_infra_defaults(
                AppUser(
                user_id=authenticated_user.user_id,
                email=authenticated_user.email,
                name=authenticated_user.name,
                picture=authenticated_user.picture,
                auth_provider=authenticated_user.auth_provider,
                created_at=now,
                updated_at=now,
                last_seen_at=now,
            )
            )
            return self._repository.save_user(user)

        updated = self._apply_infra_defaults(existing).model_copy(
            update={
                "email": authenticated_user.email,
                "name": authenticated_user.name,
                "picture": authenticated_user.picture,
                "auth_provider": authenticated_user.auth_provider,
                "updated_at": now,
                "last_seen_at": now,
            }
        )
        return self._repository.save_user(updated)

    def get_user_for_auth(self, authenticated_user: AuthenticatedUser) -> AppUser:
        return self.ensure_user_for_auth(authenticated_user)

    def upsert_terminal_ssh_public_key_for_auth(
        self, authenticated_user: AuthenticatedUser, public_key: str
    ) -> AppUser:
        user = self.ensure_user_for_auth(authenticated_user)
        updated = user.model_copy(
            update={
                "terminal_ssh_public_key": public_key,
                "runtime_workspace_state": "pending",
                "updated_at": utc_now(),
            }
        )
        return self._repository.save_user(updated)

    def mark_bootstrap_completed(self, user_id: str) -> AppUser:
        user = self._repository.get_user(user_id)
        if user is None:
            raise KeyError(f"user not found: {user_id}")
        now = utc_now()
        updated = user.model_copy(
            update={
                "infra_last_bootstrapped_at": now,
                "infra_last_bootstrap_error": None,
                "updated_at": now,
            }
        )
        return self._repository.save_user(updated)

    def mark_bootstrap_requested(self, user_id: str) -> AppUser:
        user = self._repository.get_user(user_id)
        if user is None:
            raise KeyError(f"user not found: {user_id}")
        now = utc_now()
        updated = user.model_copy(
            update={
                "runtime_workspace_state": (
                    "provisioning"
                    if user.runtime_workspace_state in {"pending", "error"}
                    else user.runtime_workspace_state
                ),
                "compiler_workspace_state": (
                    "provisioning"
                    if user.compiler_workspace_state in {"pending", "error"}
                    else user.compiler_workspace_state
                ),
                "updated_at": now,
            }
        )
        return self._repository.save_user(updated)

    def mark_runtime_workspace_bootstrapped(
        self,
        user_id: str,
        *,
        success: bool,
        error: str | None = None,
    ) -> AppUser:
        user = self._repository.get_user(user_id)
        if user is None:
            raise KeyError(f"user not found: {user_id}")
        now = utc_now()
        updated = user.model_copy(
            update={
                "runtime_workspace_state": "ready" if success else "error",
                "infra_last_bootstrap_error": error,
                "updated_at": now,
            }
        )
        return self._repository.save_user(updated)

    def mark_compiler_workspace_bootstrapped(
        self,
        user_id: str,
        *,
        success: bool,
        error: str | None = None,
    ) -> AppUser:
        user = self._repository.get_user(user_id)
        if user is None:
            raise KeyError(f"user not found: {user_id}")
        now = utc_now()
        updated = user.model_copy(
            update={
                "compiler_workspace_state": "ready" if success else "error",
                "infra_last_bootstrapped_at": now if success else user.infra_last_bootstrapped_at,
                "infra_last_bootstrap_error": error,
                "updated_at": now,
            }
        )
        return self._repository.save_user(updated)
