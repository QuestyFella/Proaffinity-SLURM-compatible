#!/usr/bin/env python3
"""Collect SLURM per-task TSVs into a sorted CSV summary.

Usage:
    python scripts/collect_results.py results/af3_batch1
    python scripts/collect_results.py results/af3_batch1 -i data/index_af3_batch1.txt
    python scripts/collect_results.py results/af3_batch1 -o results/af3_batch1/summary.csv
"""

from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent


def pdb_id_from_path(pdb_path: str) -> str:
    return Path(pdb_path).stem.lower()


def elapsed_seconds(elapsed_str: str) -> int | str:
    match = re.match(r"(\d+)s", elapsed_str or "")
    return int(match.group(1)) if match else ""


def load_index_chain_specs(index_path: Path | None) -> dict[str, str]:
    specs: dict[str, str] = {}
    if index_path is None or not index_path.exists():
        return specs
    for line in index_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        pdb_path, chain_spec = line.split("\t", 1)
        specs[pdb_id_from_path(pdb_path)] = chain_spec
    return specs


def parse_task_tsv(path: Path) -> list[tuple[str, str, str, str, str]]:
    rows: list[tuple[str, str, str, str, str]] = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        elapsed = parts[4] if len(parts) > 4 else ""
        rows.append((parts[0], parts[1], parts[2], parts[3], elapsed))
    return rows


def split_chain_spec(chain_spec: str) -> tuple[str, str]:
    if ";" in chain_spec:
        partner1, partner2 = chain_spec.split(";", 1)
        return partner1, partner2
    return chain_spec, ""


def collect_rows(output_dir: Path, index_specs: dict[str, str]) -> list[dict[str, object]]:
    task_files = sorted(
        output_dir.glob("task_*.tsv"),
        key=lambda path: int(path.stem.split("_", 1)[1]),
    )
    if not task_files:
        raise SystemExit(f"ERROR: no task_*.tsv files found in {output_dir}")

    seen: set[str] = set()
    rows: list[dict[str, object]] = []
    for task_file in task_files:
        for pdb_path, chain_spec, pka, status, elapsed in parse_task_tsv(task_file):
            pdb_id = pdb_id_from_path(pdb_path)
            if pdb_id in seen:
                continue
            seen.add(pdb_id)
            chains = index_specs.get(pdb_id, chain_spec)
            partner1, partner2 = split_chain_spec(chains)
            rows.append(
                {
                    "pdb_id": pdb_id.upper(),
                    "partner1": partner1,
                    "partner2": partner2,
                    "pka": round(float(pka), 3) if pka else "",
                    "status": status,
                    "elapsed_sec": elapsed_seconds(elapsed),
                }
            )

    rows.sort(key=lambda row: str(row["pdb_id"]))
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description="Collect task_*.tsv into a sorted CSV")
    parser.add_argument("output_dir", type=Path, help="Directory containing task_*.tsv files")
    parser.add_argument(
        "-i",
        "--index",
        type=Path,
        help="Index file for readable chain specs (default: auto-detect in data/)",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Output CSV path (default: <output_dir>/results.csv)",
    )
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    if not output_dir.is_dir():
        raise SystemExit(f"ERROR: not a directory: {output_dir}")

    index_path = args.index
    if index_path is None:
        for candidate in sorted((PROJECT_DIR / "data").glob("index_*.txt")):
            specs = load_index_chain_specs(candidate)
            if specs:
                index_path = candidate
                break

    index_specs = load_index_chain_specs(index_path)
    rows = collect_rows(output_dir, index_specs)

    out_csv = (args.output or output_dir / "results.csv").resolve()
    with out_csv.open("w", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["pdb_id", "partner1", "partner2", "pka", "status", "elapsed_sec"],
        )
        writer.writeheader()
        writer.writerows(rows)

    ok = sum(1 for row in rows if row["status"] == "OK")
    print(f"Wrote {len(rows)} rows ({ok} OK) to {out_csv}")
    if index_path:
        print(f"Chain specs from: {index_path}")


if __name__ == "__main__":
    main()
