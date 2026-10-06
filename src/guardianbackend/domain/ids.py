from secrets import token_hex


def _prefixed_id(prefix: str) -> str:
    return f"{prefix}_{token_hex(10)}"


def new_user_id() -> str:
    return _prefixed_id("user")


def new_owned_source_id() -> str:
    return _prefixed_id("source")


def new_import_run_id() -> str:
    return _prefixed_id("import")


def new_import_shard_id() -> str:
    return _prefixed_id("shard")


def new_source_file_id() -> str:
    return _prefixed_id("file")


def new_journal_id() -> str:
    return _prefixed_id("journal")


def new_journal_entry_id() -> str:
    return _prefixed_id("entry")


def new_journal_branch_id() -> str:
    return _prefixed_id("branch")


def new_journal_message_id() -> str:
    return _prefixed_id("message")


def new_vm_session_id() -> str:
    return _prefixed_id("session")
