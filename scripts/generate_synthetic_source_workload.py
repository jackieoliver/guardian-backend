import argparse
import json
import os
import shutil
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from random import Random


@dataclass(frozen=True)
class WorkloadProfile:
    name: str
    file_count: int
    min_size_bytes: int
    max_size_bytes: int


PROFILES: dict[str, WorkloadProfile] = {
    "tiny": WorkloadProfile("tiny", file_count=12, min_size_bytes=256, max_size_bytes=2_048),
    "dev": WorkloadProfile("dev", file_count=100, min_size_bytes=512, max_size_bytes=8_192),
    "real": WorkloadProfile("real", file_count=1_000, min_size_bytes=1_024, max_size_bytes=12_288),
    "stress": WorkloadProfile(
        "stress",
        file_count=10_000,
        min_size_bytes=256,
        max_size_bytes=4_096,
    ),
}

KINDS = ("screenpipe", "mixed", "many-tiny")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate synthetic source folders for Guardian ingest testing."
    )
    parser.add_argument("--output", required=True, help="Directory to create the workload under.")
    parser.add_argument(
        "--profile",
        choices=sorted(PROFILES),
        default="dev",
        help="Named size/count profile.",
    )
    parser.add_argument(
        "--kind",
        choices=KINDS,
        default="screenpipe",
        help="Layout and file-type style to generate.",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Deterministic random seed for repeatable workloads.",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Remove the output directory before generating the new workload.",
    )
    return parser


def _write_bytes(path: Path, size_bytes: int, payload_seed: str) -> None:
    base = (payload_seed + "\n").encode("utf-8")
    repeats = (size_bytes // len(base)) + 1
    path.write_bytes((base * repeats)[:size_bytes])


def _screenpipe_relative_path(index: int, rng: Random) -> str:
    base = datetime(2026, 1, 1, 9, 0, tzinfo=UTC) + timedelta(minutes=index)
    hour_dir = base.strftime("%Y/%m/%d/%H")
    ext = rng.choice(["json", "mp4", "png", "txt"])
    stem = f"screenpipe-{base.strftime('%Y%m%dT%H%M%S')}-{index:05d}"
    return f"screenpipe/{hour_dir}/{stem}.{ext}"


def _mixed_relative_path(index: int, rng: Random) -> str:
    bucket = rng.choice(["camera", "audio", "notes", "meta", "exports"])
    ext_by_bucket = {
        "camera": ["jpg", "png", "json"],
        "audio": ["wav", "json", "txt"],
        "notes": ["md", "txt", "json"],
        "meta": ["json", "log"],
        "exports": ["csv", "json"],
    }
    ext = rng.choice(ext_by_bucket[bucket])
    shard_dir = f"{bucket}/{index % 50:02d}"
    return f"{shard_dir}/{bucket}-{index:05d}.{ext}"


def _many_tiny_relative_path(index: int) -> str:
    shard_dir = f"tiny/{index % 100:03d}"
    return f"{shard_dir}/tiny-{index:05d}.txt"


def _relative_path(kind: str, index: int, rng: Random) -> str:
    if kind == "screenpipe":
        return _screenpipe_relative_path(index, rng)
    if kind == "mixed":
        return _mixed_relative_path(index, rng)
    return _many_tiny_relative_path(index)


def _build_manifest(
    *,
    output_root: Path,
    profile: WorkloadProfile,
    kind: str,
    seed: int,
    rng: Random,
) -> dict[str, object]:
    created_files: list[dict[str, object]] = []
    total_size_bytes = 0
    started_at = datetime(2026, 1, 1, 9, 0, tzinfo=UTC)

    for index in range(profile.file_count):
        relative_path = _relative_path(kind, index, rng)
        size_bytes = rng.randint(profile.min_size_bytes, profile.max_size_bytes)
        file_path = output_root / relative_path
        file_path.parent.mkdir(parents=True, exist_ok=True)
        payload_seed = f"{kind}:{profile.name}:{index}:{seed}"
        _write_bytes(file_path, size_bytes, payload_seed)

        modified_at = started_at + timedelta(seconds=index * 11)
        ts = modified_at.timestamp()
        os.utime(file_path, (ts, ts))

        total_size_bytes += size_bytes
        created_files.append(
            {
                "relative_path": relative_path,
                "size_bytes": size_bytes,
                "modified_at": modified_at.isoformat(),
            }
        )

    return {
        "workload_kind": kind,
        "profile": profile.name,
        "seed": seed,
        "file_count": profile.file_count,
        "total_size_bytes": total_size_bytes,
        "files": created_files,
    }


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()

    profile = PROFILES[args.profile]
    output_root = Path(args.output).expanduser().resolve()
    if args.clean and output_root.exists():
        shutil.rmtree(output_root)
    output_root.mkdir(parents=True, exist_ok=True)

    rng = Random(args.seed)
    manifest = _build_manifest(
        output_root=output_root,
        profile=profile,
        kind=args.kind,
        seed=args.seed,
        rng=rng,
    )
    manifest_path = output_root / ".guardian-workload.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(
        json.dumps(
            {
                "output": str(output_root),
                "manifest_path": str(manifest_path),
                "workload_kind": args.kind,
                "profile": profile.name,
                "file_count": manifest["file_count"],
                "total_size_bytes": manifest["total_size_bytes"],
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
