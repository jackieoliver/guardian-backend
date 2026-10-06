from typing import Protocol, cast

from google.cloud import firestore

from .models import VmRecord


class VmRepository(Protocol):
    def get_vm(self, vm_id: str) -> VmRecord | None: ...

    def save_vm(self, vm: VmRecord) -> VmRecord: ...


class InMemoryVmRepository:
    def __init__(self) -> None:
        self._by_id: dict[str, VmRecord] = {}

    def get_vm(self, vm_id: str) -> VmRecord | None:
        return self._by_id.get(vm_id)

    def save_vm(self, vm: VmRecord) -> VmRecord:
        self._by_id[vm.vm_id] = vm
        return vm


class FirestoreVmRepository:
    def __init__(self, client: firestore.Client, collection_name: str) -> None:
        self._collection = client.collection(collection_name)

    def get_vm(self, vm_id: str) -> VmRecord | None:
        snapshot = cast(firestore.DocumentSnapshot, self._collection.document(vm_id).get())
        if not snapshot.exists:
            return None
        data = snapshot.to_dict()
        if data is None:
            return None
        return VmRecord.model_validate(data)

    def save_vm(self, vm: VmRecord) -> VmRecord:
        self._collection.document(vm.vm_id).set(vm.model_dump(mode="python"))
        return vm
