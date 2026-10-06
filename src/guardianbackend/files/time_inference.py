import re
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path


@dataclass(frozen=True)
class RoughTimeInference:
    time_start: datetime
    time_end: datetime
    interval_confidence: float
    time_basis: str
    time_zone_name: str | None
    time_timezone_source: str


_SCREENPIPE_PATTERN = re.compile(r"(\d{4}-\d{2}-\d{2})_(\d{2}-\d{2}-\d{2})")
_UVC_PATTERN = re.compile(r"uvc-(\d{8})-(\d{6})", re.IGNORECASE)
_ANDROID_IMG_PATTERN = re.compile(r"IMG_(\d{8})_(\d{6})", re.IGNORECASE)
_L810_PATTERN = re.compile(r"^[RV](\d{4}-\d{2}-\d{2})-(\d{2}-\d{2}-\d{2})", re.IGNORECASE)


def infer_rough_time_interval(
    *,
    source_id: str,
    filename: str,
    original_relative_path: str,
    source_modified_at: datetime,
) -> RoughTimeInference:
    path_text = original_relative_path or filename
    basename = Path(filename or original_relative_path).name

    if source_id == "screenpipe":
        inferred = _infer_screenpipe(path_text, source_modified_at)
        if inferred is not None:
            return inferred

    if source_id == "jelly-phone-capture":
        inferred = _infer_uvc(path_text, source_modified_at)
        if inferred is not None:
            return inferred

    if source_id == "gumstick-mic":
        inferred = _infer_l810(path_text, source_modified_at)
        if inferred is not None:
            return inferred

    if source_id == "gopro":
        return _fallback_to_source_modified_at(source_modified_at)

    if source_id == "insta360-go-ultra":
        return _fallback_to_source_modified_at(source_modified_at)

    for inferer in (_infer_screenpipe, _infer_uvc, _infer_android_img, _infer_l810):
        inferred = inferer(path_text, source_modified_at)
        if inferred is not None:
            return inferred

    if basename.upper().startswith("GX") and basename.upper().endswith(".MP4"):
        return _fallback_to_source_modified_at(source_modified_at)

    return _fallback_to_source_modified_at(source_modified_at)


def _infer_screenpipe(path_text: str, source_modified_at: datetime) -> RoughTimeInference | None:
    match = _SCREENPIPE_PATTERN.search(path_text)
    if match is None:
        return None
    inferred_at = _parse_with_reference_timezone(
        f"{match.group(1)} {match.group(2).replace('-', ':')}",
        "%Y-%m-%d %H:%M:%S",
        source_modified_at,
    )
    return _build_point_inference(
        inferred_at,
        interval_confidence=0.91,
        time_basis="screenpipe_filename",
        source_modified_at=source_modified_at,
    )


def _infer_uvc(path_text: str, source_modified_at: datetime) -> RoughTimeInference | None:
    match = _UVC_PATTERN.search(path_text)
    if match is None:
        return None
    inferred_at = _parse_with_reference_timezone(
        f"{match.group(1)}{match.group(2)}",
        "%Y%m%d%H%M%S",
        source_modified_at,
    )
    return _build_point_inference(
        inferred_at,
        interval_confidence=0.93,
        time_basis="uvc_filename",
        source_modified_at=source_modified_at,
    )


def _infer_android_img(path_text: str, source_modified_at: datetime) -> RoughTimeInference | None:
    match = _ANDROID_IMG_PATTERN.search(path_text)
    if match is None:
        return None
    inferred_at = _parse_with_reference_timezone(
        f"{match.group(1)}{match.group(2)}",
        "%Y%m%d%H%M%S",
        source_modified_at,
    )
    return _build_point_inference(
        inferred_at,
        interval_confidence=0.9,
        time_basis="android_camera_filename",
        source_modified_at=source_modified_at,
    )


def _infer_l810(path_text: str, source_modified_at: datetime) -> RoughTimeInference | None:
    match = _L810_PATTERN.search(Path(path_text).name)
    if match is None:
        return None
    inferred_at = _parse_with_reference_timezone(
        f"{match.group(1)} {match.group(2).replace('-', ':')}",
        "%Y-%m-%d %H:%M:%S",
        source_modified_at,
    )
    return _build_point_inference(
        inferred_at,
        interval_confidence=0.94,
        time_basis="l810_filename",
        source_modified_at=source_modified_at,
    )


def _fallback_to_source_modified_at(source_modified_at: datetime) -> RoughTimeInference:
    if source_modified_at.tzinfo is None:
        source_modified_at = source_modified_at.replace(tzinfo=UTC)
    return _build_point_inference(
        source_modified_at,
        interval_confidence=0.45,
        time_basis="source_modified_at",
        source_modified_at=source_modified_at,
    )


def _parse_with_reference_timezone(
    value: str,
    pattern: str,
    reference_time: datetime,
) -> datetime:
    naive = datetime.strptime(value, pattern)  # noqa: DTZ007
    if reference_time.tzinfo is None:
        return naive.replace(tzinfo=UTC)
    return naive.replace(tzinfo=reference_time.tzinfo)


def _build_point_inference(
    inferred_at: datetime,
    *,
    interval_confidence: float,
    time_basis: str,
    source_modified_at: datetime,
) -> RoughTimeInference:
    timezone_source = (
        "source_modified_at_timezone"
        if source_modified_at.tzinfo is not None
        else "assumed_utc"
    )
    timezone_name = str(inferred_at.tzinfo) if inferred_at.tzinfo is not None else None
    return RoughTimeInference(
        time_start=inferred_at,
        time_end=inferred_at,
        interval_confidence=interval_confidence,
        time_basis=time_basis,
        time_zone_name=timezone_name,
        time_timezone_source=timezone_source,
    )
