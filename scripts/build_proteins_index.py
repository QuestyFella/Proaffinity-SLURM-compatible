#!/usr/bin/env python3
"""Build a ProAffinity index from the proteins/ AlphaFold output layout.

For AlphaFold models in proteins/, use prepare_proteins.py instead — it merges
per-chain ranked_*.pdb files into complex PDBs and writes the index.

This script is for experimental crystal structures from RCSB:
  1. Scans proteins/ folder names to discover which PDB complexes you have
  2. Writes an index TSV pointing at experimental PDB files
  3. Optionally downloads those PDBs from RCSB into proteins/pdb/

Index format (same as data/index_example.txt):
    pdb_path<TAB>antibody_chains;antigen_chains;

Usage:
    python scripts/build_proteins_index.py
    python scripts/build_proteins_index.py --download
    python scripts/build_proteins_index.py -o data/index_proteins.txt --download
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
DEFAULT_PROTEINS_DIR = PROJECT_DIR / "proteins"
DEFAULT_PDB_DIR = DEFAULT_PROTEINS_DIR / "pdb"
DEFAULT_INDEX = PROJECT_DIR / "data" / "index_proteins.txt"

# Curated chain pairs: antibody (part 1) ; antigen (part 2)
# Derived from folder names under proteins/ plus RCSB biological units.
# When a crystal has H+L but only one chain was modeled in proteins/, we still
# use the full Fab chain list so inference matches the real complex.
CHAIN_SPECS: dict[str, str] = {
    "1DZB": "A,B;X",      # Fab + turkey lysozyme
    "1I8K": "A,B;C",      # Fab + EGFRvIII peptide
    "1IQD": "A,B;C",      # Fab BO2C11 + factor VIII C2 domain
    "1JPS": "H,L;T",      # Fab + tissue factor
    "1ZVY": "A;B",        # antibody + lysozyme C
    "2FX7": "H,L;P",      # Fab + HIV gp41 fragment
    "2FX9": "H,L;P",
    "2HKF": "H,L;P",      # Fab + carbonic anhydrase IX
    "2NY1": "D;A",        # antibody + HIV gp120
    "2ZPK": "M;Q",        # antibody + PAR4
    "3G5V": "A,B;C",      # Fab + EGFR peptide
    "3P0Y": "H,L;A",      # Fab + EGFR
    "3ZKQ": "D;A",        # antibody + BACE2
    "4G6M": "H,L;A",      # Fab + IL-1 beta
    "5B71": "A,D;F",      # Fab (light A + heavy D) + complement C5 beta
    "5E8E": "A,B;H",      # Fab + thrombin heavy chain
    "5FCU": "H,L;G",      # Fab + HIV gp120 core
    "5L6Y": "H,L;C",      # Fab + IL-13
}


def scan_proteins_dir(proteins_dir: Path) -> dict[str, list[dict]]:
    """Group proteins/ subfolders by PDB ID."""
    groups: dict[str, list[dict]] = defaultdict(list)
    if not proteins_dir.is_dir():
        return groups

    pattern = re.compile(r"^\d+_([0-9A-Z]+)_(.+)_chain([A-Z0-9]+)$")
    for name in sorted(proteins_dir.iterdir()):
        if not name.is_dir():
            continue
        m = pattern.match(name.name)
        if not m:
            continue
        pdb_id, desc, chain = m.group(1), m.group(2), m.group(3)
        role = "antibody" if "antibody" in desc else "antigen"
        groups[pdb_id].append(
            {
                "folder": name.name,
                "role": role,
                "chain": chain,
                "desc": desc.replace("_", " "),
            }
        )
    return groups


def download_pdb(pdb_id: str, pdb_dir: Path) -> Path:
    pdb_dir.mkdir(parents=True, exist_ok=True)
    dest = pdb_dir / f"{pdb_id.lower()}.pdb"
    if dest.is_file() and dest.stat().st_size > 0:
        return dest
    url = f"https://files.rcsb.org/download/{pdb_id}.pdb"
    print(f"  downloading {url} → {dest}", file=sys.stderr)
    subprocess.run(
        ["curl", "-fsSL", "-o", str(dest), url],
        check=True,
    )
    return dest


def pdb_chains(pdb_path: Path) -> set[str]:
    chains: set[str] = set()
    with pdb_path.open() as f:
        for line in f:
            if line.startswith("ATOM"):
                chains.add(line[21])
    return chains


def validate_spec(pdb_id: str, spec: str, chains: set[str]) -> list[str]:
    warnings: list[str] = []
    parts = [p.strip() for p in spec.split(";") if p.strip()]
    for part in parts:
        for ch in part.replace(",", ""):
            if ch not in chains:
                warnings.append(f"{pdb_id}: chain {ch} not in PDB (have {''.join(sorted(chains))})")
    return warnings


def main() -> None:
    parser = argparse.ArgumentParser(description="Build ProAffinity index from proteins/")
    parser.add_argument(
        "-d",
        "--proteins-dir",
        type=Path,
        default=DEFAULT_PROTEINS_DIR,
        help=f"AlphaFold output root (default: {DEFAULT_PROTEINS_DIR})",
    )
    parser.add_argument(
        "--pdb-dir",
        type=Path,
        default=DEFAULT_PDB_DIR,
        help=f"Where to store/download experimental PDBs (default: {DEFAULT_PDB_DIR})",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=DEFAULT_INDEX,
        help=f"Output index TSV (default: {DEFAULT_INDEX})",
    )
    parser.add_argument(
        "--download",
        action="store_true",
        help="Download missing experimental PDB files from RCSB",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print summary only; do not write index or download",
    )
    args = parser.parse_args()

    groups = scan_proteins_dir(args.proteins_dir)
    if not groups:
        print(f"ERROR: no protein subfolders found under {args.proteins_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(groups)} PDB complexes in {args.proteins_dir}:", file=sys.stderr)
    for pdb_id in sorted(groups):
        entries = groups[pdb_id]
        ab = [e["chain"] for e in entries if e["role"] == "antibody"]
        ag = [e["chain"] for e in entries if e["role"] == "antigen"]
        spec = CHAIN_SPECS.get(pdb_id, "")
        print(
            f"  {pdb_id}: modeled chains antibody={ab} antigen={ag}"
            + (f"  → index {spec}" if spec else "  → NO CHAIN SPEC"),
            file=sys.stderr,
        )

    missing_specs = sorted(set(groups) - set(CHAIN_SPECS))
    if missing_specs:
        print(f"ERROR: add CHAIN_SPECS for: {', '.join(missing_specs)}", file=sys.stderr)
        sys.exit(1)

    lines: list[str] = []
    all_warnings: list[str] = []

    for pdb_id in sorted(groups):
        spec = CHAIN_SPECS[pdb_id]
        rel_pdb = args.pdb_dir.relative_to(PROJECT_DIR) / f"{pdb_id.lower()}.pdb"
        pdb_path = args.pdb_dir / f"{pdb_id.lower()}.pdb"

        if args.download and not args.dry_run:
            download_pdb(pdb_id, args.pdb_dir)

        if pdb_path.is_file():
            all_warnings.extend(validate_spec(pdb_id, spec, pdb_chains(pdb_path)))
        elif not args.dry_run:
            all_warnings.append(f"{pdb_id}: PDB not found at {pdb_path} (run with --download)")

        lines.append(f"{rel_pdb}\t{spec}")

    if all_warnings:
        print("\nWarnings:", file=sys.stderr)
        for w in all_warnings:
            print(f"  {w}", file=sys.stderr)

    if args.dry_run:
        print("\nIndex preview:", file=sys.stderr)
        for line in lines:
            print(line)
        return

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n")
    print(f"\nWrote {len(lines)} entries → {args.output}", file=sys.stderr)
    print(
        "\nNext steps:\n"
        f"  python scripts/build_proteins_index.py --download   # if PDBs not fetched yet\n"
        f"  ./scripts/submit_test.sh {args.output.relative_to(PROJECT_DIR)}\n"
        f"  ./scripts/submit_array.sh {args.output.relative_to(PROJECT_DIR)}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
