from datetime import UTC, datetime

from guardianbackend.files import infer_rough_time_interval


def test_infer_screenpipe_from_filename() -> None:
    inferred = infer_rough_time_interval(
        source_id="screenpipe",
        filename="MacBook Air Microphone (input)_2026-03-28_22-39-10.mp4",
        original_relative_path="data/MacBook Air Microphone (input)_2026-03-28_22-39-10.mp4",
        source_modified_at=datetime(2026, 3, 28, 22, 43, tzinfo=UTC),
    )

    assert inferred.time_start == datetime(2026, 3, 28, 22, 39, 10, tzinfo=UTC)
    assert inferred.time_basis == "screenpipe_filename"


def test_infer_phonecapture_from_filename() -> None:
    inferred = infer_rough_time_interval(
        source_id="jelly-phone-capture",
        filename="uvc-20260327-165013.mp4",
        original_relative_path="20260327-214727/uvc-videos/uvc-20260327-165013.mp4",
        source_modified_at=datetime(2026, 3, 27, 23, 50, 14, tzinfo=UTC),
    )

    assert inferred.time_start == datetime(2026, 3, 27, 16, 50, 13, tzinfo=UTC)
    assert inferred.time_basis == "uvc_filename"


def test_infer_l810_from_filename() -> None:
    inferred = infer_rough_time_interval(
        source_id="gumstick-mic",
        filename="R2026-03-29-03-02-35.WAV",
        original_relative_path="RECORD/R2026-03-29-03-02-35.WAV",
        source_modified_at=datetime(2026, 3, 29, 3, 10, tzinfo=UTC),
    )

    assert inferred.time_start == datetime(2026, 3, 29, 3, 2, 35, tzinfo=UTC)
    assert inferred.time_basis == "l810_filename"


def test_fallback_to_source_modified_at_for_gopro_style_file() -> None:
    modified_at = datetime(2026, 3, 24, 21, 38, 3, tzinfo=UTC)
    inferred = infer_rough_time_interval(
        source_id="gopro",
        filename="GX010045.MP4",
        original_relative_path="DCIM/100GOPRO/GX010045.MP4",
        source_modified_at=modified_at,
    )

    assert inferred.time_start == modified_at
    assert inferred.time_basis == "source_modified_at"
