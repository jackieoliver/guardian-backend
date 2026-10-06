import importlib.util
import json
import threading
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from socketserver import TCPServer
from types import ModuleType


def _load_lifestream_workshop_module() -> ModuleType:
    module_path = (
        Path(__file__).resolve().parents[1] / "scripts" / "lifestream_workshop.py"
    )
    spec = importlib.util.spec_from_file_location("lifestream_workshop", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("Could not load lifestream_workshop module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_lifestream_workshop_sqlite_flow(tmp_path: Path) -> None:
    workshop = _load_lifestream_workshop_module()
    db_path = tmp_path / "workshop.sqlite3"
    connection = workshop.connect_db(db_path)
    try:
        workshop.init_db(connection)
        registered = workshop.register_source_file(
            connection,
            source_file_id="file_test123",
            user_id="user_test123",
            owned_source_id="source_test123",
            import_run_id="import_test123",
            content_hash="hash123",
            original_relative_path="notes/example.txt",
        )
        assert registered.metadata_state == "pending"
        assert registered.dirty is True

        updated = workshop.record_metadata_result(
            connection,
            source_file_id="file_test123",
            metadata_state="inferred",
            time_start="2026-01-01T09:00:00Z",
            time_end="2026-01-01T09:05:00Z",
            interval_confidence=0.81,
            processing_version="interval-v1",
            metadata_artifact_uri="gs://guardian/artifacts/file_test123.json",
            review_notes=None,
            metadata_error=None,
        )
        assert updated.metadata_state == "inferred"
        assert updated.interval_confidence == 0.81

        pending = workshop.list_pending_writebacks(connection)
        assert len(pending) == 1
        assert pending[0].source_file_id == "file_test123"

        payload = workshop.emit_writeback_payload(connection, "file_test123")
        assert payload["source_file_id"] == "file_test123"
        assert payload["payload"]["metadata_state"] == "inferred"
        assert payload["payload"]["time_start"] == "2026-01-01T09:00:00Z"

        completed = workshop.mark_writeback_complete(connection, "file_test123")
        assert completed.dirty is False
        assert completed.last_writeback_at is not None

        assert workshop.list_pending_writebacks(connection) == []
    finally:
        connection.close()


def test_lifestream_workshop_sync_one(tmp_path: Path) -> None:
    workshop = _load_lifestream_workshop_module()
    db_path = tmp_path / "workshop.sqlite3"
    connection = workshop.connect_db(db_path)

    captured: dict[str, object] = {}

    class Handler(BaseHTTPRequestHandler):
        def do_PATCH(self) -> None:  # noqa: N802
            content_length = int(self.headers["Content-Length"])
            body = self.rfile.read(content_length).decode("utf-8")
            captured["path"] = self.path
            captured["authorization"] = self.headers.get("Authorization")
            captured["payload"] = json.loads(body)
            response = json.dumps({"metadata_state": "inferred"}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)

        def log_message(self, format: str, *args: object) -> None:  # noqa: A003
            return

    server = TCPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        workshop.init_db(connection)
        workshop.register_source_file(
            connection,
            source_file_id="file_sync123",
            user_id="user_test123",
            owned_source_id="source_sync123",
            import_run_id=None,
            content_hash="hash123",
            original_relative_path="notes/example.txt",
        )
        workshop.record_metadata_result(
            connection,
            source_file_id="file_sync123",
            metadata_state="inferred",
            time_start="2026-01-01T09:00:00Z",
            time_end="2026-01-01T09:05:00Z",
            interval_confidence=0.9,
            processing_version="interval-v1",
            metadata_artifact_uri=None,
            review_notes=None,
            metadata_error=None,
        )

        result = workshop.sync_one_to_backend(
            connection,
            source_file_id="file_sync123",
            api_base_url=f"http://127.0.0.1:{server.server_address[1]}",
            bearer_token="test-token",
        )
        assert result["synced"] is True
        assert captured["path"] == "/me/sources/source_sync123/files/file_sync123/metadata"
        assert captured["authorization"] == "Bearer test-token"
        assert captured["payload"] == {
            "metadata_state": "inferred",
            "time_start": "2026-01-01T09:00:00Z",
            "time_end": "2026-01-01T09:05:00Z",
            "interval_confidence": 0.9,
            "processing_version": "interval-v1",
            "metadata_artifact_uri": None,
            "review_notes": None,
            "metadata_error": None,
        }
        assert workshop.list_pending_writebacks(connection) == []
    finally:
        server.shutdown()
        server.server_close()
        connection.close()
