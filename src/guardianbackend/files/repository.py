from collections.abc import Iterable
from typing import Protocol, cast

from google.cloud import firestore

from guardianbackend.domain import utc_now

from .models import (
    SourceFile,
    SourceFileHashIndexEntry,
    SourceTimeCoverageRecord,
    hours_in_year,
)


def build_source_file_hash_index_id(owned_source_id: str, content_hash: str) -> str:
    return f"{owned_source_id}:{content_hash}"


def build_source_time_coverage_id(owned_source_id: str, year: int) -> str:
    return f"{owned_source_id}:{year}"


class SourceFileRepository(Protocol):
    def get_source_file(self, source_file_id: str) -> SourceFile | None: ...

    def list_source_files_for_owned_source(
        self,
        owned_source_id: str,
        *,
        limit: int | None = None,
    ) -> list[SourceFile]: ...

    def find_source_files_by_hashes(
        self,
        owned_source_id: str,
        content_hashes: set[str],
    ) -> list[SourceFile]: ...

    def save_source_file(self, source_file: SourceFile) -> SourceFile: ...

    def save_source_files(self, source_files: list[SourceFile]) -> list[SourceFile]: ...

    def delete_source_file(self, source_file_id: str) -> None: ...


class SourceTimeCoverageRepository(Protocol):
    def get_source_time_coverage(
        self,
        owned_source_id: str,
        year: int,
    ) -> SourceTimeCoverageRecord | None: ...

    def save_source_time_coverage(
        self,
        coverage_record: SourceTimeCoverageRecord,
    ) -> SourceTimeCoverageRecord: ...

    def apply_hour_deltas(
        self,
        *,
        user_id: str,
        owned_source_id: str,
        year: int,
        hour_deltas: dict[int, int],
    ) -> SourceTimeCoverageRecord: ...


class InMemorySourceFileRepository:
    def __init__(self) -> None:
        self._source_files: dict[str, SourceFile] = {}
        self._by_hash_index: dict[str, str] = {}

    def get_source_file(self, source_file_id: str) -> SourceFile | None:
        return self._source_files.get(source_file_id)

    def list_source_files_for_owned_source(
        self,
        owned_source_id: str,
        *,
        limit: int | None = None,
    ) -> list[SourceFile]:
        results = [
            source_file
            for source_file in self._source_files.values()
            if source_file.owned_source_id == owned_source_id
        ]
        if limit is None:
            return results
        return results[:limit]

    def find_source_files_by_hashes(
        self,
        owned_source_id: str,
        content_hashes: set[str],
    ) -> list[SourceFile]:
        matches: list[SourceFile] = []
        for content_hash in content_hashes:
            source_file_id = self._by_hash_index.get(
                build_source_file_hash_index_id(owned_source_id, content_hash)
            )
            if source_file_id is None:
                continue
            source_file = self._source_files.get(source_file_id)
            if source_file is not None:
                matches.append(source_file)
        return matches

    def save_source_file(self, source_file: SourceFile) -> SourceFile:
        self._source_files[source_file.source_file_id] = source_file
        self._by_hash_index[
            build_source_file_hash_index_id(source_file.owned_source_id, source_file.content_hash)
        ] = source_file.source_file_id
        return source_file

    def save_source_files(self, source_files: list[SourceFile]) -> list[SourceFile]:
        for source_file in source_files:
            self._source_files[source_file.source_file_id] = source_file
            self._by_hash_index[
                build_source_file_hash_index_id(
                    source_file.owned_source_id,
                    source_file.content_hash,
                )
            ] = source_file.source_file_id
        return source_files

    def delete_source_file(self, source_file_id: str) -> None:
        source_file = self._source_files.pop(source_file_id, None)
        if source_file is None:
            return
        self._by_hash_index.pop(
            build_source_file_hash_index_id(
                source_file.owned_source_id,
                source_file.content_hash,
            ),
            None,
        )


