from __future__ import annotations

import json
import shlex
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from google.cloud import tasks_v2
from google.cloud.tasks_v2.types import HttpMethod, HttpRequest, Task
from pydantic import BaseModel

from guardianbackend.config import Settings
from guardianbackend.users import AppUser, UserRepository, UserService

from .models import VmRecord
from .repository import VmRepository


class ProcessUserBootstrapRequest(BaseModel):
    user_id: str


class ProcessUserBootstrapResponse(BaseModel):
    success: bool
    user_id: str
    runtime_bootstrap: dict[str, Any]
    compiler_bootstrap: dict[str, Any]
    runtime_workspace_state: str
    compiler_workspace_state: str


class UserBootstrapDispatcher(Protocol):
    def dispatch_user_bootstrap(self, user_id: str) -> None: ...


class NoopUserBootstrapDispatcher:
    def dispatch_user_bootstrap(self, user_id: str) -> None:
        del user_id


class CloudTasksUserBootstrapDispatcher:
    def __init__(self, settings: Settings) -> None:
        bootstrap_queue = settings.cloud_tasks_user_bootstrap_queue or settings.cloud_tasks_queue
        if (
            settings.gcp_project_id is None
            or settings.cloud_tasks_location is None
            or bootstrap_queue is None
            or settings.worker_cloud_run_url is None
            or settings.internal_worker_token is None
        ):
            raise RuntimeError(
                "cloud tasks bootstrap dispatcher requires worker/task configuration"
            )
        self._client = tasks_v2.CloudTasksClient()
        self._worker_cloud_run_url = settings.worker_cloud_run_url
        self._internal_worker_token = settings.internal_worker_token
        self._queue_path = self._client.queue_path(
            settings.gcp_project_id,
            settings.cloud_tasks_location,
            bootstrap_queue,
        )

    def dispatch_user_bootstrap(self, user_id: str) -> None:
        payload = json.dumps({"user_id": user_id}).encode("utf-8")
        task = Task(
            http_request=HttpRequest(
                http_method=HttpMethod.POST,
                url=f"{self._worker_cloud_run_url.rstrip('/')}/internal/bootstrap-user",
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {self._internal_worker_token}",
                },
                body=payload,
            )
        )
        self._client.create_task(parent=self._queue_path, task=task)


def build_user_bootstrap_dispatcher(settings: Settings) -> UserBootstrapDispatcher:
    bootstrap_queue = settings.cloud_tasks_user_bootstrap_queue or settings.cloud_tasks_queue
    if not settings.uses_cloud:
        return NoopUserBootstrapDispatcher()
    if (
        settings.gcp_project_id
        and settings.cloud_tasks_location
        and bootstrap_queue
        and settings.worker_cloud_run_url
        and settings.internal_worker_token
    ):
        return CloudTasksUserBootstrapDispatcher(settings)
    return NoopUserBootstrapDispatcher()


@dataclass
class _SshExecutionResult:
    success: bool
    returncode: int
    stdout: str
    stderr: str


class _BootstrapExecutor(Protocol):
    def run(self, vm: VmRecord, command: str) -> _SshExecutionResult: ...


