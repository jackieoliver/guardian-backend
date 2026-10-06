from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, status

from guardianbackend.users import (
    AppUser,
    AuthenticatedUser,
    UpdateTerminalSshKeyRequest,
    UserService,
)
from guardianbackend.vm import VmAccessInfo, VmAccessService

from .deps import (
    _get_or_build_user_bootstrap_dispatcher,
    get_current_app_user,
    get_user_service,
    get_vm_access_service,
    require_authenticated_user,
)

router = APIRouter()


@router.get("/me", response_model=AuthenticatedUser)
def get_me(
    authenticated_user: Annotated[AuthenticatedUser, Depends(require_authenticated_user)],
) -> AuthenticatedUser:
    return authenticated_user


@router.get("/me/profile", response_model=AppUser)
def get_my_profile(
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
) -> AppUser:
    return app_user


@router.get("/me/vm-access", response_model=VmAccessInfo)
def get_my_vm_access(
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    vm_access_service: Annotated[VmAccessService, Depends(get_vm_access_service)],
) -> VmAccessInfo:
    try:
        return vm_access_service.get_vm_access_info(app_user)
    except KeyError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(exc),
        ) from exc


@router.put("/me/terminal-ssh-key", response_model=AppUser)
def put_my_terminal_ssh_key(
    request_context: Request,
    request: UpdateTerminalSshKeyRequest,
    user_service: Annotated[UserService, Depends(get_user_service)],
    authenticated_user: Annotated[AuthenticatedUser, Depends(require_authenticated_user)],
) -> AppUser:
    user = user_service.upsert_terminal_ssh_public_key_for_auth(
        authenticated_user, request.public_key
    )
    user = user_service.mark_bootstrap_requested(user.user_id)
    try:
        _get_or_build_user_bootstrap_dispatcher(request_context).dispatch_user_bootstrap(
            user.user_id
        )
    except Exception:
        return user
    return user
