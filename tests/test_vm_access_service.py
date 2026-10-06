from datetime import UTC, datetime

from guardianbackend.users import AppUser
from guardianbackend.vm import InMemoryVmRepository, VmAccessService, VmRecord


def _user(**overrides: object) -> AppUser:
    now = datetime.now(UTC)
    base = AppUser(
        user_id="user_123",
        email="user@example.com",
        created_at=now,
        updated_at=now,
        last_seen_at=now,
    )
    return base.model_copy(update=overrides)


def test_vm_access_requires_public_key_before_connecting() -> None:
    vm_repository = InMemoryVmRepository()
    vm_repository.save_vm(
        VmRecord(
            vm_id="guardian-vm-01",
            zone="us-west2-c",
            public_ip="35.236.113.159",
            ssh_login_user="example",
            role="runtime",
        )
    )
    service = VmAccessService(vm_repository)

    info = service.get_vm_access_info(
        _user(
            vm_id="guardian-vm-01",
            linux_username="gdn_user123",
            runtime_workspace_path="/srv/guardian-runtime/user_123",
            runtime_workspace_state="ready",
        )
    )

    assert info.access_state == "needs_ssh_key"
    assert info.can_connect is False
    assert info.host == "35.236.113.159"


def test_vm_access_is_ready_when_runtime_and_key_are_ready() -> None:
    vm_repository = InMemoryVmRepository()
    vm_repository.save_vm(
        VmRecord(
            vm_id="guardian-vm-01",
            zone="us-west2-c",
            public_ip="35.236.113.159",
            ssh_login_user="example",
            role="runtime",
        )
    )
    service = VmAccessService(vm_repository)

    info = service.get_vm_access_info(
        _user(
            vm_id="guardian-vm-01",
            linux_username="gdn_user123",
            runtime_workspace_path="/srv/guardian-runtime/user_123",
            runtime_workspace_state="ready",
            terminal_ssh_public_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest guardian@test",
        )
    )

    assert info.access_state == "ready"
    assert info.can_connect is True
    assert info.port == 22
    assert info.linux_username == "gdn_user123"
