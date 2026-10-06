from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    environment: str = "development"
    api_host: str = "0.0.0.0"
    api_port: int = 8000
    local_storage_root: str = ".guardian-data/recordings"
    gcp_project_id: str | None = None
    gcs_bucket_name: str | None = None
    gcs_bucket_region: str = "us-west2"
    gcs_files_prefix: str = "files"
    gcs_transport_prefix: str = "tmp-imports"
    gcs_vm_session_prefix: str = "vm-session-logs"
    worker_cloud_run_url: str | None = None
    firestore_database: str = "(default)"
    firestore_import_runs_collection: str = "import_runs"
    firestore_import_shards_collection: str = "import_shards"
    firestore_source_types_collection: str = "source_types"
    firestore_owned_sources_collection: str = "owned_sources"
    firestore_source_files_collection: str = "source_files"
    firestore_source_file_hash_index_collection: str = "source_file_hash_index"
    firestore_source_time_coverage_collection: str = "source_time_coverage"
    firestore_journals_collection: str = "journals"
    firestore_journal_entries_collection: str = "journal_entries"
    firestore_journal_branches_collection: str = "journal_branches"
    firestore_journal_messages_collection: str = "journal_messages"
    firestore_journal_runtime_sessions_collection: str = "journal_runtime_sessions"
    firestore_users_collection: str = "users"
    firestore_vms_collection: str = "vms"
    firestore_vm_sessions_collection: str = "vm_sessions"
    smoke_bearer_token: str | None = None
    smoke_user_id: str = "guardian-smoke-user"
    smoke_user_email: str = "guardian-smoke@local"
    dummy_user_signing_key: str | None = None
    google_oauth_client_ids: str | None = None
    allowed_google_emails: str | None = None
    internal_worker_token: str | None = None
    cloud_tasks_location: str | None = None
    cloud_tasks_queue: str | None = None
    cloud_tasks_user_bootstrap_queue: str | None = None
    cloud_tasks_service_account_email: str | None = None
    import_worker_file_concurrency: int = 16
    vm_bootstrap_ssh_private_key: str | None = None
    default_runtime_vm_id: str | None = "guardian-vm-01"
    default_compiler_vm_id: str | None = "guardian-vm-lifestream-compiler"
    runtime_workspace_root: str = "/srv/guardian-runtime"
    compiler_workspace_root: str = "/srv/guardian-compiler"

    model_config = SettingsConfigDict(env_prefix="GUARDIAN_", extra="ignore")

    @property
    def uses_cloud(self) -> bool:
        return bool(self.gcp_project_id and self.gcs_bucket_name)

    @property
    def google_oauth_client_id_list(self) -> list[str]:
        if not self.google_oauth_client_ids:
            return []
        return [
            item.strip()
            for item in self.google_oauth_client_ids.split(",")
            if item.strip()
        ]

    @property
    def allowed_google_email_list(self) -> list[str]:
        if not self.allowed_google_emails:
            return []
        return [
            item.strip().lower()
            for item in self.allowed_google_emails.split(",")
            if item.strip()
        ]


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
