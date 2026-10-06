from __future__ import annotations

from pydantic import BaseModel

from guardianbackend.users import AppUser

from .repository import VmRepository


class VmAccessInfo(BaseModel):
    vm_id: str | None
    host: str | None
    port: int | None
    linux_username: str | None
    runtime_workspace_path: str | None
    runtime_workspace_state: str
    access_state: str
    can_connect: bool
    terminal_ssh_public_key_present: bool
    bootstrap_error: str | None


class VmAccessService:
    def __init__(self, vm_repository: VmRepository) -> None:
        self._vm_repository = vm_repository

    def get_vm_access_info(self, user: AppUser) -> VmAccessInfo:
        has_public_key = bool(user.terminal_ssh_public_key)
        if user.vm_id is None or user.linux_username is None or user.runtime_workspace_path is None:
            return VmAccessInfo(
                vm_id=user.vm_id,
                host=None,
                port=None,
                linux_username=user.linux_username,
                runtime_workspace_path=user.runtime_workspace_path,
                runtime_workspace_state=user.runtime_workspace_state,
                access_state="unassigned",
                can_connect=False,
                terminal_ssh_public_key_present=has_public_key,
                bootstrap_error=user.infra_last_bootstrap_error,
            )

        vm = self._vm_repository.get_vm(user.vm_id)
        if vm is None:
            raise KeyError(f"vm not found: {user.vm_id}")

        if not has_public_key:
            access_state = "needs_ssh_key"
        elif user.runtime_workspace_state == "ready":
            access_state = "ready"
        elif user.runtime_workspace_state == "error":
            access_state = "error"
        else:
            access_state = "provisioning"

        return VmAccessInfo(
            vm_id=vm.vm_id,
            host=vm.public_ip,
            port=22,
            linux_username=user.linux_username,
            runtime_workspace_path=user.runtime_workspace_path,
            runtime_workspace_state=user.runtime_workspace_state,
            access_state=access_state,
            can_connect=access_state == "ready",
            terminal_ssh_public_key_present=has_public_key,
            bootstrap_error=user.infra_last_bootstrap_error,
        )
