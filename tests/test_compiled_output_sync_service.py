from datetime import UTC, datetime

from guardianbackend.config import Settings
from guardianbackend.users import AppUser, InMemoryUserRepository
from guardianbackend.vm import (
    CompiledOutputSyncService,
    InMemoryVmRepository,
    SshBytesExecutionResult,
    SshExecutionResult,
    VmRecord,
)


class FakeVmSshExecutor:
    def __init__(self) -> None:
        self.commands: list[tuple[str, str]] = []
        self.stdin_payloads: list[tuple[str, bytes]] = []

    def run(self, vm: VmRecord, command: str) -> SshExecutionResult:
        self.commands.append((vm.vm_id, command))
        if vm.role == "compiler":
            return SshExecutionResult(
                success=True,
                returncode=0,
                stdout="2\n",
                stderr="",
            )
        return SshExecutionResult(
            success=True,
            returncode=0,
            stdout="2\n",
            stderr="",
        )

    def capture_bytes(self, vm: VmRecord, command: str) -> SshBytesExecutionResult:
        self.commands.append((vm.vm_id, command))
        return SshBytesExecutionResult(
            success=True,
            returncode=0,
            stdout=b"fake-tar-stream",
            stderr="",
        )

    def run_with_input(
        self,
        vm: VmRecord,
        command: str,
        stdin_bytes: bytes,
    ) -> SshExecutionResult:
        self.commands.append((vm.vm_id, command))
        self.stdin_payloads.append((vm.vm_id, stdin_bytes))
        return SshExecutionResult(
            success=True,
            returncode=0,
            stdout="2\n",
            stderr="",
        )


def test_sync_user_compiled_outputs_mirrors_compiler_tree() -> None:
    user_repository = InMemoryUserRepository()
    vm_repository = InMemoryVmRepository()
    ssh_executor = FakeVmSshExecutor()
    settings = Settings(vm_bootstrap_ssh_private_key="test-key")

    user_repository.save_user(
        AppUser(
            user_id="user_sync123",
            email="sync@guardian.local",
            vm_id="guardian-vm-01",
            compiler_vm_id="guardian-vm-lifestream-compiler",
            linux_username="gdn_user_sync123",
            runtime_workspace_path="/srv/guardian-runtime/user_sync123",
            compiler_workspace_path="/srv/guardian-compiler/user_sync123",
            runtime_workspace_state="ready",
            compiler_workspace_state="ready",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
            last_seen_at=datetime.now(tz=UTC),
        )
    )
    vm_repository.save_vm(
        VmRecord(
            vm_id="guardian-vm-01",
            zone="us-west2-c",
            public_ip="203.0.113.10",
            ssh_login_user="example",
            role="runtime",
        )
    )
    vm_repository.save_vm(
        VmRecord(
            vm_id="guardian-vm-lifestream-compiler",
            zone="us-west2-c",
            public_ip="203.0.113.11",
            ssh_login_user="example",
            role="compiler",
        )
    )

    service = CompiledOutputSyncService(
        settings,
        user_repository,
        vm_repository,
        ssh_executor=ssh_executor,
    )

    result = service.sync_user_compiled_outputs("user_sync123")

    assert result.success is True
    assert result.mirrored_file_count == 2
    assert ssh_executor.stdin_payloads == [("guardian-vm-01", b"fake-tar-stream")]
    assert any(
        vm_id == "guardian-vm-lifestream-compiler" and "compiled-out" in command
        for vm_id, command in ssh_executor.commands
    )
    assert any(
        vm_id == "guardian-vm-01" and "compiled" in command
        for vm_id, command in ssh_executor.commands
    )
