from datetime import UTC, datetime

from guardianbackend.config import Settings
from guardianbackend.users import AppUser, InMemoryUserRepository, UserService
from guardianbackend.vm import InMemoryVmRepository, UserBootstrapService, VmRecord


class _FakeSshExecutor:
    def __init__(self) -> None:
        self.commands: list[tuple[str, str]] = []

    def run(self, vm: VmRecord, command: str):  # type: ignore[no-untyped-def]
        self.commands.append((vm.vm_id, command))
        return type(
            "_Result",
            (),
            {"success": True, "returncode": 0, "stdout": "ok", "stderr": ""},
        )()


def test_user_bootstrap_writes_workspace_and_home_readmes() -> None:
    now = datetime.now(UTC)
    user_repository = InMemoryUserRepository()
    vm_repository = InMemoryVmRepository()
    vm_repository.save_vm(
        VmRecord(
            vm_id="guardian-vm-01",
            zone="us-west2-c",
            public_ip="1.2.3.4",
            ssh_login_user="example",
            role="runtime",
        )
    )
    vm_repository.save_vm(
        VmRecord(
            vm_id="guardian-vm-lifestream-compiler",
            zone="us-west2-c",
            public_ip="1.2.3.5",
            ssh_login_user="example",
            role="compiler",
        )
    )
    user = AppUser(
        user_id="user_bootstrap1",
        email="bootstrap@example.com",
        vm_id="guardian-vm-01",
        compiler_vm_id="guardian-vm-lifestream-compiler",
        linux_username="gdn_bootstrap1",
        runtime_workspace_path="/srv/guardian-runtime/user_bootstrap1",
        compiler_workspace_path="/srv/guardian-compiler/user_bootstrap1",
        created_at=now,
        updated_at=now,
        last_seen_at=now,
    )
    user_repository.save_user(user)
    fake_ssh = _FakeSshExecutor()
    service = UserBootstrapService(
        Settings(),
        user_repository,
        vm_repository,
        UserService(user_repository, Settings()),
        ssh_executor=fake_ssh,
    )

    result = service.process_user_bootstrap(user.user_id)

    assert result.success is True
    runtime_command = next(
        command for vm_id, command in fake_ssh.commands if vm_id == "guardian-vm-01"
    )
    compiler_command = next(
        command
        for vm_id, command in fake_ssh.commands
        if vm_id == "guardian-vm-lifestream-compiler"
    )
    assert "/srv/guardian-runtime/README.md" in runtime_command
    assert "/srv/guardian-runtime/user_bootstrap1/README.md" in runtime_command
    assert "/home/gdn_bootstrap1/README.md" in runtime_command
    assert "/home/gdn_bootstrap1/guardian-runtime" in runtime_command
    assert "/srv/guardian-compiler/README.md" in compiler_command
    assert "/srv/guardian-compiler/user_bootstrap1/README.md" in compiler_command