class FirestoreSourceFileRepository:
    def __init__(
        self,
        client: firestore.Client,
        collection_name: str,
        hash_index_collection_name: str,
    ) -> None:
        self._client = client
        self._collection = client.collection(collection_name)
        self._hash_index_collection = client.collection(hash_index_collection_name)

    def get_source_file(self, source_file_id: str) -> SourceFile | None:
        snapshot = cast(firestore.DocumentSnapshot, self._collection.document(source_file_id).get())
        if not snapshot.exists:
            return None
        data = snapshot.to_dict()
        if data is None:
            return None
        return SourceFile.model_validate(data)

    def list_source_files_for_owned_source(
        self,
        owned_source_id: str,
        *,
        limit: int | None = None,
    ) -> list[SourceFile]:
        query = self._collection.where("owned_source_id", "==", owned_source_id)
        if limit is not None:
            query = query.limit(limit)
        docs: Iterable[firestore.DocumentSnapshot] = query.stream()
        return [
            SourceFile.model_validate(doc.to_dict())
            for doc in docs
            if doc.to_dict() is not None
        ]

    def find_source_files_by_hashes(
        self,
        owned_source_id: str,
        content_hashes: set[str],
    ) -> list[SourceFile]:
        if not content_hashes:
            return []
        index_refs = [
            self._hash_index_collection.document(
                build_source_file_hash_index_id(owned_source_id, content_hash)
            )
            for content_hash in content_hashes
        ]
        index_entries = [
            SourceFileHashIndexEntry.model_validate(snapshot.to_dict())
            for snapshot in self._client.get_all(index_refs)
            if snapshot.exists and snapshot.to_dict() is not None
        ]
        source_file_refs = [
            self._collection.document(index_entry.source_file_id) for index_entry in index_entries
        ]
        return [
            SourceFile.model_validate(snapshot.to_dict())
            for snapshot in self._client.get_all(source_file_refs)
            if snapshot.exists and snapshot.to_dict() is not None
        ]

    def save_source_file(self, source_file: SourceFile) -> SourceFile:
        self._collection.document(source_file.source_file_id).set(source_file.model_dump(mode="python"))
        hash_index_entry = SourceFileHashIndexEntry(
            index_id=build_source_file_hash_index_id(
                source_file.owned_source_id,
                source_file.content_hash,
            ),
            owned_source_id=source_file.owned_source_id,
            content_hash=source_file.content_hash,
            source_file_id=source_file.source_file_id,
            object_path=source_file.object_path,
            bucket=source_file.bucket,
            updated_at=source_file.updated_at,
        )
        self._hash_index_collection.document(hash_index_entry.index_id).set(
            hash_index_entry.model_dump(mode="python")
        )
        return source_file

    def save_source_files(self, source_files: list[SourceFile]) -> list[SourceFile]:
        if not source_files:
            return []
        chunk_size = 400
        for start in range(0, len(source_files), chunk_size):
            batch = self._collection._client.batch()  # noqa: SLF001
            chunk = source_files[start : start + chunk_size]
            for source_file in chunk:
                batch.set(
                    self._collection.document(source_file.source_file_id),
                    source_file.model_dump(mode="python"),
                )
                hash_index_entry = SourceFileHashIndexEntry(
                    index_id=build_source_file_hash_index_id(
                        source_file.owned_source_id,
                        source_file.content_hash,
                    ),
                    owned_source_id=source_file.owned_source_id,
                    content_hash=source_file.content_hash,
                    source_file_id=source_file.source_file_id,
                    object_path=source_file.object_path,
                    bucket=source_file.bucket,
                    updated_at=source_file.updated_at,
                )
                batch.set(
                    self._hash_index_collection.document(hash_index_entry.index_id),
                    hash_index_entry.model_dump(mode="python"),
                )
            batch.commit()
        return source_files

    def delete_source_file(self, source_file_id: str) -> None:
        source_file = self.get_source_file(source_file_id)
        self._collection.document(source_file_id).delete()
        if source_file is not None:
            self._hash_index_collection.document(
                build_source_file_hash_index_id(
                    source_file.owned_source_id,
                    source_file.content_hash,
                )
            ).delete()