class _BootstrapSshExecutor:
    def __init__(self, settings: Settings) -> None:
        if not settings.vm_bootstrap_ssh_private_key:
            raise RuntimeError("VM bootstrap requires GUARDIAN_VM_BOOTSTRAP_SSH_PRIVATE_KEY")
        self._private_key = settings.vm_bootstrap_ssh_private_key.replace("\\n", "\n")

    def run(self, vm: VmRecord, command: str) -> _SshExecutionResult:
        with tempfile.TemporaryDirectory(prefix="guardian-bootstrap-") as temp_dir:
            key_path = Path(temp_dir) / "ssh_key"
            key_path.write_text(self._private_key)
            key_path.chmod(0o600)
            return self._run_ssh(vm, key_path, command)

    def _run_ssh(self, vm: VmRecord, key_path: Path, command: str) -> _SshExecutionResult:
        deadline = time.monotonic() + 60
        last_result: subprocess.CompletedProcess[str] | None = None
        ssh_command = [
            "ssh",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "IdentitiesOnly=yes",
            "-i",
            str(key_path),
            f"{vm.ssh_login_user}@{vm.public_ip}",
            command,
        ]
        while time.monotonic() < deadline:
            result = subprocess.run(
                ssh_command,
                capture_output=True,
                text=True,
                check=False,
            )
            last_result = result
            if result.returncode == 0:
                return _SshExecutionResult(
                    success=True,
                    returncode=result.returncode,
                    stdout=result.stdout.strip(),
                    stderr=result.stderr.strip(),
                )
            time.sleep(2)
        if last_result is None:
            raise RuntimeError("ssh command did not run")
        return _SshExecutionResult(
            success=False,
            returncode=last_result.returncode,
            stdout=last_result.stdout.strip(),
            stderr=last_result.stderr.strip(),
        )


