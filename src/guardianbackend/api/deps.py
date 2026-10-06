from typing import Annotated, cast

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from guardianbackend.auth import verify_dummy_user_token, verify_google_user_token
from guardianbackend.config import Settings
from guardianbackend.db import build_firestore_client
from guardianbackend.files import (
    FirestoreSourceFileRepository,
    FirestoreSourceTimeCoverageRepository,
    InMemorySourceFileRepository,
    InMemorySourceTimeCoverageRepository,
    SourceFileRepository,
    SourceFileService,
    SourceTimeCoverageRepository,
)
from guardianbackend.imports import (
    FirestoreImportRunRepository,
    FirestoreImportShardRepository,
    ImportProcessingDispatcher,
    ImportRunRepository,
    ImportService,
    ImportShardRepository,
    ImportWorkerService,
    InMemoryImportRunRepository,
    InMemoryImportShardRepository,
    build_import_processing_dispatcher,
)
from guardianbackend.sources import (
    FirestoreOwnedSourceRepository,
    FirestoreSourceTypeRepository,
    InMemoryOwnedSourceRepository,
    InMemorySourceTypeRepository,
    OwnedSourceService,
)
from guardianbackend.storage import ObjectStore, build_object_store
from guardianbackend.users import (
    AppUser,
    AuthenticatedUser,
    FirestoreUserRepository,
    InMemoryUserRepository,
    UserRepository,
    UserService,
)
from guardianbackend.vm import (
    ApprovedSourceMirrorService,
    CompiledOutputSyncService,
    CompilerSourceSyncService,
    FirestoreVmRepository,
    InMemoryVmRepository,
    UserBootstrapDispatcher,
    UserBootstrapService,
    VmAccessService,
    VmRepository,
    build_user_bootstrap_dispatcher,
)

security = HTTPBearer(auto_error=False)


def get_settings(request: Request) -> Settings:
    return cast(Settings, request.app.state.settings)


def _get_or_build_user_repository(
    request: Request,
) -> UserRepository:
    existing = getattr(request.app.state, "user_repository", None)
    if existing is not None:
        return cast(UserRepository, existing)
    settings = get_settings(request)
    client = build_firestore_client(settings)
    repository: UserRepository
    if client is None:
        repository = InMemoryUserRepository()
    else:
        repository = FirestoreUserRepository(client, settings.firestore_users_collection)
    request.app.state.user_repository = repository
    return repository


def _get_or_build_source_repositories(
    request: Request,
) -> tuple[
    FirestoreOwnedSourceRepository | InMemoryOwnedSourceRepository,
    FirestoreSourceTypeRepository | InMemorySourceTypeRepository,
]:
    owned_source_repository = getattr(request.app.state, "owned_source_repository", None)
    source_type_repository = getattr(request.app.state, "source_type_repository", None)
    if owned_source_repository is not None and source_type_repository is not None:
        return (
            cast(
                FirestoreOwnedSourceRepository | InMemoryOwnedSourceRepository,
                owned_source_repository,
            ),
            cast(
                FirestoreSourceTypeRepository | InMemorySourceTypeRepository,
                source_type_repository,
            ),
        )

    settings = get_settings(request)
    client = build_firestore_client(settings)
    built_owned_source_repository: FirestoreOwnedSourceRepository | InMemoryOwnedSourceRepository
    built_source_type_repository: FirestoreSourceTypeRepository | InMemorySourceTypeRepository
    if client is None:
        built_owned_source_repository = InMemoryOwnedSourceRepository()
        built_source_type_repository = InMemorySourceTypeRepository()
    else:
        built_owned_source_repository = FirestoreOwnedSourceRepository(
            client, settings.firestore_owned_sources_collection
        )
        built_source_type_repository = FirestoreSourceTypeRepository(
            client, settings.firestore_source_types_collection
        )
    request.app.state.owned_source_repository = built_owned_source_repository
    request.app.state.source_type_repository = built_source_type_repository
    return built_owned_source_repository, built_source_type_repository


def _get_or_build_vm_repository(request: Request) -> VmRepository:
    existing = getattr(request.app.state, "vm_repository", None)
    if existing is not None:
        return cast(VmRepository, existing)
    settings = get_settings(request)
    client = build_firestore_client(settings)
    repository: VmRepository
    if client is None:
        repository = InMemoryVmRepository()
    else:
        repository = FirestoreVmRepository(client, settings.firestore_vms_collection)
    request.app.state.vm_repository = repository
    return repository


def _get_or_build_user_service(request: Request) -> UserService:
    existing = getattr(request.app.state, "user_service", None)
    if isinstance(existing, UserService):
        return existing
    repository = _get_or_build_user_repository(request)
    service = UserService(repository, get_settings(request))
    request.app.state.user_service = service
    return service


def _get_or_build_object_store(request: Request) -> ObjectStore:
    existing = getattr(request.app.state, "object_store", None)
    if existing is not None:
        return cast(ObjectStore, existing)
    settings = get_settings(request)
    object_store = build_object_store(settings)
    request.app.state.object_store = object_store
    return object_store


