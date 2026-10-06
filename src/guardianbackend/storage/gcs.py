from pathlib import Path
from typing import Protocol, cast

import google.cloud.storage as gcs_storage

from guardianbackend.config import Settings


class ObjectStore(Protocol):
    def upload_bytes(
        self,
        *,
        bucket: str,
        object_path: str,
        data: bytes,
        content_type: str | None = None,
    ) -> None: ...

    def download_bytes(
        self,
        *,
        bucket: str,
        object_path: str,
    ) -> bytes: ...

    def delete_object(
        self,
        *,
        bucket: str,
        object_path: str,
    ) -> None: ...

    def object_exists(
        self,
        *,
        bucket: str,
        object_path: str,
    ) -> bool: ...


class LocalObjectStore:
    def __init__(self, root: Path) -> None:
        self._root = root

    def upload_bytes(
        self,
        *,
        bucket: str,
        object_path: str,
        data: bytes,
        content_type: str | None = None,
    ) -> None:
        del content_type
        path = self._root / bucket / object_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def download_bytes(
        self,
        *,
        bucket: str,
        object_path: str,
    ) -> bytes:
        return (self._root / bucket / object_path).read_bytes()

    def delete_object(
        self,
        *,
        bucket: str,
        object_path: str,
    ) -> None:
        path = self._root / bucket / object_path
        path.unlink(missing_ok=True)

    def object_exists(
        self,
        *,
        bucket: str,
        object_path: str,
    ) -> bool:
        return (self._root / bucket / object_path).exists()


class GCSObjectStore:
    def __init__(self, client: gcs_storage.Client) -> None:
        self._client = client

    def upload_bytes(
        self,
        *,
        bucket: str,
        object_path: str,
        data: bytes,
        content_type: str | None = None,
    ) -> None:
        blob = self._client.bucket(bucket).blob(object_path)
        blob.upload_from_string(data, content_type=content_type)

    def download_bytes(
        self,
        *,
        bucket: str,
        object_path: str,
    ) -> bytes:
        return cast(bytes, self._client.bucket(bucket).blob(object_path).download_as_bytes())

    def delete_object(
        self,
        *,
        bucket: str,
        object_path: str,
    ) -> None:
        self._client.bucket(bucket).blob(object_path).delete(if_generation_match=None)

    def object_exists(
        self,
        *,
        bucket: str,
        object_path: str,
    ) -> bool:
        return cast(bool, self._client.bucket(bucket).blob(object_path).exists())


def build_object_store(settings: Settings) -> ObjectStore:
    if settings.uses_cloud and settings.gcp_project_id is not None:
        return GCSObjectStore(gcs_storage.Client(project=settings.gcp_project_id))
    return LocalObjectStore(Path(settings.local_storage_root))
