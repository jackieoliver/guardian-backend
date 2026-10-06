from collections.abc import Iterable
from typing import Protocol, cast

from google.cloud import firestore

from .models import AppUser


class UserRepository(Protocol):
    def get_user(self, user_id: str) -> AppUser | None: ...

    def get_user_by_email(self, email: str) -> AppUser | None: ...

    def save_user(self, user: AppUser) -> AppUser: ...

    def list_users_for_vm(self, vm_id: str) -> list[AppUser]: ...


class InMemoryUserRepository:
    def __init__(self) -> None:
        self._by_id: dict[str, AppUser] = {}

    def get_user(self, user_id: str) -> AppUser | None:
        return self._by_id.get(user_id)

    def get_user_by_email(self, email: str) -> AppUser | None:
        for user in self._by_id.values():
            if user.email == email:
                return user
        return None

    def save_user(self, user: AppUser) -> AppUser:
        self._by_id[user.user_id] = user
        return user

    def list_users_for_vm(self, vm_id: str) -> list[AppUser]:
        return [user for user in self._by_id.values() if user.vm_id == vm_id]


class FirestoreUserRepository:
    def __init__(self, client: firestore.Client, collection_name: str) -> None:
        self._collection = client.collection(collection_name)

    def get_user(self, user_id: str) -> AppUser | None:
        snapshot = cast(firestore.DocumentSnapshot, self._collection.document(user_id).get())
        if not snapshot.exists:
            return None
        data = snapshot.to_dict()
        if data is None:
            return None
        return AppUser.model_validate(data)

    def get_user_by_email(self, email: str) -> AppUser | None:
        docs: Iterable[firestore.DocumentSnapshot] = (
            self._collection.where("email", "==", email).limit(1).stream()
        )
        for doc in docs:
            data = doc.to_dict()
            if data is not None:
                return AppUser.model_validate(data)
        return None

    def save_user(self, user: AppUser) -> AppUser:
        self._collection.document(user.user_id).set(user.model_dump(mode="python"))
        return user

    def list_users_for_vm(self, vm_id: str) -> list[AppUser]:
        docs = self._collection.where("vm_id", "==", vm_id).stream()
        return [
            AppUser.model_validate(doc.to_dict())
            for doc in docs
            if doc.to_dict() is not None
        ]
