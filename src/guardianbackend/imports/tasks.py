import json
from typing import Protocol

from google.cloud import tasks_v2
from google.cloud.tasks_v2.types import HttpMethod, HttpRequest, Task

from guardianbackend.config import Settings


class ImportProcessingDispatcher(Protocol):
    def dispatch_import_shard(self, *, import_run_id: str, import_shard_id: str) -> None: ...


class NoopImportProcessingDispatcher:
    def dispatch_import_shard(self, *, import_run_id: str, import_shard_id: str) -> None:
        del import_run_id, import_shard_id


class MisconfiguredImportProcessingDispatcher:
    def dispatch_import_shard(self, *, import_run_id: str, import_shard_id: str) -> None:
        del import_run_id, import_shard_id
        raise RuntimeError("cloud tasks dispatch is not configured")


class CloudTasksImportProcessingDispatcher:
    def __init__(self, settings: Settings) -> None:
        if (
            settings.gcp_project_id is None
            or settings.cloud_tasks_location is None
            or settings.cloud_tasks_queue is None
            or settings.worker_cloud_run_url is None
            or settings.internal_worker_token is None
        ):
            raise RuntimeError("cloud tasks dispatcher requires full worker/task configuration")
        self._client = tasks_v2.CloudTasksClient()
        self._worker_cloud_run_url = settings.worker_cloud_run_url
        self._internal_worker_token = settings.internal_worker_token
        self._queue_path = self._client.queue_path(
            settings.gcp_project_id,
            settings.cloud_tasks_location,
            settings.cloud_tasks_queue,
        )

    def dispatch_import_shard(self, *, import_run_id: str, import_shard_id: str) -> None:
        payload = json.dumps(
            {"import_run_id": import_run_id, "import_shard_id": import_shard_id}
        ).encode("utf-8")
        task = Task(
            http_request=HttpRequest(
                http_method=HttpMethod.POST,
                url=f"{self._worker_cloud_run_url.rstrip('/')}/internal/process-import-shard",
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {self._internal_worker_token}",
                },
                body=payload,
            )
        )
        self._client.create_task(parent=self._queue_path, task=task)


def build_import_processing_dispatcher(settings: Settings) -> ImportProcessingDispatcher:
    if not settings.uses_cloud:
        return NoopImportProcessingDispatcher()
    if (
        settings.gcp_project_id
        and settings.cloud_tasks_location
        and settings.cloud_tasks_queue
        and settings.worker_cloud_run_url
        and settings.internal_worker_token
    ):
        return CloudTasksImportProcessingDispatcher(settings)
    return MisconfiguredImportProcessingDispatcher()
