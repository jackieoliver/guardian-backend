from collections.abc import Iterable
from typing import Protocol, cast

from google.cloud import firestore

from .models import ImportRun, ImportShard


class ImportRunRepository(Protocol):
    def get_import_run(self, import_run_id: str) -> ImportRun | None: ...

    def list_import_runs_for_user(
        self,
        user_id: str,
        *,
        limit: int | None = None,
    ) -> list[ImportRun]: ...

    def list_import_runs_for_owned_source(
        self,
        owned_source_id: str,
        *,
        limit: int | None = None,
    ) -> list[ImportRun]: ...

    def save_import_run(self, import_run: ImportRun) -> ImportRun: ...


class ImportShardRepository(Protocol):
    def get_import_shard(self, import_shard_id: str) -> ImportShard | None: ...

    def list_import_shards_for_run(self, import_run_id: str) -> list[ImportShard]: ...

    def claim_uploaded_shard(self, import_shard_id: str) -> ImportShard | None: ...

    def save_import_shard(self, import_shard: ImportShard) -> ImportShard: ...


class InMemoryImportRunRepository:
    def __init__(self) -> None:
        self._runs: dict[str, ImportRun] = {}

    def get_import_run(self, import_run_id: str) -> ImportRun | None:
        return self._runs.get(import_run_id)

    def list_import_runs_for_user(
        self,
        user_id: str,
        *,
        limit: int | None = None,
    ) -> list[ImportRun]:
        runs = [run for run in self._runs.values() if run.user_id == user_id]
        if limit is None:
            return runs
        return runs[:limit]

    def list_import_runs_for_owned_source(
        self,
        owned_source_id: str,
        *,
        limit: int | None = None,
    ) -> list[ImportRun]:
        runs = [run for run in self._runs.values() if run.owned_source_id == owned_source_id]
        if limit is None:
            return runs
        return runs[:limit]

    def save_import_run(self, import_run: ImportRun) -> ImportRun:
        self._runs[import_run.import_run_id] = import_run
        return import_run


class InMemoryImportShardRepository:
    def __init__(self) -> None:
        self._shards: dict[str, ImportShard] = {}

    def get_import_shard(self, import_shard_id: str) -> ImportShard | None:
        return self._shards.get(import_shard_id)

    def list_import_shards_for_run(self, import_run_id: str) -> list[ImportShard]:
        return [shard for shard in self._shards.values() if shard.import_run_id == import_run_id]

    def claim_uploaded_shard(self, import_shard_id: str) -> ImportShard | None:
        shard = self._shards.get(import_shard_id)
        if shard is None or shard.status != "uploaded":
            return None
        claimed = shard.model_copy(update={"status": "processing"})
        self._shards[import_shard_id] = claimed
        return claimed

    def save_import_shard(self, import_shard: ImportShard) -> ImportShard:
        self._shards[import_shard.import_shard_id] = import_shard
        return import_shard


class FirestoreImportRunRepository:
    def __init__(self, client: firestore.Client, collection_name: str) -> None:
        self._collection = client.collection(collection_name)

    def get_import_run(self, import_run_id: str) -> ImportRun | None:
        snapshot = cast(firestore.DocumentSnapshot, self._collection.document(import_run_id).get())
        if not snapshot.exists:
            return None
        data = snapshot.to_dict()
        if data is None:
            return None
        return ImportRun.model_validate(data)

    def list_import_runs_for_user(
        self,
        user_id: str,
        *,
        limit: int | None = None,
    ) -> list[ImportRun]:
        query = self._collection.where("user_id", "==", user_id)
        if limit is not None:
            query = query.limit(limit)
        docs: Iterable[firestore.DocumentSnapshot] = query.stream()
        return [
            ImportRun.model_validate(doc.to_dict())
            for doc in docs
            if doc.to_dict() is not None
        ]

    def list_import_runs_for_owned_source(
        self,
        owned_source_id: str,
        *,
        limit: int | None = None,
    ) -> list[ImportRun]:
        query = self._collection.where("owned_source_id", "==", owned_source_id)
        if limit is not None:
            query = query.limit(limit)
        docs: Iterable[firestore.DocumentSnapshot] = query.stream()
        return [
            ImportRun.model_validate(doc.to_dict())
            for doc in docs
            if doc.to_dict() is not None
        ]

    def save_import_run(self, import_run: ImportRun) -> ImportRun:
        self._collection.document(import_run.import_run_id).set(import_run.model_dump(mode="python"))
        return import_run


class FirestoreImportShardRepository:
    def __init__(self, client: firestore.Client, collection_name: str) -> None:
        self._client = client
        self._collection = client.collection(collection_name)

    def get_import_shard(self, import_shard_id: str) -> ImportShard | None:
        snapshot = cast(
            firestore.DocumentSnapshot,
            self._collection.document(import_shard_id).get(),
        )
        if not snapshot.exists:
            return None
        data = snapshot.to_dict()
        if data is None:
            return None
        return ImportShard.model_validate(data)

    def list_import_shards_for_run(self, import_run_id: str) -> list[ImportShard]:
        docs: Iterable[firestore.DocumentSnapshot] = (
            self._collection.where("import_run_id", "==", import_run_id).stream()
        )
        return [
            ImportShard.model_validate(doc.to_dict())
            for doc in docs
            if doc.to_dict() is not None
        ]

    def claim_uploaded_shard(self, import_shard_id: str) -> ImportShard | None:
        document = self._collection.document(import_shard_id)

        @firestore.transactional
        def _claim(transaction: firestore.Transaction) -> ImportShard | None:
            snapshot = cast(firestore.DocumentSnapshot, document.get(transaction=transaction))
            if not snapshot.exists:
                return None
            data = snapshot.to_dict()
            if data is None:
                return None
            shard = ImportShard.model_validate(data)
            if shard.status != "uploaded":
                return None
            claimed = shard.model_copy(update={"status": "processing"})
            transaction.set(document, claimed.model_dump(mode="python"))
            return claimed

        transaction = self._client.transaction()
        claimed = _claim(transaction)
        if claimed is None:
            return None
        return cast(ImportShard, claimed)

    def save_import_shard(self, import_shard: ImportShard) -> ImportShard:
        self._collection.document(import_shard.import_shard_id).set(
            import_shard.model_dump(mode="python")
        )
        return import_shard
