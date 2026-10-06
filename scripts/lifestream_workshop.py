import argparse
import json
import sqlite3
import urllib.error
import urllib.request
from contextlib import closing
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%S.%fZ"


@dataclass(frozen=True)
class WorkshopSourceFile:
    source_file_id: str
    user_id: str
    owned_source_id: str
    import_run_id: str | None
    content_hash: str
    original_relative_path: str
    metadata_state: str
    time_start: str | None
    time_end: str | None
    interval_confidence: float | None
    processing_version: str | None
    metadata_artifact_uri: str | None
    review_notes: str | None
    metadata_error: str | None
    dirty: bool
    last_writeback_at: str | None
    created_at: str
    updated_at: str


def utc_now_iso() -> str:
    return datetime.now(tz=UTC).strftime(TIMESTAMP_FORMAT)


def _ensure_parent_dir(db_path: Path) -> None:
    db_path.parent.mkdir(parents=True, exist_ok=True)


def connect_db(db_path: Path) -> sqlite3.Connection:
    _ensure_parent_dir(db_path)
    connection = sqlite3.connect(str(db_path))
    connection.row_factory = sqlite3.Row
    return connection


def init_db(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS source_file_work_items (
            source_file_id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            owned_source_id TEXT NOT NULL,
            import_run_id TEXT,
            content_hash TEXT NOT NULL,
            original_relative_path TEXT NOT NULL,
            metadata_state TEXT NOT NULL,
            time_start TEXT,
            time_end TEXT,
            interval_confidence REAL,
            processing_version TEXT,
            metadata_artifact_uri TEXT,
            review_notes TEXT,
            metadata_error TEXT,
            dirty INTEGER NOT NULL DEFAULT 1,
            last_writeback_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_work_items_owned_source
            ON source_file_work_items (owned_source_id);

        CREATE INDEX IF NOT EXISTS idx_work_items_dirty
            ON source_file_work_items (dirty, metadata_state, updated_at);
        """
    )
    connection.commit()


def register_source_file(
    connection: sqlite3.Connection,
    *,
    source_file_id: str,
    user_id: str,
    owned_source_id: str,
    import_run_id: str | None,
    content_hash: str,
    original_relative_path: str,
) -> WorkshopSourceFile:
    now = utc_now_iso()
    connection.execute(
        """
        INSERT OR REPLACE INTO source_file_work_items (
            source_file_id,
            user_id,
            owned_source_id,
            import_run_id,
            content_hash,
            original_relative_path,
            metadata_state,
            time_start,
            time_end,
            interval_confidence,
            processing_version,
            metadata_artifact_uri,
            review_notes,
            metadata_error,
            dirty,
            last_writeback_at,
            created_at,
            updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1, NULL, ?, ?)
        """,
        (
            source_file_id,
            user_id,
            owned_source_id,
            import_run_id,
            content_hash,
            original_relative_path,
            "pending",
            now,
            now,
        ),
    )
    connection.commit()
    return get_source_file(connection, source_file_id)


def get_source_file(connection: sqlite3.Connection, source_file_id: str) -> WorkshopSourceFile:
    row = connection.execute(
        "SELECT * FROM source_file_work_items WHERE source_file_id = ?",
        (source_file_id,),
    ).fetchone()
    if row is None:
        raise KeyError(f"source_file_id not found: {source_file_id}")
    return _row_to_workshop_source_file(row)


def record_metadata_result(
    connection: sqlite3.Connection,
    *,
    source_file_id: str,
    metadata_state: str,
    time_start: str | None,
    time_end: str | None,
    interval_confidence: float | None,
    processing_version: str | None,
    metadata_artifact_uri: str | None,
    review_notes: str | None,
    metadata_error: str | None,
) -> WorkshopSourceFile:
    _validate_interval_window(time_start, time_end)
    now = utc_now_iso()
    cursor = connection.execute(
        """
        UPDATE source_file_work_items
        SET metadata_state = ?,
            time_start = ?,
            time_end = ?,
            interval_confidence = ?,
            processing_version = ?,
            metadata_artifact_uri = ?,
            review_notes = ?,
            metadata_error = ?,
            dirty = 1,
            updated_at = ?
        WHERE source_file_id = ?
        """,
        (
            metadata_state,
            time_start,
            time_end,
            interval_confidence,
            processing_version,
            metadata_artifact_uri,
            review_notes,
            metadata_error,
            now,
            source_file_id,
        ),
    )
    if cursor.rowcount == 0:
        raise KeyError(f"source_file_id not found: {source_file_id}")
    connection.commit()
    return get_source_file(connection, source_file_id)


def list_pending_writebacks(connection: sqlite3.Connection) -> list[WorkshopSourceFile]:
    rows = connection.execute(
        """
        SELECT *
        FROM source_file_work_items
        WHERE dirty = 1
        ORDER BY updated_at ASC
        """
    ).fetchall()
    return [_row_to_workshop_source_file(row) for row in rows]


def emit_writeback_payload(
    connection: sqlite3.Connection,
    source_file_id: str,
) -> dict[str, Any]:
    work_item = get_source_file(connection, source_file_id)
    return {
        "source_file_id": work_item.source_file_id,
        "owned_source_id": work_item.owned_source_id,
        "payload": {
            "metadata_state": work_item.metadata_state,
            "time_start": work_item.time_start,
            "time_end": work_item.time_end,
            "interval_confidence": work_item.interval_confidence,
            "processing_version": work_item.processing_version,
            "metadata_artifact_uri": work_item.metadata_artifact_uri,
            "review_notes": work_item.review_notes,
            "metadata_error": work_item.metadata_error,
        },
    }


def mark_writeback_complete(
    connection: sqlite3.Connection,
    source_file_id: str,
) -> WorkshopSourceFile:
    now = utc_now_iso()
    cursor = connection.execute(
        """
        UPDATE source_file_work_items
        SET dirty = 0,
            last_writeback_at = ?,
            updated_at = ?
        WHERE source_file_id = ?
        """,
        (now, now, source_file_id),
    )
    if cursor.rowcount == 0:
        raise KeyError(f"source_file_id not found: {source_file_id}")
    connection.commit()
    return get_source_file(connection, source_file_id)


def sync_one_to_backend(
    connection: sqlite3.Connection,
    *,
    source_file_id: str,
    api_base_url: str,
    bearer_token: str,
) -> dict[str, Any]:
    payload = emit_writeback_payload(connection, source_file_id)
    request = urllib.request.Request(
        (
            f"{api_base_url.rstrip('/')}"
            f"/me/sources/{payload['owned_source_id']}/files/{source_file_id}/metadata"
        ),
        data=json.dumps(payload["payload"]).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {bearer_token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="PATCH",
    )
    try:
        with urllib.request.urlopen(request) as response:
            body = response.read().decode("utf-8")
            response_payload = json.loads(body) if body else None
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        try:
            response_payload = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            response_payload = raw
        raise RuntimeError(
            json.dumps(
                {
                    "detail": "Backend metadata sync failed.",
                    "source_file_id": source_file_id,
                    "status_code": exc.code,
                    "response": response_payload,
                },
                indent=2,
            )
        ) from exc

    updated_work_item = mark_writeback_complete(connection, source_file_id)
    return {
        "source_file_id": source_file_id,
        "owned_source_id": payload["owned_source_id"],
        "synced": True,
        "backend_response": response_payload,
        "workshop_row": asdict(updated_work_item),
    }


def sync_pending_to_backend(
    connection: sqlite3.Connection,
    *,
    api_base_url: str,
    bearer_token: str,
    limit: int,
) -> list[dict[str, Any]]:
    pending = list_pending_writebacks(connection)[:limit]
    results: list[dict[str, Any]] = []
    for work_item in pending:
        results.append(
            sync_one_to_backend(
                connection,
                source_file_id=work_item.source_file_id,
                api_base_url=api_base_url,
                bearer_token=bearer_token,
            )
        )
    return results


def _row_to_workshop_source_file(row: sqlite3.Row) -> WorkshopSourceFile:
    return WorkshopSourceFile(
        source_file_id=str(row["source_file_id"]),
        user_id=str(row["user_id"]),
        owned_source_id=str(row["owned_source_id"]),
        import_run_id=str(row["import_run_id"]) if row["import_run_id"] is not None else None,
        content_hash=str(row["content_hash"]),
        original_relative_path=str(row["original_relative_path"]),
        metadata_state=str(row["metadata_state"]),
        time_start=str(row["time_start"]) if row["time_start"] is not None else None,
        time_end=str(row["time_end"]) if row["time_end"] is not None else None,
        interval_confidence=(
            float(row["interval_confidence"]) if row["interval_confidence"] is not None else None
        ),
        processing_version=(
            str(row["processing_version"]) if row["processing_version"] is not None else None
        ),
        metadata_artifact_uri=(
            str(row["metadata_artifact_uri"]) if row["metadata_artifact_uri"] is not None else None
        ),
        review_notes=str(row["review_notes"]) if row["review_notes"] is not None else None,
        metadata_error=str(row["metadata_error"]) if row["metadata_error"] is not None else None,
        dirty=bool(row["dirty"]),
        last_writeback_at=(
            str(row["last_writeback_at"]) if row["last_writeback_at"] is not None else None
        ),
        created_at=str(row["created_at"]),
        updated_at=str(row["updated_at"]),
    )


def _validate_interval_window(time_start: str | None, time_end: str | None) -> None:
    if time_start is None or time_end is None:
        return
    parsed_start = datetime.fromisoformat(time_start.replace("Z", "+00:00"))
    parsed_end = datetime.fromisoformat(time_end.replace("Z", "+00:00"))
    if parsed_end < parsed_start:
        raise ValueError("time_end must be greater than or equal to time_start")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Local SQLite workshop tooling for the Guardian lifestream compiler VM."
    )
    parser.add_argument(
        "--db",
        default="~/.guardian/lifestream-compiler/workshop.sqlite3",
        help="Path to the local workshop sqlite database.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("init", help="Initialize the sqlite workshop database.")

    register_parser = subparsers.add_parser(
        "register-source-file",
        help="Register a source_file work item in the workshop DB.",
    )
    register_parser.add_argument("--source-file-id", required=True)
    register_parser.add_argument("--user-id", required=True)
    register_parser.add_argument("--owned-source-id", required=True)
    register_parser.add_argument("--import-run-id", default=None)
    register_parser.add_argument("--content-hash", required=True)
    register_parser.add_argument("--original-relative-path", required=True)

    record_parser = subparsers.add_parser(
        "record-metadata",
        help="Record or revise interval metadata for a source_file work item.",
    )
    record_parser.add_argument("--source-file-id", required=True)
    record_parser.add_argument("--metadata-state", required=True)
    record_parser.add_argument("--time-start", default=None)
    record_parser.add_argument("--time-end", default=None)
    record_parser.add_argument("--interval-confidence", type=float, default=None)
    record_parser.add_argument("--processing-version", default=None)
    record_parser.add_argument("--metadata-artifact-uri", default=None)
    record_parser.add_argument("--review-notes", default=None)
    record_parser.add_argument("--metadata-error", default=None)

    pending_parser = subparsers.add_parser(
        "list-pending-writebacks",
        help="List work items that still need backend writeback.",
    )
    pending_parser.add_argument("--limit", type=int, default=100)

    emit_parser = subparsers.add_parser(
        "emit-writeback",
        help="Emit the backend writeback payload for one source_file.",
    )
    emit_parser.add_argument("--source-file-id", required=True)

    complete_parser = subparsers.add_parser(
        "mark-writeback-complete",
        help="Mark a source_file work item as flushed back to the backend.",
    )
    complete_parser.add_argument("--source-file-id", required=True)

    sync_one_parser = subparsers.add_parser(
        "sync-one",
        help="Push one work item to the real Guardian backend and mark it clean on success.",
    )
    sync_one_parser.add_argument("--source-file-id", required=True)
    sync_one_parser.add_argument("--api-base-url", required=True)
    sync_one_parser.add_argument("--bearer-token", required=True)

    sync_pending_parser = subparsers.add_parser(
        "sync-pending",
        help="Push pending dirty work items to the real Guardian backend.",
    )
    sync_pending_parser.add_argument("--api-base-url", required=True)
    sync_pending_parser.add_argument("--bearer-token", required=True)
    sync_pending_parser.add_argument("--limit", type=int, default=10)

    return parser


def _to_json(value: Any) -> str:
    if isinstance(value, WorkshopSourceFile):
        payload: Any = asdict(value)
    elif isinstance(value, dict):
        payload = value
    else:
        payload = [asdict(item) if isinstance(item, WorkshopSourceFile) else item for item in value]
    return json.dumps(payload, indent=2)


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()
    db_path = Path(args.db).expanduser().resolve()

    with closing(connect_db(db_path)) as connection:
        init_db(connection)

        if args.command == "init":
            print(json.dumps({"db_path": str(db_path), "initialized": True}, indent=2))
            return

        if args.command == "register-source-file":
            result = register_source_file(
                connection,
                source_file_id=args.source_file_id,
                user_id=args.user_id,
                owned_source_id=args.owned_source_id,
                import_run_id=args.import_run_id,
                content_hash=args.content_hash,
                original_relative_path=args.original_relative_path,
            )
            print(_to_json(result))
            return

        if args.command == "record-metadata":
            result = record_metadata_result(
                connection,
                source_file_id=args.source_file_id,
                metadata_state=args.metadata_state,
                time_start=args.time_start,
                time_end=args.time_end,
                interval_confidence=args.interval_confidence,
                processing_version=args.processing_version,
                metadata_artifact_uri=args.metadata_artifact_uri,
                review_notes=args.review_notes,
                metadata_error=args.metadata_error,
            )
            print(_to_json(result))
            return

        if args.command == "list-pending-writebacks":
            results = list_pending_writebacks(connection)[: args.limit]
            print(_to_json(results))
            return

        if args.command == "emit-writeback":
            print(_to_json(emit_writeback_payload(connection, args.source_file_id)))
            return

        if args.command == "mark-writeback-complete":
            result = mark_writeback_complete(connection, args.source_file_id)
            print(_to_json(result))
            return

        if args.command == "sync-one":
            sync_result = sync_one_to_backend(
                connection,
                source_file_id=args.source_file_id,
                api_base_url=args.api_base_url,
                bearer_token=args.bearer_token,
            )
            print(_to_json(sync_result))
            return

        if args.command == "sync-pending":
            sync_results = sync_pending_to_backend(
                connection,
                api_base_url=args.api_base_url,
                bearer_token=args.bearer_token,
                limit=args.limit,
            )
            print(_to_json(sync_results))
            return

        raise SystemExit(f"Unknown command: {args.command}")


if __name__ == "__main__":
    main()
