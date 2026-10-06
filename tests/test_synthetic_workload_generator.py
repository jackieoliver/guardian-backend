import json
import runpy
from pathlib import Path


def test_synthetic_workload_generator_creates_manifest_and_files(
    monkeypatch: object,
    tmp_path: Path,
) -> None:
    output_dir = tmp_path / "workload"
    monkeypatch.setattr(
        "sys.argv",
        [
            "generate_synthetic_source_workload.py",
            "--output",
            str(output_dir),
            "--profile",
            "tiny",
            "--kind",
            "screenpipe",
            "--clean",
        ],
    )

    runpy.run_path(
        str(
            Path(__file__).resolve().parent.parent
            / "scripts"
            / "generate_synthetic_source_workload.py"
        ),
        run_name="__main__",
    )

    manifest_path = output_dir / ".guardian-workload.json"
    assert manifest_path.exists()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["profile"] == "tiny"
    assert manifest["workload_kind"] == "screenpipe"
    assert manifest["file_count"] == 12

    generated_files = [path for path in output_dir.rglob("*") if path.is_file()]
    data_files = [path for path in generated_files if path.name != ".guardian-workload.json"]
    assert len(data_files) == 12
