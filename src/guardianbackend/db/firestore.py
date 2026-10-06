from google.cloud import firestore

from guardianbackend.config import Settings


def build_firestore_client(settings: Settings) -> firestore.Client | None:
    if not settings.uses_cloud:
        return None
    return firestore.Client(project=settings.gcp_project_id, database=settings.firestore_database)
