from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request, status

from guardianbackend.config import Settings
from guardianbackend.imports import (
    ImportPlanRequest,
    ImportPlanResponse,
    ImportQueueItem,
    ImportRun,
    ImportRunCreateRequest,
    ImportRunStatusUpdateRequest,
    ImportService,
    ImportShard,
    ImportShardCreateRequest,
)
from guardianbackend.storage import ObjectStore
from guardianbackend.users import AppUser

from .deps import get_current_app_user, get_import_service, get_object_store, get_settings

router = APIRouter()


@router.get("/me/imports/queue", response_model=list[ImportQueueItem])
def list_import_queue(
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    import_service: Annotated[ImportService, Depends(get_import_service)],
    limit: int = Query(default=20, ge=1, le=200),
    include_completed: bool = Query(default=False),
) -> list[ImportQueueItem]:
    return import_service.list_import_queue_for_user(
        app_user.user_id,
        limit=limit,
        include_completed=include_completed,
    )


@router.get("/me/sources/{owned_source_id}/imports", response_model=list[ImportRun])
def list_import_runs(
    owned_source_id: str,
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    import_service: Annotated[ImportService, Depends(get_import_service)],
    limit: int = Query(default=50, ge=1, le=500),
) -> list[ImportRun]:
    return import_service.list_import_runs_for_source(
        app_user.user_id,
        owned_source_id,
        limit=limit,
    )


@router.post(
    "/me/sources/{owned_source_id}/imports",
    response_model=ImportRun,
    status_code=status.HTTP_201_CREATED,
)
def create_import_run(
    owned_source_id: str,
    request: ImportRunCreateRequest,
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    import_service: Annotated[ImportService, Depends(get_import_service)],
) -> ImportRun:
    return import_service.create_import_run(app_user.user_id, owned_source_id, request)


@router.get("/me/sources/{owned_source_id}/imports/{import_run_id}", response_model=ImportRun)
def get_import_run(
    owned_source_id: str,
    import_run_id: str,
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    import_service: Annotated[ImportService, Depends(get_import_service)],
) -> ImportRun:
    return import_service.get_import_run_for_source(
        app_user.user_id, owned_source_id, import_run_id
    )


@router.post(
    "/me/sources/{owned_source_id}/imports/{import_run_id}/plan",
    response_model=ImportPlanResponse,
)
def plan_import_run(
    owned_source_id: str,
    import_run_id: str,
    request: ImportPlanRequest,
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    import_service: Annotated[ImportService, Depends(get_import_service)],
) -> ImportPlanResponse:
    return import_service.plan_import_run(
        app_user.user_id,
        owned_source_id,
        import_run_id,
        request,
    )


@router.post(
    "/me/sources/{owned_source_id}/imports/{import_run_id}/shards",
    response_model=list[ImportShard],
    status_code=status.HTTP_201_CREATED,
)
def create_import_shards(
    owned_source_id: str,
    import_run_id: str,
    request: ImportShardCreateRequest,
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    import_service: Annotated[ImportService, Depends(get_import_service)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> list[ImportShard]:
    return import_service.create_import_shards(
        app_user.user_id,
        owned_source_id,
        import_run_id,
        request,
        transport_prefix=settings.gcs_transport_prefix,
    )


@router.put(
    "/me/sources/{owned_source_id}/imports/{import_run_id}/shards/{import_shard_id}/content",
    response_model=ImportShard,
)
async def upload_import_shard_content(
    owned_source_id: str,
    import_run_id: str,
    import_shard_id: str,
    request: Request,
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    import_service: Annotated[ImportService, Depends(get_import_service)],
    object_store: Annotated[ObjectStore, Depends(get_object_store)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> ImportShard:
    return import_service.upload_import_shard_content(
        app_user.user_id,
        owned_source_id,
        import_run_id,
        import_shard_id,
        data=await request.body(),
        bucket=settings.gcs_bucket_name or "guardian-local",
        object_store=object_store,
        content_type=request.headers.get("content-type"),
    )


@router.post(
    "/me/sources/{owned_source_id}/imports/{import_run_id}/complete",
    response_model=ImportRun,
)
def complete_import_run(
    owned_source_id: str,
    import_run_id: str,
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    import_service: Annotated[ImportService, Depends(get_import_service)],
) -> ImportRun:
    return import_service.complete_import_run(app_user.user_id, owned_source_id, import_run_id)


@router.post(
    "/me/sources/{owned_source_id}/imports/{import_run_id}/cancel",
    response_model=ImportRun,
)
def cancel_import_run(
    owned_source_id: str,
    import_run_id: str,
    request: ImportRunStatusUpdateRequest,
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    import_service: Annotated[ImportService, Depends(get_import_service)],
) -> ImportRun:
    return import_service.cancel_import_run(
        app_user.user_id,
        owned_source_id,
        import_run_id,
        request,
    )
