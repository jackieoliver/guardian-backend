from guardianbackend.config import Settings
from guardianbackend.users import AuthenticatedUser, InMemoryUserRepository, UserService


def test_user_service_assigns_default_infra_fields() -> None:
    service = UserService(
        InMemoryUserRepository(),
        Settings(
            default_runtime_vm_id="guardian-vm-01",
            default_compiler_vm_id="guardian-vm-lifestream-compiler",
            runtime_workspace_root="/srv/guardian-runtime",
            compiler_workspace_root="/srv/guardian-compiler",
        ),
    )

    user = service.ensure_user_for_auth(
        AuthenticatedUser(
            user_id="user_Test-123",
            email="test-user@guardian.local",
            auth_provider="dummy",
        )
    )

    assert user.vm_id == "guardian-vm-01"
    assert user.compiler_vm_id == "guardian-vm-lifestream-compiler"
    assert user.linux_username == "gdn_usertest123"
    assert user.runtime_workspace_path == "/srv/guardian-runtime/user_Test-123"
    assert user.compiler_workspace_path == "/srv/guardian-compiler/user_Test-123"
    assert user.runtime_workspace_state == "pending"
    assert user.compiler_workspace_state == "pending"
    assert service.should_bootstrap_user(user) is True

    provisioning = service.mark_bootstrap_requested(user.user_id)
    assert provisioning.runtime_workspace_state == "provisioning"
    assert provisioning.compiler_workspace_state == "provisioning"

    ready_runtime = service.mark_runtime_workspace_bootstrapped(
        user.user_id,
        success=True,
    )
    ready_compiler = service.mark_compiler_workspace_bootstrapped(
        user.user_id,
        success=True,
    )
    done = service.mark_bootstrap_completed(user.user_id)
    assert ready_runtime.runtime_workspace_state == "ready"
    assert ready_compiler.compiler_workspace_state == "ready"
    assert done.infra_last_bootstrapped_at is not None


def test_google_user_path_gets_same_infra_defaults_and_updates() -> None:
    service = UserService(
        InMemoryUserRepository(),
        Settings(
            default_runtime_vm_id="guardian-vm-01",
            default_compiler_vm_id="guardian-vm-lifestream-compiler",
            runtime_workspace_root="/srv/guardian-runtime",
            compiler_workspace_root="/srv/guardian-compiler",
        ),
    )

    created = service.ensure_user_for_auth(
        AuthenticatedUser(
            user_id="google-sub-123",
            email="person@example.com",
            name="First Name",
            auth_provider="google",
        )
    )

    assert created.auth_provider == "google"
    assert created.vm_id == "guardian-vm-01"
    assert created.compiler_vm_id == "guardian-vm-lifestream-compiler"
    assert created.linux_username == "gdn_googlesub123"
    assert created.runtime_workspace_state == "pending"
    assert created.compiler_workspace_state == "pending"
    assert service.should_bootstrap_user(created) is True

    updated = service.ensure_user_for_auth(
        AuthenticatedUser(
            user_id="google-sub-123",
            email="person@example.com",
            name="Updated Name",
            auth_provider="google",
        )
    )

    assert updated.user_id == created.user_id
    assert updated.name == "Updated Name"
    assert updated.vm_id == created.vm_id
    assert updated.compiler_vm_id == created.compiler_vm_id
    assert updated.runtime_workspace_path == created.runtime_workspace_path
    assert updated.compiler_workspace_path == created.compiler_workspace_path
