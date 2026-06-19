#!/usr/bin/env python3
"""Prepare ColabFold multimer PDBs for ProAffinity.

ColabFold output PDBs usually use generic chain IDs (A, B, C, ...), while the
folder/file names preserve the intended source chains, e.g.

    0001_1JPS_chains_T_H_L/
      1JPS_chains_T_H_L_unrelaxed_rank_001_...pdb

This script remaps generic chains back to those source chain IDs and writes a
clean ProAffinity index. The first chain in the folder name is treated as the
target/antigen partner; remaining chains are the binder/antibody partner.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
DEFAULT_COLABFOLD_DIR = PROJECT_DIR / "colabfold_fast_results"
DEFAULT_COMPLEX_DIR = DEFAULT_COLABFOLD_DIR / "complexes"
DEFAULT_INDEX = PROJECT_DIR / "data" / "index_colabfold_fast.txt"

FOLDER_RE = re.compile(r"^\d+_([0-9A-Z]+)_chains_([A-Za-z0-9_]+)$")
RANK_RE = re.compile(r"_rank_(\d+)_", re.I)


def relpath_for_display(path: Path, base: Path) -> str:
    try:
        return str(path.resolve().relative_to(base.resolve()))
    except ValueError:
        return str(path)


def parse_rank(path: Path) -> str:
    match = RANK_RE.search(path.name)
    if not match:
        return "1"
    return str(int(match.group(1)))


def atom_chain_ids(path: Path) -> list[str]:
    chains: list[str] = []
    for line in path.read_text(errors="ignore").splitlines():
        if line.startswith(("ATOM", "HETATM")):
            chain = line[21].strip() or " "
            if chain not in chains:
                chains.append(chain)
    return chains


def remap_pdb_lines(path: Path, chain_map: dict[str, str]) -> list[str]:
    out = [
        "REMARK   1 converted from ColabFold multimer via prepare_colabfold_proteins.py",
        f"REMARK   1 source {path.name}",
        f"REMARK   1 chain map {chain_map}",
    ]
    for line in path.read_text(errors="ignore").splitlines():
        if line.startswith(("ATOM", "HETATM", "TER")):
            old_chain = line[21].strip() or " "
            new_chain = chain_map.get(old_chain, old_chain)
            line = line[:21] + new_chain[:1] + line[22:]
        out.append(line)
    if not out[-1].startswith("END"):
        out.append("END")
    return out


def scan_colabfold_dir(colabfold_dir: Path) -> list[dict]:
    entries: list[dict] = []
    if not colabfold_dir.is_dir():
        return entries

    for fold_dir in sorted(colabfold_dir.iterdir()):
        if not fold_dir.is_dir() or fold_dir.name == "complexes":
            continue
        match = FOLDER_RE.match(fold_dir.name)
        if not match:
            continue

        pdb_id = match.group(1).upper()
        source_chains = [part.upper() for part in match.group(2).split("_") if part]
        pdb_files = sorted(fold_dir.glob("*.pdb"))
        for pdb_file in pdb_files:
            entries.append(
                {
                    "pdb_id": pdb_id,
                    "source_chains": source_chains,
                    "rank": parse_rank(pdb_file),
                    "pdb_file": pdb_file,
                }
            )
    return entries


def main() -> None:
    parser = argparse.ArgumentParser(description="Prepare ColabFold multimer PDBs for ProAffinity")
    parser.add_argument(
        "-d",
        "--colabfold-dir",
        type=Path,
        default=DEFAULT_COLABFOLD_DIR,
        help=f"ColabFold output root (default: {DEFAULT_COLABFOLD_DIR})",
    )
    parser.add_argument(
        "--complex-dir",
        type=Path,
        default=DEFAULT_COMPLEX_DIR,
        help=f"Clean PDB output dir (default: {DEFAULT_COMPLEX_DIR})",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=DEFAULT_INDEX,
        help=f"Index TSV output (default: {DEFAULT_INDEX})",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print planned work without writing files")
    args = parser.parse_args()

    entries = scan_colabfold_dir(args.colabfold_dir)
    if not entries:
        print(f"ERROR: no ColabFold PDBs found under {args.colabfold_dir}", file=sys.stderr)
        sys.exit(1)

    index_lines: list[str] = []
    skipped: list[str] = []

    print(f"Preparing {len(entries)} ColabFold PDBs from {args.colabfold_dir}:", file=sys.stderr)

    for entry in entries:
        pdb_id = entry["pdb_id"]
        source_chains = entry["source_chains"]
        rank = entry["rank"]
        pdb_file = entry["pdb_file"]

        generic_chains = atom_chain_ids(pdb_file)
        if len(generic_chains) != len(source_chains):
            skipped.append(f"{pdb_id} rank {rank} (chain count {generic_chains} != {source_chains})")
            print(f"  SKIP {pdb_id} rank {rank}: chain count mismatch", file=sys.stderr)
            continue

        chain_map = dict(zip(generic_chains, source_chains))
        target = source_chains[0]
        binder = source_chains[1:]
        if not binder:
            skipped.append(f"{pdb_id} rank {rank} (need at least 2 chains)")
            print(f"  SKIP {pdb_id} rank {rank}: need at least 2 chains", file=sys.stderr)
            continue

        spec = f"{','.join(binder)};{target}"
        stem = f"{pdb_id.lower()}_rank{rank}"
        rel_pdb = Path(relpath_for_display(args.complex_dir, PROJECT_DIR)) / f"{stem}.pdb"
        dest = args.complex_dir / f"{stem}.pdb"

        lines = remap_pdb_lines(pdb_file, chain_map)
        n_atoms = sum(1 for line in lines if line.startswith("ATOM"))
        print(
            f"  OK   {pdb_id} rank {rank}: {spec} map={chain_map} ({n_atoms} atoms -> {rel_pdb})",
            file=sys.stderr,
        )

        if not args.dry_run:
            args.complex_dir.mkdir(parents=True, exist_ok=True)
            dest.write_text("\n".join(lines) + "\n")
        index_lines.append(f"{rel_pdb}\t{spec}")

    if skipped:
        print(f"\nSkipped {len(skipped)}:", file=sys.stderr)
        for item in skipped:
            print(f"  {item}", file=sys.stderr)

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
    print(f"\nWrote {len(index_lines)} PDBs -> {args.complex_dir}", file=sys.stderr)
    print(f"Wrote index -> {args.output}", file=sys.stderr)
    print(
        "\nNext steps:\n"
        f"  ./scripts/prebuild_pdbqt.sh {relpath_for_display(args.output, PROJECT_DIR)}\n"
        f"  ./scripts/submit_test.sh {relpath_for_display(args.output, PROJECT_DIR)}\n"
        f"  ./scripts/submit_array.sh {relpath_for_display(args.output, PROJECT_DIR)}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
