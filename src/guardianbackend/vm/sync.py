from __future__ import annotations

import io
import json
import shlex
import subprocess
import tarfile
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from pydantic import BaseModel

from guardianbackend.config import Settings
from guardianbackend.files import SourceFile, SourceFileRepository
from guardianbackend.sources import OwnedSourceRepository
from guardianbackend.storage import ObjectStore
from guardianbackend.users import AppUser, UserRepository

from .models import VmRecord
from .repository import VmRepository


class SyncCompiledOutputsRequest(BaseModel):
    user_id: str


class SyncCompiledOutputsResponse(BaseModel):
    success: bool
    user_id: str
    runtime_vm_id: str
    compiler_vm_id: str
    mirrored_file_count: int
    compiler_result: dict[str, Any]
    runtime_result: dict[str, Any]


class SyncSourceFilesToCompilerRequest(BaseModel):
    user_id: str
    owned_source_id: str


class SyncSourceFilesToCompilerResponse(BaseModel):
    success: bool
    user_id: str
    owned_source_id: str
    compiler_vm_id: str
    compiler_workspace_path: str
    raw_sync_path: str
    synced_source_file_count: int
    compiler_result: dict[str, Any]


class MirrorApprovedSourceToRuntimeRequest(BaseModel):
    user_id: str
    owned_source_id: str


class MirrorApprovedSourceToRuntimeResponse(BaseModel):
    success: bool
    user_id: str
    owned_source_id: str
    runtime_vm_id: str
    compiler_vm_id: str
    compiler_raw_path: str
    runtime_source_path: str
    mirrored_file_count: int
    compiler_result: dict[str, Any]
    runtime_result: dict[str, Any]


@dataclass
class SshExecutionResult:
    success: bool
    returncode: int
    stdout: str
    stderr: str


@dataclass
class SshBytesExecutionResult:
    success: bool
    returncode: int
    stdout: bytes
    stderr: str


class VmSshExecutor(Protocol):
    def run(self, vm: VmRecord, command: str) -> SshExecutionResult: ...

    def capture_bytes(self, vm: VmRecord, command: str) -> SshBytesExecutionResult: ...

    def run_with_input(
        self,
        vm: VmRecord,
        command: str,
        stdin_bytes: bytes,
    ) -> SshExecutionResult: ...


class OpensshVmSshExecutor:
    def __init__(self, settings: Settings) -> None:
        if not settings.vm_bootstrap_ssh_private_key:
            raise RuntimeError("VM SSH executor requires GUARDIAN_VM_BOOTSTRAP_SSH_PRIVATE_KEY")
        self._private_key = settings.vm_bootstrap_ssh_private_key.replace("\\n", "\n")

    def run(self, vm: VmRecord, command: str) -> SshExecutionResult:
        result = self._run_ssh_command(vm, command, text=True)
        stdout = result.stdout if isinstance(result.stdout, str) else ""
        stderr = result.stderr if isinstance(result.stderr, str) else ""
        return SshExecutionResult(
            success=result.returncode == 0,
            returncode=result.returncode,
            stdout=stdout.strip(),
            stderr=stderr.strip(),
        )

    def capture_bytes(self, vm: VmRecord, command: str) -> SshBytesExecutionResult:
        result = self._run_ssh_command(vm, command, text=False)
        stdout = result.stdout if isinstance(result.stdout, bytes) else b""
        stderr = (
            result.stderr.decode("utf-8", errors="replace")
            if isinstance(result.stderr, bytes)
            else str(result.stderr)
        )
        return SshBytesExecutionResult(
            success=result.returncode == 0,
            returncode=result.returncode,
            stdout=stdout,
            stderr=stderr.strip(),
        )

    def run_with_input(
        self,
        vm: VmRecord,
        command: str,
        stdin_bytes: bytes,
    ) -> SshExecutionResult:
        result = self._run_ssh_command(
            vm,
            command,
            text=False,
            stdin_bytes=stdin_bytes,
        )
        stdout = (
            result.stdout.decode("utf-8", errors="replace")
            if isinstance(result.stdout, bytes)
            else str(result.stdout)
        )
        stderr = (
            result.stderr.decode("utf-8", errors="replace")
            if isinstance(result.stderr, bytes)
            else str(result.stderr)
        )
        return SshExecutionResult(
            success=result.returncode == 0,
            returncode=result.returncode,
            stdout=stdout.strip(),
            stderr=stderr.strip(),
        )

    def _run_ssh_command(
        self,
        vm: VmRecord,
        command: str,
        *,
        text: bool,
        stdin_bytes: bytes | None = None,
    ) -> subprocess.CompletedProcess[str] | subprocess.CompletedProcess[bytes]:
        with tempfile.TemporaryDirectory(prefix="guardian-vm-ssh-") as temp_dir:
            key_path = Path(temp_dir) / "ssh_key"
            key_path.write_text(self._private_key)
            key_path.chmod(0o600)
            deadline = time.monotonic() + 60
            last_result: (
                subprocess.CompletedProcess[str]
                | subprocess.CompletedProcess[bytes]
                | None
            ) = None
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
                    input=stdin_bytes,
                    capture_output=True,
                    text=text,
                    check=False,
                )
                last_result = result
                if result.returncode == 0:
                    return result
                time.sleep(2)
            if last_result is None:
                raise RuntimeError("ssh command did not run")
            return last_result


