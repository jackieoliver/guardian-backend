from collections.abc import Iterable
from typing import Protocol, cast

from google.cloud import firestore

from .models import OwnedSource, SourceType


class SourceTypeRepository(Protocol):
    def get_source_type(self, source_id: str) -> SourceType | None: ...

    def list_source_types(self) -> list[SourceType]: ...

    def save_source_type(self, source_type: SourceType) -> SourceType: ...


class OwnedSourceRepository(Protocol):
    def get_owned_source(self, owned_source_id: str) -> OwnedSource | None: ...

    def list_owned_sources_for_user(self, user_id: str) -> list[OwnedSource]: ...

    def save_owned_source(self, owned_source: OwnedSource) -> OwnedSource: ...

    def delete_owned_source(self, owned_source_id: str) -> None: ...


class InMemorySourceTypeRepository:
    def __init__(self) -> None:
        self._source_types: dict[str, SourceType] = {}

    def get_source_type(self, source_id: str) -> SourceType | None:
        return self._source_types.get(source_id)

    def list_source_types(self) -> list[SourceType]:
        return list(self._source_types.values())

    def save_source_type(self, source_type: SourceType) -> SourceType:
        self._source_types[source_type.source_id] = source_type
        return source_type


class InMemoryOwnedSourceRepository:
    def __init__(self) -> None:
        self._sources: dict[str, OwnedSource] = {}

    def get_owned_source(self, owned_source_id: str) -> OwnedSource | None:
        return self._sources.get(owned_source_id)

    def list_owned_sources_for_user(self, user_id: str) -> list[OwnedSource]:
        return [source for source in self._sources.values() if source.user_id == user_id]

    def save_owned_source(self, owned_source: OwnedSource) -> OwnedSource:
        self._sources[owned_source.owned_source_id] = owned_source
        return owned_source

    def delete_owned_source(self, owned_source_id: str) -> None:
        self._sources.pop(owned_source_id, None)


class FirestoreSourceTypeRepository:
    def __init__(self, client: firestore.Client, collection_name: str) -> None:
        self._collection = client.collection(collection_name)

    def get_source_type(self, source_id: str) -> SourceType | None:
        snapshot = cast(firestore.DocumentSnapshot, self._collection.document(source_id).get())
        if not snapshot.exists:
            return None
        data = snapshot.to_dict()
        if data is None:
            return None
        return SourceType.model_validate(data)

    def list_source_types(self) -> list[SourceType]:
        docs: Iterable[firestore.DocumentSnapshot] = self._collection.stream()
        return [
            SourceType.model_validate(doc.to_dict())
            for doc in docs
            if doc.to_dict() is not None
        ]

    def save_source_type(self, source_type: SourceType) -> SourceType:
        self._collection.document(source_type.source_id).set(source_type.model_dump(mode="python"))
        return source_type


class FirestoreOwnedSourceRepository:
    def __init__(self, client: firestore.Client, collection_name: str) -> None:
        self._collection = client.collection(collection_name)

    def get_owned_source(self, owned_source_id: str) -> OwnedSource | None:
        snapshot = cast(
            firestore.DocumentSnapshot,
            self._collection.document(owned_source_id).get(),
        )
        if not snapshot.exists:
            return None
        data = snapshot.to_dict()
        if data is None:
            return None
        return OwnedSource.model_validate(data)

    def list_owned_sources_for_user(self, user_id: str) -> list[OwnedSource]:
        docs = self._collection.where("user_id", "==", user_id).stream()
        return [
            OwnedSource.model_validate(doc.to_dict())
            for doc in docs
            if doc.to_dict() is not None
        ]

    def save_owned_source(self, owned_source: OwnedSource) -> OwnedSource:
        self._collection.document(owned_source.owned_source_id).set(
            owned_source.model_dump(mode="python")
        )
        return owned_source

    def delete_owned_source(self, owned_source_id: str) -> None:
        self._collection.document(owned_source_id).delete()