class InMemorySourceTimeCoverageRepository:
    def __init__(self) -> None:
        self._coverage_records: dict[str, SourceTimeCoverageRecord] = {}

    def get_source_time_coverage(
        self,
        owned_source_id: str,
        year: int,
    ) -> SourceTimeCoverageRecord | None:
        return self._coverage_records.get(build_source_time_coverage_id(owned_source_id, year))

    def save_source_time_coverage(
        self,
        coverage_record: SourceTimeCoverageRecord,
    ) -> SourceTimeCoverageRecord:
        self._coverage_records[coverage_record.coverage_id] = coverage_record
        return coverage_record

    def apply_hour_deltas(
        self,
        *,
        user_id: str,
        owned_source_id: str,
        year: int,
        hour_deltas: dict[int, int],
    ) -> SourceTimeCoverageRecord:
        coverage_id = build_source_time_coverage_id(owned_source_id, year)
        coverage_record = self._coverage_records.get(coverage_id)
        now = utc_now()
        if coverage_record is None:
            coverage_record = SourceTimeCoverageRecord(
                coverage_id=coverage_id,
                user_id=user_id,
                owned_source_id=owned_source_id,
                year=year,
                hour_counts=[0] * hours_in_year(year),
                covered_hour_count=0,
                created_at=now,
                updated_at=now,
            )
        counts = list(coverage_record.hour_counts)
        for hour_index, delta in hour_deltas.items():
            if 0 <= hour_index < len(counts):
                counts[hour_index] = max(0, counts[hour_index] + delta)
        updated = coverage_record.model_copy(
            update={
                "hour_counts": counts,
                "covered_hour_count": sum(1 for count in counts if count > 0),
                "updated_at": now,
            }
        )
        self._coverage_records[coverage_id] = updated
        return updated


class FirestoreSourceTimeCoverageRepository:
    def __init__(self, client: firestore.Client, collection_name: str) -> None:
        self._collection = client.collection(collection_name)

    def get_source_time_coverage(
        self,
        owned_source_id: str,
        year: int,
    ) -> SourceTimeCoverageRecord | None:
        snapshot = cast(
            firestore.DocumentSnapshot,
            self._collection.document(build_source_time_coverage_id(owned_source_id, year)).get(),
        )
        if not snapshot.exists:
            return None
        data = snapshot.to_dict()
        if data is None:
            return None
        return SourceTimeCoverageRecord.model_validate(data)

    def save_source_time_coverage(
        self,
        coverage_record: SourceTimeCoverageRecord,
    ) -> SourceTimeCoverageRecord:
        self._collection.document(coverage_record.coverage_id).set(
            coverage_record.model_dump(mode="python")
        )
        return coverage_record

    def apply_hour_deltas(
        self,
        *,
        user_id: str,
        owned_source_id: str,
        year: int,
        hour_deltas: dict[int, int],
    ) -> SourceTimeCoverageRecord:
        coverage_id = build_source_time_coverage_id(owned_source_id, year)
        document_ref = self._collection.document(coverage_id)

        @firestore.transactional
        def _apply(
            transaction: firestore.Transaction,
        ) -> SourceTimeCoverageRecord:
            snapshot = cast(
                firestore.DocumentSnapshot,
                document_ref.get(transaction=transaction),
            )
            if snapshot.exists and snapshot.to_dict() is not None:
                coverage_record = SourceTimeCoverageRecord.model_validate(snapshot.to_dict())
            else:
                now = utc_now()
                coverage_record = SourceTimeCoverageRecord(
                    coverage_id=coverage_id,
                    user_id=user_id,
                    owned_source_id=owned_source_id,
                    year=year,
                    hour_counts=[0] * hours_in_year(year),
                    covered_hour_count=0,
                    created_at=now,
                    updated_at=now,
                )
            counts = list(coverage_record.hour_counts)
            for hour_index, delta in hour_deltas.items():
                if 0 <= hour_index < len(counts):
                    counts[hour_index] = max(0, counts[hour_index] + delta)
            updated = coverage_record.model_copy(
                update={
                    "hour_counts": counts,
                    "covered_hour_count": sum(1 for count in counts if count > 0),
                    "updated_at": utc_now(),
                }
            )
            transaction.set(document_ref, updated.model_dump(mode="python"))
            return updated

        return cast(
            SourceTimeCoverageRecord,
            _apply(self._collection._client.transaction()),  # noqa: SLF001
        )