class CompiledOutputSyncService:
    def __init__(
        self,
        settings: Settings,
        user_repository: UserRepository,
        vm_repository: VmRepository,
        ssh_executor: VmSshExecutor | None = None,
    ) -> None:
        self._settings = settings
        self._user_repository = user_repository
        self._vm_repository = vm_repository
        self._ssh_executor = ssh_executor or OpensshVmSshExecutor(settings)

    def sync_user_compiled_outputs(self, user_id: str) -> SyncCompiledOutputsResponse:
        user = self._require_user(user_id)
        compiler_vm = self._require_vm(user.compiler_vm_id, "compiler")
        runtime_vm = self._require_vm(user.vm_id, "runtime")
        compiler_path = self._require_path(user.compiler_workspace_path, "compiler_workspace_path")
        runtime_path = self._require_path(user.runtime_workspace_path, "runtime_workspace_path")

        compiled_out_path = f"{compiler_path}/compiled-out"
        runtime_compiled_path = f"{runtime_path}/compiled"

        compiler_manifest_command = (
            "bash --noprofile --norc -lc "
            + json.dumps(
                " && ".join(
                    [
                        f"test -d {shlex.quote(compiled_out_path)}",
                        f"find {shlex.quote(compiled_out_path)} -type f | wc -l",
                    ]
                )
            )
        )
        compiler_manifest_result = self._ssh_executor.run(compiler_vm, compiler_manifest_command)
        if not compiler_manifest_result.success:
            raise RuntimeError(
                f"compiler VM manifest check failed: {compiler_manifest_result.stderr}"
            )
        mirrored_file_count = int(compiler_manifest_result.stdout.splitlines()[-1].strip() or "0")

        archive_command = (
            "bash --noprofile --norc -lc "
            + json.dumps(
                " && ".join(
                    [
                        f"test -d {shlex.quote(compiled_out_path)}",
                        f"cd {shlex.quote(compiled_out_path)}",
                        "tar -cf - .",
                    ]
                )
            )
        )
        compiler_archive_result = self._ssh_executor.capture_bytes(compiler_vm, archive_command)
        if not compiler_archive_result.success:
            raise RuntimeError(
                f"compiler VM archive failed: {compiler_archive_result.stderr}"
            )

        install_command = (
            "bash --noprofile --norc -lc "
            + json.dumps(
                " && ".join(
                    [
                        f"sudo install -d -o {shlex.quote(user.linux_username or '')} "
                        f"-g {shlex.quote(user.linux_username or '')} -m 0755 "
                        f"{shlex.quote(runtime_compiled_path)}",
                        (
                            f"sudo find {shlex.quote(runtime_compiled_path)} -mindepth 1 "
                            "-exec rm -rf -- {} + || true"
                        ),
                        f"sudo tar -xf - -C {shlex.quote(runtime_compiled_path)}",
                        (
                            f"sudo chown -R {shlex.quote(user.linux_username or '')}:"
                            f"{shlex.quote(user.linux_username or '')} "
                            f"{shlex.quote(runtime_compiled_path)}"
                        ),
                        f"find {shlex.quote(runtime_compiled_path)} -type f | wc -l",
                    ]
                )
            )
        )
        runtime_result = self._ssh_executor.run_with_input(
            runtime_vm,
            install_command,
            compiler_archive_result.stdout,
        )
        if not runtime_result.success:
            raise RuntimeError(f"runtime VM sync failed: {runtime_result.stderr}")

        return SyncCompiledOutputsResponse(
            success=True,
            user_id=user.user_id,
            runtime_vm_id=runtime_vm.vm_id,
            compiler_vm_id=compiler_vm.vm_id,
            mirrored_file_count=mirrored_file_count,
            compiler_result={
                "stdout": compiler_manifest_result.stdout,
                "stderr": compiler_manifest_result.stderr,
            },
            runtime_result={
                "stdout": runtime_result.stdout,
                "stderr": runtime_result.stderr,
            },
        )

    def _require_user(self, user_id: str) -> AppUser:
        user = self._user_repository.get_user(user_id)
        if user is None:
            raise KeyError(f"user not found: {user_id}")
        return user

    def _require_vm(self, vm_id: str | None, role: str) -> VmRecord:
        if vm_id is None:
            raise RuntimeError(f"user is missing {role} vm assignment")
        vm = self._vm_repository.get_vm(vm_id)
        if vm is None:
            raise KeyError(f"vm not found: {vm_id}")
        return vm

    def _require_path(self, path: str | None, field_name: str) -> str:
        if path is None:
            raise RuntimeError(f"user is missing {field_name}")
        return path