class UserBootstrapService:
    def __init__(
        self,
        settings: Settings,
        user_repository: UserRepository,
        vm_repository: VmRepository,
        user_service: UserService,
        ssh_executor: _BootstrapExecutor | None = None,
    ) -> None:
        self._settings = settings
        self._user_repository = user_repository
        self._vm_repository = vm_repository
        self._user_service = user_service
        self._ssh_executor = ssh_executor or _BootstrapSshExecutor(settings)

    def process_user_bootstrap(self, user_id: str) -> ProcessUserBootstrapResponse:
        user = self._user_repository.get_user(user_id)
        if user is None:
            raise KeyError(f"user not found: {user_id}")
        if user.vm_id is None or user.compiler_vm_id is None:
            raise RuntimeError(f"user is missing VM assignments: {user.user_id}")

        runtime_vm = self._require_vm(user.vm_id)
        compiler_vm = self._require_vm(user.compiler_vm_id)

        runtime_result = self._ensure_runtime_workspace(runtime_vm, user)
        compiler_result = self._ensure_compiler_workspace(compiler_vm, user)

        self._user_service.mark_runtime_workspace_bootstrapped(
            user.user_id,
            success=runtime_result.success,
            error=runtime_result.stderr or None,
        )
        updated_user = self._user_service.mark_compiler_workspace_bootstrapped(
            user.user_id,
            success=compiler_result.success,
            error=compiler_result.stderr or None,
        )
        if runtime_result.success and compiler_result.success:
            updated_user = self._user_service.mark_bootstrap_completed(updated_user.user_id)

        return ProcessUserBootstrapResponse(
            success=runtime_result.success and compiler_result.success,
            user_id=updated_user.user_id,
            runtime_bootstrap={
                "vm_id": runtime_vm.vm_id,
                "success": runtime_result.success,
                "stdout": runtime_result.stdout,
                "stderr": runtime_result.stderr,
            },
            compiler_bootstrap={
                "vm_id": compiler_vm.vm_id,
                "success": compiler_result.success,
                "stdout": compiler_result.stdout,
                "stderr": compiler_result.stderr,
            },
            runtime_workspace_state=updated_user.runtime_workspace_state,
            compiler_workspace_state=updated_user.compiler_workspace_state,
        )

    def _require_vm(self, vm_id: str) -> VmRecord:
        vm = self._vm_repository.get_vm(vm_id)
        if vm is None:
            raise KeyError(f"vm not found: {vm_id}")
        return vm

    def _ensure_runtime_workspace(self, vm: VmRecord, user: AppUser) -> _SshExecutionResult:
        if user.linux_username is None or user.runtime_workspace_path is None:
            raise RuntimeError(f"user {user.user_id} is missing runtime fields")
        runtime_path = user.runtime_workspace_path
        home_path = f"/home/{user.linux_username}"
        ssh_dir = f"{home_path}/.ssh"
        authorized_keys = f"{ssh_dir}/authorized_keys"
        runtime_root_readme = f"{self._settings.runtime_workspace_root}/README.md"
        runtime_workspace_readme = f"{runtime_path}/README.md"
        home_readme = f"{home_path}/README.md"
        commands = [
            "sudo install -d -m 0755 /srv/guardian-runtime",
            (
                f"if ! id {user.linux_username} >/dev/null 2>&1; then "
                f"sudo useradd -m -s /usr/bin/tlog-rec-session-shell-bin-bash "
                f"{user.linux_username}; fi"
            ),
            (
                f"sudo install -d -o {user.linux_username} "
                f"-g {user.linux_username} -m 0700 {ssh_dir}"
            ),
        ]
        if user.terminal_ssh_public_key:
            quoted_public_key = shlex.quote(user.terminal_ssh_public_key)
            commands.extend(
                [
                    f"sudo touch {authorized_keys}",
                    (
                        f"sudo grep -qxF -- {quoted_public_key} {authorized_keys} "
                        f"|| printf '%s\\n' {quoted_public_key} "
                        f"| sudo tee -a {authorized_keys} >/dev/null"
                    ),
                    (
                        f"sudo chown {user.linux_username}:{user.linux_username} "
                        f"{authorized_keys}"
                    ),
                    f"sudo chmod 0600 {authorized_keys}",
                ]
            )
        commands.extend(
            [
                (
                    f"sudo install -d -o {user.linux_username} "
                    f"-g {user.linux_username} -m 0755 {runtime_path}"
                ),
                (
                    f"sudo install -d -o {user.linux_username} "
                    f"-g {user.linux_username} -m 0755 {runtime_path}/sources"
                ),
                (
                    f"sudo install -d -o {user.linux_username} "
                    f"-g {user.linux_username} -m 0755 {runtime_path}/compiled"
                ),
                (
                    f"sudo install -d -o {user.linux_username} "
                    f"-g {user.linux_username} -m 0755 {runtime_path}/sessions"
                ),
                f"sudo ln -sfn {runtime_path} {home_path}/guardian-runtime",
                (
                    f"sudo chown -h {user.linux_username}:{user.linux_username} "
                    f"{home_path}/guardian-runtime"
                ),
                *self._write_file_commands(
                    runtime_root_readme,
                    self._build_runtime_root_readme(),
                    owner="root",
                    group="root",
                ),
                *self._write_file_commands(
                    runtime_workspace_readme,
                    self._build_runtime_workspace_readme(user),
                    owner=user.linux_username,
                    group=user.linux_username,
                ),
                *self._write_file_commands(
                    home_readme,
                    self._build_runtime_home_readme(user),
                    owner=user.linux_username,
                    group=user.linux_username,
                ),
                f"printf '%s\\n' {user.linux_username} {runtime_path}",
            ]
        )
        command = (
            "bash --noprofile --norc -lc "
            + json.dumps(" && ".join(commands))
        )
        return self._ssh_executor.run(vm, command)

    def _ensure_compiler_workspace(self, vm: VmRecord, user: AppUser) -> _SshExecutionResult:
        if user.compiler_workspace_path is None:
            raise RuntimeError(f"user {user.user_id} is missing compiler workspace path")
        workspace_path = user.compiler_workspace_path
        compiler_root_readme = f"{self._settings.compiler_workspace_root}/README.md"
        compiler_workspace_readme = f"{workspace_path}/README.md"
        command = (
            "bash --noprofile --norc -lc "
            + json.dumps(
                " && ".join(
                    [
                        "sudo install -d -m 0755 /srv/guardian-compiler",
                        f"sudo install -d -m 0755 {workspace_path}/raw-work",
                        f"sudo install -d -m 0755 {workspace_path}/compiled-out",
                        f"sudo install -d -m 0755 {workspace_path}/artifacts",
                        *self._write_file_commands(
                            compiler_root_readme,
                            self._build_compiler_root_readme(),
                            owner="root",
                            group="root",
                        ),
                        *self._write_file_commands(
                            compiler_workspace_readme,
                            self._build_compiler_workspace_readme(user, vm),
                            owner=vm.ssh_login_user,
                            group=vm.ssh_login_user,
                        ),
                        f"sudo chown -R {vm.ssh_login_user}:{vm.ssh_login_user} {workspace_path}",
                        f"printf '%s\\n' {workspace_path}",
                    ]
                )
            )
        )
        return self._ssh_executor.run(vm, command)

    def _write_file_commands(
        self,
        path: str,
        content: str,
        *,
        owner: str,
        group: str,
        mode: str = "0644",
    ) -> list[str]:
        quoted_path = shlex.quote(path)
        python_code = shlex.quote(
            f"from pathlib import Path; Path({path!r}).write_text({content!r})"
        )
        return [
            f"sudo python3 -c {python_code}",
            f"sudo chown {shlex.quote(owner)}:{shlex.quote(group)} {quoted_path}",
            f"sudo chmod {mode} {quoted_path}",
        ]

    def _build_runtime_root_readme(self) -> str:
        return (
            "# Guardian Runtime VM\n\n"
            "This VM hosts per-user runtime workspaces.\n\n"
            "Layout:\n"
            "- USER_WORKSPACE/sources holds runtime-visible source files.\n"
            "- USER_WORKSPACE/compiled holds compiled outputs mirrored from the compiler VM.\n"
            "- USER_WORKSPACE/sessions holds runtime session artifacts or scratch state.\n\n"
            "This machine is runtime-facing. Canonical backend truth still lives "
            "in Firestore and GCS.\n"
        )

    def _build_runtime_workspace_readme(self, user: AppUser) -> str:
        return (
            f"# Guardian Runtime Workspace: {user.user_id}\n\n"
            f"Linux user: {user.linux_username}\n"
            f"Workspace path: {user.runtime_workspace_path}\n"
            f"Compiler workspace: {user.compiler_workspace_path}\n\n"
            "Folders:\n"
            "- sources contains runtime-visible source material.\n"
            "- compiled contains compiled outputs mirrored from guardian-vm-lifestream-compiler.\n"
            "- sessions contains runtime session artifacts or scratch state.\n\n"
            "Use this workspace as a materialized runtime view, not the only "
            "source of product truth.\n"
        )

    def _build_runtime_home_readme(self, user: AppUser) -> str:
        return (
            f"# Guardian Runtime Home: {user.linux_username}\n\n"
            "This home directory belongs to the Guardian runtime login user for "
            "the desktop app.\n\n"
            f"Useful paths:\n"
            f"- ~/guardian-runtime -> {user.runtime_workspace_path}\n"
            "- ~/guardian-runtime/sources\n"
            "- ~/guardian-runtime/compiled\n"
            "- ~/guardian-runtime/sessions\n\n"
            "Compiled outputs arrive from guardian-vm-lifestream-compiler via "
            "the backend sync step.\n"
        )

    def _build_compiler_root_readme(self) -> str:
        return (
            "# Guardian Compiler VM\n\n"
            "This VM is the lifestream workshop and compilation machine.\n\n"
            "Layout:\n"
            "- USER_WORKSPACE/raw-work for imported raw material or working copies.\n"
            "- USER_WORKSPACE/compiled-out for finished outputs ready to mirror "
            "to the runtime VM.\n"
            "- USER_WORKSPACE/artifacts for processing artifacts and scratch outputs.\n\n"
            "This machine is allowed to be ad-hoc. Canonical backend truth still "
            "lives outside the VM.\n"
        )

    def _build_compiler_workspace_readme(self, user: AppUser, vm: VmRecord) -> str:
        return (
            f"# Guardian Compiler Workspace: {user.user_id}\n\n"
            f"Workspace path: {user.compiler_workspace_path}\n"
            f"Compiler VM: {vm.vm_id}\n"
            f"Runtime workspace: {user.runtime_workspace_path}\n\n"
            "Folders:\n"
            "- raw-work for working copies and manual review inputs.\n"
            "- compiled-out for outputs that will be mirrored to the runtime VM.\n"
            "- artifacts for intermediate processing outputs.\n\n"
            "Anything in compiled-out is treated as ready-to-mirror output "
            "for the user's runtime VM.\n"
        )