def _get_or_build_import_processing_dispatcher(
    request: Request,
) -> ImportProcessingDispatcher:
    existing = getattr(request.app.state, "import_processing_dispatcher", None)
    if existing is not None:
        return cast(ImportProcessingDispatcher, existing)
    settings = get_settings(request)
    dispatcher = build_import_processing_dispatcher(settings)
    request.app.state.import_processing_dispatcher = dispatcher
    return dispatcher


def _get_or_build_source_service(request: Request) -> OwnedSourceService:
    existing = getattr(request.app.state, "source_service", None)
    if isinstance(existing, OwnedSourceService):
        return existing
    owned_source_repository, source_type_repository = _get_or_build_source_repositories(request)
    service = OwnedSourceService(owned_source_repository, source_type_repository)
    request.app.state.source_service = service
    return service


def _get_or_build_import_service(request: Request) -> ImportService:
    existing = getattr(request.app.state, "import_service", None)
    if isinstance(existing, ImportService):
        return existing
    settings = get_settings(request)
    client = build_firestore_client(settings)
    import_run_repository: ImportRunRepository
    import_shard_repository: ImportShardRepository
    owned_source_repository, _ = _get_or_build_source_repositories(request)
    source_file_service = _get_or_build_source_file_service(request)
    if client is None:
        import_run_repository = InMemoryImportRunRepository()
        import_shard_repository = InMemoryImportShardRepository()
    else:
        import_run_repository = FirestoreImportRunRepository(
            client, settings.firestore_import_runs_collection
        )
        import_shard_repository = FirestoreImportShardRepository(
            client, settings.firestore_import_shards_collection
        )
    service = ImportService(
        import_run_repository,
        import_shard_repository,
        owned_source_repository,
        source_file_service,
        _get_or_build_import_processing_dispatcher(request),
    )
    request.app.state.import_service = service
    return service


def _get_or_build_import_worker_service(request: Request) -> ImportWorkerService:
    existing = getattr(request.app.state, "import_worker_service", None)
    if isinstance(existing, ImportWorkerService):
        return existing

    settings = get_settings(request)
    client = build_firestore_client(settings)
    owned_source_repository, _ = _get_or_build_source_repositories(request)
    source_file_service = _get_or_build_source_file_service(request)
    import_run_repository: ImportRunRepository
    import_shard_repository: ImportShardRepository
    if client is None:
        import_run_repository = InMemoryImportRunRepository()
        import_shard_repository = InMemoryImportShardRepository()
    else:
        import_run_repository = FirestoreImportRunRepository(
            client, settings.firestore_import_runs_collection
        )
        import_shard_repository = FirestoreImportShardRepository(
            client, settings.firestore_import_shards_collection
        )
    service = ImportWorkerService(
        settings,
        import_run_repository,
        import_shard_repository,
        owned_source_repository,
        source_file_service,
        _get_or_build_object_store(request),
        _get_or_build_compiler_source_sync_service(request),
        _get_or_build_approved_source_mirror_service(request),
    )
    request.app.state.import_worker_service = service
    return service


def _get_or_build_user_bootstrap_dispatcher(request: Request) -> UserBootstrapDispatcher:
    existing = getattr(request.app.state, "user_bootstrap_dispatcher", None)
    if existing is not None:
        return cast(UserBootstrapDispatcher, existing)
    settings = get_settings(request)
    dispatcher = build_user_bootstrap_dispatcher(settings)
    request.app.state.user_bootstrap_dispatcher = dispatcher
    return dispatcher


def _get_or_build_user_bootstrap_service(request: Request) -> UserBootstrapService:
    existing = getattr(request.app.state, "user_bootstrap_service", None)
    if isinstance(existing, UserBootstrapService):
        return existing
    service = UserBootstrapService(
        get_settings(request),
        _get_or_build_user_repository(request),
        _get_or_build_vm_repository(request),
        _get_or_build_user_service(request),
    )
    request.app.state.user_bootstrap_service = service
    return service


def _get_or_build_compiled_output_sync_service(request: Request) -> CompiledOutputSyncService:
    existing = getattr(request.app.state, "compiled_output_sync_service", None)
    if isinstance(existing, CompiledOutputSyncService):
        return existing
    service = CompiledOutputSyncService(
        get_settings(request),
        _get_or_build_user_repository(request),
        _get_or_build_vm_repository(request),
    )
    request.app.state.compiled_output_sync_service = service
    return service


def _get_or_build_compiler_source_sync_service(request: Request) -> CompilerSourceSyncService:
    existing = getattr(request.app.state, "compiler_source_sync_service", None)
    if isinstance(existing, CompilerSourceSyncService):
        return existing
    settings = get_settings(request)
    client = build_firestore_client(settings)
    owned_source_repository, _ = _get_or_build_source_repositories(request)
    source_file_repository: SourceFileRepository
    if client is None:
        source_file_repository = InMemorySourceFileRepository()
    else:
        source_file_repository = FirestoreSourceFileRepository(
            client,
            settings.firestore_source_files_collection,
            settings.firestore_source_file_hash_index_collection,
        )
    service = CompilerSourceSyncService(
        settings,
        _get_or_build_user_repository(request),
        _get_or_build_vm_repository(request),
        owned_source_repository,
        source_file_repository,
        _get_or_build_object_store(request),
    )
    request.app.state.compiler_source_sync_service = service
    return service


