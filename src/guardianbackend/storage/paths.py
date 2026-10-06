def build_transport_object_path(
    *,
    transport_prefix: str,
    user_id: str,
    owned_source_id: str,
    import_run_id: str,
    filename: str,
) -> str:
    return f"{transport_prefix}/{user_id}/{owned_source_id}/{import_run_id}/{filename}"


def build_canonical_file_object_path(
    *,
    files_prefix: str,
    user_id: str,
    owned_source_id: str,
    materialized_filename: str,
) -> str:
    return f"{files_prefix}/{user_id}/{owned_source_id}/{materialized_filename}"