class CompilerSourceSyncService:
    def __init__(
        self,
        settings: Settings,
        user_repository: UserRepository,
        vm_repository: VmRepository,
        owned_source_repository: OwnedSourceRepository,
        source_file_repository: SourceFileRepository,
        object_store: ObjectStore,
        ssh_executor: VmSshExecutor | None = None,
    ) -> None:
        self._settings = settings
        self._user_repository = user_repository
        self._vm_repository = vm_repository
        self._owned_source_repository = owned_source_repository
        self._source_file_repository = source_file_repository
        self._object_store = object_store
        self._ssh_executor = ssh_executor or OpensshVmSshExecutor(settings)

    def sync_source_files_to_compiler(
        self,
        *,
        user_id: str,
        owned_source_id: str,
    ) -> SyncSourceFilesToCompilerResponse:
        user = self._require_user(user_id)
        owned_source = self._owned_source_repository.get_owned_source(owned_source_id)
        if owned_source is None or owned_source.user_id != user.user_id:
            raise RuntimeError("owned source not found for user")
        compiler_vm = self._require_vm(user.compiler_vm_id, "compiler")
        compiler_path = self._require_path(user.compiler_workspace_path, "compiler_workspace_path")
        raw_source_path = f"{compiler_path}/raw-work/{owned_source_id}"

        source_files = self._source_file_repository.list_source_files_for_owned_source(
            owned_source_id
        )
        source_files = [
            source_file
            for source_file in source_files
            if source_file.user_id == user.user_id
        ]
        archive_bytes = self._build_source_snapshot_tar(
            owned_source_id=owned_source_id,
            source_files=source_files,
        )
        install_command = (
            "bash --noprofile --norc -lc "
            + json.dumps(
                " && ".join(
                    [
                        f"mkdir -p {shlex.quote(raw_source_path)}",
                        (
                            f"find {shlex.quote(raw_source_path)} -mindepth 1 "
                            "-exec rm -rf -- {} + || true"
                        ),
                        f"tar -xf - -C {shlex.quote(raw_source_path)}",
                        f"find {shlex.quote(raw_source_path)} -type f | wc -l",
                    ]
                )
            )
        )
        compiler_result = self._ssh_executor.run_with_input(
            compiler_vm,
            install_command,
            archive_bytes,
        )
        if not compiler_result.success:
            raise RuntimeError(f"compiler raw-work sync failed: {compiler_result.stderr}")

        return SyncSourceFilesToCompilerResponse(
            success=True,
            user_id=user.user_id,
            owned_source_id=owned_source_id,
            compiler_vm_id=compiler_vm.vm_id,
            compiler_workspace_path=compiler_path,
            raw_sync_path=raw_source_path,
            synced_source_file_count=len(source_files),
            compiler_result={
                "stdout": compiler_result.stdout,
                "stderr": compiler_result.stderr,
            },
        )

    def _build_source_snapshot_tar(
        self,
        *,
        owned_source_id: str,
        source_files: list[SourceFile],
    ) -> bytes:
        buffer = io.BytesIO()
        manifest = {
            "owned_source_id": owned_source_id,
            "synced_at": time.time(),
            "file_count": len(source_files),
            "files": [
                {
                    "source_file_id": source_file.source_file_id,
                    "original_relative_path": source_file.original_relative_path,
                    "filename": source_file.filename,
                    "content_hash": source_file.content_hash,
                    "object_path": source_file.object_path,
                    "bucket": source_file.bucket,
                    "size_bytes": source_file.size_bytes,
                    "time_start": (
                        source_file.time_start.isoformat().replace("+00:00", "Z")
                        if source_file.time_start is not None
                        else None
                    ),
                    "time_end": (
                        source_file.time_end.isoformat().replace("+00:00", "Z")
                        if source_file.time_end is not None
                        else None
                    ),
                    "time_basis": source_file.time_basis,
                }
                for source_file in source_files
            ],
        }
        manifest_bytes = json.dumps(manifest, indent=2, sort_keys=True).encode("utf-8")

        with tarfile.open(fileobj=buffer, mode="w") as archive:
            manifest_info = tarfile.TarInfo(name="manifest.json")
            manifest_info.size = len(manifest_bytes)
            archive.addfile(manifest_info, io.BytesIO(manifest_bytes))

            for source_file in source_files:
                file_bytes = self._object_store.download_bytes(
                    bucket=source_file.bucket,
                    object_path=source_file.object_path,
                )
                archive_name = f"files/{source_file.original_relative_path}"
                info = tarfile.TarInfo(name=archive_name)
                info.size = len(file_bytes)
                archive.addfile(info, io.BytesIO(file_bytes))

        return buffer.getvalue()

    def _require_user(self, user_id: str) -> AppUser:
        user = self._user_repository.get_user(user_id)
        if user is None:
            raise KeyError(f"user not found: {user_id}")
        return user

    def _require_vm(self, vm_id: str | None, role: str) -> VmRecord:
        if vm_id is None:
            raise RuntimeError(f"user is missing {role} vm assignment")
        vm = self._vm_repository.get_vm(vm_id)
        if vm is None:
            raise KeyError(f"vm not found: {vm_id}")
        return vm

    def _require_path(self, path: str | None, field_name: str) -> str:
        if path is None:
            raise RuntimeError(f"user is missing {field_name}")
        return path