def _get_or_build_approved_source_mirror_service(request: Request) -> ApprovedSourceMirrorService:
    existing = getattr(request.app.state, "approved_source_mirror_service", None)
    if isinstance(existing, ApprovedSourceMirrorService):
        return existing
    service = ApprovedSourceMirrorService(
        get_settings(request),
        _get_or_build_user_repository(request),
        _get_or_build_vm_repository(request),
    )
    request.app.state.approved_source_mirror_service = service
    return service


def _get_or_build_vm_access_service(request: Request) -> VmAccessService:
    existing = getattr(request.app.state, "vm_access_service", None)
    if isinstance(existing, VmAccessService):
        return existing
    service = VmAccessService(_get_or_build_vm_repository(request))
    request.app.state.vm_access_service = service
    return service


def _get_or_build_source_file_service(request: Request) -> SourceFileService:
    existing = getattr(request.app.state, "source_file_service", None)
    if isinstance(existing, SourceFileService):
        return existing

    settings = get_settings(request)
    client = build_firestore_client(settings)
    owned_source_repository, _ = _get_or_build_source_repositories(request)
    source_file_repository: SourceFileRepository
    source_time_coverage_repository: SourceTimeCoverageRepository
    if client is None:
        source_file_repository = InMemorySourceFileRepository()
        source_time_coverage_repository = InMemorySourceTimeCoverageRepository()
    else:
        source_file_repository = FirestoreSourceFileRepository(
            client,
            settings.firestore_source_files_collection,
            settings.firestore_source_file_hash_index_collection,
        )
        source_time_coverage_repository = FirestoreSourceTimeCoverageRepository(
            client,
            settings.firestore_source_time_coverage_collection,
        )
    service = SourceFileService(
        source_file_repository,
        source_time_coverage_repository,
        owned_source_repository,
    )
    request.app.state.source_file_service = service
    return service


def get_user_service(request: Request) -> UserService:
    return _get_or_build_user_service(request)


def get_source_service(request: Request) -> OwnedSourceService:
    return _get_or_build_source_service(request)


def get_import_service(request: Request) -> ImportService:
    return _get_or_build_import_service(request)


def get_object_store(request: Request) -> ObjectStore:
    return _get_or_build_object_store(request)


def get_source_file_service(request: Request) -> SourceFileService:
    return _get_or_build_source_file_service(request)


def get_import_worker_service(request: Request) -> ImportWorkerService:
    return _get_or_build_import_worker_service(request)


def get_user_bootstrap_service(request: Request) -> UserBootstrapService:
    return _get_or_build_user_bootstrap_service(request)


def get_vm_access_service(request: Request) -> VmAccessService:
    return _get_or_build_vm_access_service(request)


def get_compiled_output_sync_service(request: Request) -> CompiledOutputSyncService:
    return _get_or_build_compiled_output_sync_service(request)


def get_compiler_source_sync_service(request: Request) -> CompilerSourceSyncService:
    return _get_or_build_compiler_source_sync_service(request)


def get_approved_source_mirror_service(request: Request) -> ApprovedSourceMirrorService:
    return _get_or_build_approved_source_mirror_service(request)


def require_authenticated_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(security)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> AuthenticatedUser:
    if credentials is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")

    token = credentials.credentials
    if settings.smoke_bearer_token and token == settings.smoke_bearer_token:
        return AuthenticatedUser(
            user_id=settings.smoke_user_id,
            email=settings.smoke_user_email,
            name="Guardian Smoke",
            auth_provider="smoke",
        )

    if settings.dummy_user_signing_key:
        user = verify_dummy_user_token(token, settings.dummy_user_signing_key)
        if user is not None:
            return user

    google_user = verify_google_user_token(
        token,
        client_ids=settings.google_oauth_client_id_list,
        allowed_emails=settings.allowed_google_email_list,
    )
    if google_user is not None:
        return google_user

    raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid bearer token")


def require_internal_worker_token(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(security)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> None:
    if settings.internal_worker_token is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Internal worker token is not configured",
        )
    if credentials is None or credentials.credentials != settings.internal_worker_token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid internal worker token",
        )


def get_current_app_user(
    request: Request,
    user_service: Annotated[UserService, Depends(get_user_service)],
    authenticated_user: Annotated[AuthenticatedUser, Depends(require_authenticated_user)],
) -> AppUser:
    user = user_service.ensure_user_for_auth(authenticated_user)
    if user_service.should_bootstrap_user(user):
        user = user_service.mark_bootstrap_requested(user.user_id)
        dispatcher = _get_or_build_user_bootstrap_dispatcher(request)
        try:
            dispatcher.dispatch_user_bootstrap(user.user_id)
        except Exception:
            return user
    return user
