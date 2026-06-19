#!/usr/bin/env python3
"""Merge per-chain AlphaFold models in proteins/ into complex PDBs for ProAffinity.

Each subfolder under proteins/ (e.g. 016_5L6Y_antibody_chainH) holds ranked_0.pdb
with a single chain A. ProAffinity needs one PDB per complex with antibody and
antigen chains labeled correctly.

This script:
  1. Groups folders by PDB ID
  2. Merges ranked_<rank>.pdb from each chain into proteins/complexes/<pdb>.pdb
  3. Writes data/index_proteins.txt using only chains you actually modeled

Usage:
    python scripts/prepare_proteins.py
    python scripts/prepare_proteins.py --rank 0
    python scripts/prepare_proteins.py --all-ranks
    python scripts/prepare_proteins.py --dry-run

Then on Rorqual:
    ./scripts/submit_test.sh data/index_proteins.txt
    ./scripts/submit_array.sh data/index_proteins.txt

Note: chains are merged at their AlphaFold coordinates (separate runs). Relative
binding geometry is approximate; scores are useful for ranking your models, not
absolute affinity vs experiment.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
DEFAULT_PROTEINS_DIR = PROJECT_DIR / "proteins"
DEFAULT_COMPLEX_DIR = DEFAULT_PROTEINS_DIR / "complexes"
DEFAULT_INDEX = PROJECT_DIR / "data" / "index_proteins.txt"

FOLDER_PATTERN = re.compile(r"^\d+_([0-9A-Z]+)_(.+)_chain([A-Z0-9]+)$")
AB_ORDER = "HLABDM"


def scan_proteins_dir(proteins_dir: Path) -> dict[str, list[dict]]:
    groups: dict[str, list[dict]] = defaultdict(list)
    if not proteins_dir.is_dir():
        return groups

    for path in sorted(proteins_dir.iterdir()):
        if not path.is_dir():
            continue
        m = FOLDER_PATTERN.match(path.name)
        if not m:
            continue
        pdb_id, desc, chain = m.group(1), m.group(2), m.group(3)
        role = "antibody" if "antibody" in desc else "antigen"
        groups[pdb_id].append(
            {
                "folder": path,
                "role": role,
                "chain": chain,
                "desc": desc.replace("_", " "),
            }
        )
    return groups


def chain_sort_key(chain: str) -> tuple[int, str]:
    idx = AB_ORDER.find(chain)
    return (idx if idx >= 0 else len(AB_ORDER), chain)


def sort_antibody_chains(chains: list[str]) -> list[str]:
    return sorted(chains, key=chain_sort_key)


def chain_spec(antibody: list[str], antigen: list[str]) -> str:
    ab = ",".join(sort_antibody_chains(antibody))
    ag = ",".join(sorted(antigen))
    return f"{ab};{ag}"


def pick_model(folder: Path, rank: int) -> Path:
    ranked = folder / f"ranked_{rank}.pdb"
    if ranked.is_file():
        return ranked
    fallback = folder / "ranked_0.pdb"
    if fallback.is_file():
        return fallback
    raise FileNotFoundError(f"no ranked_{rank}.pdb in {folder}")


def remap_line(line: str, serial: int, chain: str) -> str:
    if line.startswith(("ATOM", "HETATM")):
        return line[:6] + f"{serial:5d}" + line[11:21] + chain + line[22:]
    return line


def merge_complex(
    entries: list[dict],
    rank: int,
) -> tuple[list[str], list[str], list[str]]:
    """Return (pdb_lines, antibody_chains, antigen_chains)."""
    antibody = [e["chain"] for e in entries if e["role"] == "antibody"]
    antigen = [e["chain"] for e in entries if e["role"] == "antigen"]
    if not antibody or not antigen:
        raise ValueError("need at least one antibody and one antigen chain")

    # Stable merge order: antibody chains first, then antigen
    ordered = sorted([e for e in entries if e["role"] == "antibody"], key=lambda e: chain_sort_key(e["chain"])) + sorted(
        [e for e in entries if e["role"] == "antigen"], key=lambda e: e["chain"]
    )

    out: list[str] = [
        "REMARK   1 merged from AlphaFold per-chain models via prepare_proteins.py",
    ]
    serial = 0
    for entry in ordered:
        src = pick_model(entry["folder"], rank)
        chain = entry["chain"]
        out.append(f"REMARK   1 source {src.parent.name} -> chain {chain}")
        chain_atoms = 0
        last_atom_line = ""
        for line in src.read_text().splitlines():
            if line.startswith(("ATOM", "HETATM")):
                serial += 1
                last_atom_line = remap_line(line, serial, chain)
                out.append(last_atom_line)
                chain_atoms += 1
        if chain_atoms == 0:
            raise ValueError(f"no ATOM records in {src}")
        serial += 1
        out.append(f"TER   {serial:5d}      {last_atom_line[17:27]}")
    out.append("END")
    return out, antibody, antigen


def main() -> None:
    parser = argparse.ArgumentParser(description="Prepare proteins/ AlphaFold models for ProAffinity")
    parser.add_argument(
        "-d",
        "--proteins-dir",
        type=Path,
        default=DEFAULT_PROTEINS_DIR,
        help=f"AlphaFold output root (default: {DEFAULT_PROTEINS_DIR})",
    )
    parser.add_argument(
        "--complex-dir",
        type=Path,
        default=DEFAULT_COMPLEX_DIR,
        help=f"Merged complex PDB output dir (default: {DEFAULT_COMPLEX_DIR})",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=DEFAULT_INDEX,
        help=f"Index TSV output (default: {DEFAULT_INDEX})",
    )
    parser.add_argument(
        "--rank",
        type=int,
        default=0,
        help="AlphaFold ranked model index to use (default: 0)",
    )
    parser.add_argument(
        "--all-ranks",
        action="store_true",
        help="Prepare all 5 AlphaFold ranks (0-4) as <pdb>_rank<N>.pdb per complex",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned merges without writing files",
    )
    args = parser.parse_args()

    if args.all_ranks and args.rank != 0:
        print("ERROR: use --all-ranks alone, not with --rank", file=sys.stderr)
        sys.exit(1)

    if args.all_ranks and args.output == DEFAULT_INDEX:
        args.output = PROJECT_DIR / "data" / "index_proteins_allranks.txt"

    rank_indices = list(range(5)) if args.all_ranks else [args.rank]

    groups = scan_proteins_dir(args.proteins_dir)
    if not groups:
        print(f"ERROR: no protein subfolders found under {args.proteins_dir}", file=sys.stderr)
        sys.exit(1)

    index_lines: list[str] = []
    skipped: list[str] = []

    print(f"Preparing {len(groups)} complexes from {args.proteins_dir} (ranks={rank_indices}):", file=sys.stderr)

    for pdb_id in sorted(groups):
        entries = groups[pdb_id]
        ab = [e["chain"] for e in entries if e["role"] == "antibody"]
        ag = [e["chain"] for e in entries if e["role"] == "antigen"]

        if not ab or not ag:
            skipped.append(f"{pdb_id} (antibody={ab}, antigen={ag})")
            print(f"  SKIP {pdb_id}: need both antibody and antigen folders", file=sys.stderr)
            continue

        spec = chain_spec(ab, ag)

        for rank in rank_indices:
            if args.all_ranks:
                stem = f"{pdb_id.lower()}_rank{rank}"
            else:
                stem = pdb_id.lower()
            rel_pdb = args.complex_dir.relative_to(PROJECT_DIR) / f"{stem}.pdb"
            dest = args.complex_dir / f"{stem}.pdb"

            try:
                lines, _, _ = merge_complex(entries, rank)
            except (FileNotFoundError, ValueError) as exc:
                skipped.append(f"{pdb_id} rank {rank} ({exc})")
                print(f"  SKIP {pdb_id} rank {rank}: {exc}", file=sys.stderr)
                continue

            print(f"  OK   {pdb_id} rank {rank}: {spec}  ({len(entries)} chains -> {rel_pdb})", file=sys.stderr)

            if not args.dry_run:
                args.complex_dir.mkdir(parents=True, exist_ok=True)
                dest.write_text("\n".join(lines) + "\n")

            index_lines.append(f"{rel_pdb}\t{spec}")

    if skipped:
        print(f"\nSkipped {len(skipped)}:", file=sys.stderr)
        for s in skipped:
            print(f"  {s}", file=sys.stderr)

    if not index_lines:
        print("ERROR: no complexes prepared.", file=sys.stderr)
        sys.exit(1)

    if args.dry_run:
        print("\nIndex preview:", file=sys.stderr)
        for line in index_lines:
            print(line)
        return

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(index_lines) + "\n")
    print(f"\nWrote {len(index_lines)} merged PDBs -> {args.complex_dir}", file=sys.stderr)
    print(f"Wrote index -> {args.output}", file=sys.stderr)
    print(
        "\nNext steps:\n"
        f"  ./scripts/submit_test.sh {args.output.relative_to(PROJECT_DIR)}\n"
        f"  ./scripts/submit_array.sh {args.output.relative_to(PROJECT_DIR)}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