class ApprovedSourceMirrorService:
    def __init__(
        self,
        settings: Settings,
        user_repository: UserRepository,
        vm_repository: VmRepository,
        ssh_executor: VmSshExecutor | None = None,
    ) -> None:
        self._settings = settings
        self._user_repository = user_repository
        self._vm_repository = vm_repository
        self._ssh_executor = ssh_executor or OpensshVmSshExecutor(settings)

    def mirror_source_to_runtime(
        self,
        *,
        user_id: str,
        owned_source_id: str,
    ) -> MirrorApprovedSourceToRuntimeResponse:
        user = self._require_user(user_id)
        compiler_vm = self._require_vm(user.compiler_vm_id, "compiler")
        runtime_vm = self._require_vm(user.vm_id, "runtime")
        compiler_path = self._require_path(user.compiler_workspace_path, "compiler_workspace_path")
        runtime_path = self._require_path(user.runtime_workspace_path, "runtime_workspace_path")
        compiler_raw_path = f"{compiler_path}/raw-work/{owned_source_id}"
        runtime_source_path = f"{runtime_path}/sources/{owned_source_id}"

        compiler_manifest_command = (
            "bash --noprofile --norc -lc "
            + json.dumps(
                " && ".join(
                    [
                        f"test -d {shlex.quote(compiler_raw_path)}",
                        f"find {shlex.quote(compiler_raw_path)} -type f | wc -l",
                    ]
                )
            )
        )
        compiler_manifest_result = self._ssh_executor.run(compiler_vm, compiler_manifest_command)
        if not compiler_manifest_result.success:
            raise RuntimeError(
                f"compiler raw manifest check failed: {compiler_manifest_result.stderr}"
            )
        mirrored_file_count = int(compiler_manifest_result.stdout.splitlines()[-1].strip() or "0")

        archive_command = (
            "bash --noprofile --norc -lc "
            + json.dumps(
                " && ".join(
                    [
                        f"test -d {shlex.quote(compiler_raw_path)}",
                        f"cd {shlex.quote(compiler_raw_path)}",
                        "tar -cf - .",
                    ]
                )
            )
        )
        compiler_archive_result = self._ssh_executor.capture_bytes(compiler_vm, archive_command)
        if not compiler_archive_result.success:
            raise RuntimeError(
                f"compiler raw archive failed: {compiler_archive_result.stderr}"
            )

        install_command = (
            "bash --noprofile --norc -lc "
            + json.dumps(
                " && ".join(
                    [
                        f"sudo install -d -o {shlex.quote(user.linux_username or '')} "
                        f"-g {shlex.quote(user.linux_username or '')} -m 0755 "
                        f"{shlex.quote(runtime_source_path)}",
                        (
                            f"sudo find {shlex.quote(runtime_source_path)} -mindepth 1 "
                            "-exec rm -rf -- {} + || true"
                        ),
                        f"sudo tar -xf - -C {shlex.quote(runtime_source_path)}",
                        (
                            f"sudo chown -R {shlex.quote(user.linux_username or '')}:"
                            f"{shlex.quote(user.linux_username or '')} "
                            f"{shlex.quote(runtime_source_path)}"
                        ),
                        f"find {shlex.quote(runtime_source_path)} -type f | wc -l",
                    ]
                )
            )
        )
        runtime_result = self._ssh_executor.run_with_input(
            runtime_vm,
            install_command,
            compiler_archive_result.stdout,
        )
        if not runtime_result.success:
            raise RuntimeError(f"runtime source mirror failed: {runtime_result.stderr}")

        return MirrorApprovedSourceToRuntimeResponse(
            success=True,
            user_id=user.user_id,
            owned_source_id=owned_source_id,
            runtime_vm_id=runtime_vm.vm_id,
            compiler_vm_id=compiler_vm.vm_id,
            compiler_raw_path=compiler_raw_path,
            runtime_source_path=runtime_source_path,
            mirrored_file_count=mirrored_file_count,
            compiler_result={
                "stdout": compiler_manifest_result.stdout,
                "stderr": compiler_manifest_result.stderr,
            },
            runtime_result={
                "stdout": runtime_result.stdout,
                "stderr": runtime_result.stderr,
            },
        )

    def _require_user(self, user_id: str) -> AppUser:
        user = self._user_repository.get_user(user_id)
        if user is None:
            raise KeyError(f"user not found: {user_id}")
        return user

    def _require_vm(self, vm_id: str | None, role: str) -> VmRecord:
        if vm_id is None:
            raise RuntimeError(f"user is missing {role} vm assignment")
        vm = self._vm_repository.get_vm(vm_id)
        if vm is None:
            raise KeyError(f"vm not found: {vm_id}")
        return vm

    def _require_path(self, path: str | None, field_name: str) -> str:
        if path is None:
            raise RuntimeError(f"user is missing {field_name}")
        return path
