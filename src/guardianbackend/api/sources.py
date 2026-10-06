from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response, status

from guardianbackend.files import (
    SourceFile,
    SourceFileMetadataUpdateRequest,
    SourceFileService,
    SourceTimeCoverageResponse,
)
from guardianbackend.sources import (
    OwnedSource,
    OwnedSourceCreateRequest,
    OwnedSourceService,
    SourceType,
)
from guardianbackend.users import AppUser

from .deps import get_current_app_user, get_source_file_service, get_source_service

router = APIRouter()


@router.get("/source-types", response_model=list[SourceType])
def list_source_types(
    source_service: Annotated[OwnedSourceService, Depends(get_source_service)],
) -> list[SourceType]:
    return source_service.list_source_types()


@router.get("/me/sources", response_model=list[OwnedSource])
def list_my_sources(
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    source_service: Annotated[OwnedSourceService, Depends(get_source_service)],
) -> list[OwnedSource]:
    return source_service.list_owned_sources_for_user(app_user.user_id)


@router.post("/me/sources", response_model=OwnedSource, status_code=status.HTTP_201_CREATED)
def create_my_source(
    request: OwnedSourceCreateRequest,
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    source_service: Annotated[OwnedSourceService, Depends(get_source_service)],
) -> OwnedSource:
    return source_service.add_owned_source_for_user(app_user.user_id, request)


@router.get("/me/sources/{owned_source_id}/files", response_model=list[SourceFile])
def list_my_source_files(
    owned_source_id: str,
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    source_file_service: Annotated[SourceFileService, Depends(get_source_file_service)],
    limit: int = Query(default=100, ge=1, le=1000),
) -> list[SourceFile]:
    return source_file_service.list_source_files_for_owned_source(
        app_user.user_id,
        owned_source_id,
        limit=limit,
    )


@router.patch(
    "/me/sources/{owned_source_id}/files/{source_file_id}/metadata",
    response_model=SourceFile,
)
def update_my_source_file_metadata(
    owned_source_id: str,
    source_file_id: str,
    request: SourceFileMetadataUpdateRequest,
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    source_file_service: Annotated[SourceFileService, Depends(get_source_file_service)],
) -> SourceFile:
    return source_file_service.update_source_file_metadata(
        user_id=app_user.user_id,
        owned_source_id=owned_source_id,
        source_file_id=source_file_id,
        request=request,
    )


@router.get(
    "/me/sources/{owned_source_id}/coverage",
    response_model=SourceTimeCoverageResponse,
)
def get_my_source_coverage(
    owned_source_id: str,
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    source_file_service: Annotated[SourceFileService, Depends(get_source_file_service)],
    year: int | None = Query(default=None, ge=2000, le=2100),
) -> SourceTimeCoverageResponse:
    return source_file_service.get_source_time_coverage(
        user_id=app_user.user_id,
        owned_source_id=owned_source_id,
        year=year,
    )


@router.delete("/me/sources/{owned_source_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_my_source(
    owned_source_id: str,
    app_user: Annotated[AppUser, Depends(get_current_app_user)],
    source_service: Annotated[OwnedSourceService, Depends(get_source_service)],
) -> Response:
    source_service.remove_owned_source_for_user(app_user.user_id, owned_source_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
