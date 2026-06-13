#!/usr/bin/env python3
"""predict_batch.py — run ProAffinity-GNN on multiple PDBs.

Usage:
    # Index-file mode (explicit PDB + chain pairs)
    python scripts/predict_batch.py -i index.tsv -o results.tsv

    # Directory-scan mode (all .pdb files, fixed chain pair)
    python scripts/predict_batch.py -d /path/to/pdbs/ -c A,B -o results.tsv

    # With parallelism (local only — not needed when using SLURM)
    python scripts/predict_batch.py -i index.tsv -o results.tsv -p 4

    # Skip already-completed entries in the output file
    python scripts/predict_batch.py -i index.tsv -o results.tsv --skip-existing

Index file format (TSV, no header):
    pdb_file<TAB>chain_spec
    e.g.:
    /data/pdbs/1a22.pdb	A,B
    1a4y.pdb	B,A
    1ahw.pdb	AB,C

Output format (TSV):
    pdb_file<TAB>chain_spec<TAB>pKa<TAB>status
"""

import argparse
import csv
import os
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
PREDICT_ONE = SCRIPT_DIR / "predict_one.sh"


def run_one(pdb_file: str, chain_spec: str, timeout: int = 3600) -> tuple[str, str, str]:
    """Run predict_one.sh on a single PDB. Returns (pdb_file, pKa, status)."""
    if not os.path.isfile(pdb_file):
        return (pdb_file, "", f"ERROR: file not found: {pdb_file}")

    try:
        result = subprocess.run(
            ["bash", str(PREDICT_ONE), pdb_file, chain_spec],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return (pdb_file, "", f"ERROR: timeout ({timeout}s)")

    stdout = result.stdout.strip()
    stderr = result.stderr.strip()

    if result.returncode != 0:
        # Extract the last meaningful error line
        err_lines = [l for l in stderr.splitlines() if l]
        err_msg = err_lines[-1] if err_lines else f"exit code {result.returncode}"
        return (pdb_file, "", f"ERROR: {err_msg[:120]}")

    # Parse the pKa line: "pKa: 7.342"
    if stdout:
        for line in reversed(stdout.splitlines()):
            line = line.strip()
            if line.lower().startswith("pka"):
                parts = line.split(":", 1)
                if len(parts) == 2:
                    try:
                        pka_val = float(parts[1].strip())
                        return (pdb_file, str(round(pka_val, 3)), "OK")
                    except ValueError:
                        pass
        # If we got here, stdout didn't parse — return it as error
        return (pdb_file, "", f"ERROR: unparseable output: {stdout[:120]}")
    else:
        return (pdb_file, "", "ERROR: empty output from predict_one.sh")


def read_index(index_file: str) -> list[tuple[str, str]]:
    """Read the index TSV file. Returns list of (pdb_file, chain_spec)."""
    entries = []
    with open(index_file, "r") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                print(f"Warning: skipping line {line_no} (not enough columns): {line}", file=sys.stderr)
                continue
            pdb_file = parts[0].strip()
            chain_spec = parts[1].strip()
            # Remove trailing semicolons (present in some index formats)
            chain_spec = chain_spec.rstrip(";")
            # Convert semicolon-separated parts to the comma format used by -c
            # e.g. "B; A" → "B,A" or "L,H; I" → "LH,I"
            if ";" in chain_spec:
                parts_list = [p.strip().replace(" ", "").replace(",", "") for p in chain_spec.split(";") if p.strip()]
                chain_spec = ",".join(parts_list)
            entries.append((pdb_file, chain_spec))
    return entries


def scan_directory(pdb_dir: str, chain_spec: str) -> list[tuple[str, str]]:
    """Scan a directory for .pdb files with a fixed chain spec."""
    entries = []
    pdb_dir = os.path.abspath(pdb_dir)
    for fname in sorted(os.listdir(pdb_dir)):
        if fname.endswith(".pdb"):
            entries.append((os.path.join(pdb_dir, fname), chain_spec))
    return entries


def load_existing_results(output_file: str) -> set[tuple[str, str]]:
    """Load already-completed (pdb_file, chain_spec) pairs from existing output."""
    completed = set()
    if not os.path.isfile(output_file):
        return completed
    with open(output_file, "r") as f:
        reader = csv.reader(f, delimiter="\t")
        for row in reader:
            if len(row) >= 4 and row[3] == "OK":
                completed.add((row[0], row[1]))
    return completed


def main():
    parser = argparse.ArgumentParser(description="Batch ProAffinity-GNN inference")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("-i", "--index", help="Index TSV file (pdb<TAB>chain_spec)")
    group.add_argument("-d", "--directory", help="Directory of .pdb files")
    parser.add_argument("-c", "--chains", default="A,B", help="Chain spec for directory mode (default: A,B)")
    parser.add_argument("-o", "--output", required=True, help="Output TSV file")
    parser.add_argument("-p", "--parallel", type=int, default=1, help="Parallel workers (default: 1)")
    parser.add_argument("-t", "--timeout", type=int, default=3600, help="Timeout per PDB in seconds (default: 3600)")
    parser.add_argument("--skip-existing", action="store_true", help="Skip entries already marked OK in output")
    parser.add_argument("--dry-run", action="store_true", help="Print what would run, don't execute")
    args = parser.parse_args()

    # Collect entries
    if args.index:
        entries = read_index(args.index)
    else:
        entries = scan_directory(args.directory, args.chains)

    if not entries:
        print("ERROR: no PDB entries found.", file=sys.stderr)
        sys.exit(1)

    print(f"[predict_batch] {len(entries)} PDB(s) to process", file=sys.stderr)

    # Optionally skip existing
    if args.skip_existing and os.path.isfile(args.output):
        completed = load_existing_results(args.output)
        before = len(entries)
        entries = [e for e in entries if e not in completed]
        print(f"[predict_batch] Skipping {before - len(entries)} already-completed entries", file=sys.stderr)

    if args.dry_run:
        for pdb_file, chain_spec in entries:
            print(f"  [DRY RUN] {pdb_file}  chains={chain_spec}")
        sys.exit(0)

    # Run inference
    # Load previous results so we don't lose them on re-run
    previous_results: dict[tuple[str, str], tuple[str, str, str, str]] = {}
    if os.path.isfile(args.output):
        with open(args.output, "r") as f:
            reader = csv.reader(f, delimiter="\t")
            for row in reader:
                if len(row) >= 4:
                    previous_results[(row[0], row[1])] = (row[0], row[1], row[2], row[3])

    new_results: dict[tuple[str, str], tuple[str, str, str]] = {}
    start_time = time.time()

    if args.parallel > 1:
        with ProcessPoolExecutor(max_workers=args.parallel) as executor:
            futures = {
                executor.submit(run_one, pdb, chains, args.timeout): (pdb, chains)
                for pdb, chains in entries
            }
            for future in as_completed(futures):
                pdb_file, chains = futures[future]
                try:
                    pdb, pka, status = future.result()
                except Exception as e:
                    pdb, pka, status = pdb_file, "", f"ERROR: {e}"
                new_results[(pdb_file, chains)] = (pdb_file, pka, status)
                elapsed = time.time() - start_time
                done = len(new_results)
                print(f"  [{done}/{len(entries)}] {os.path.basename(pdb_file)}  {pka or status}  ({elapsed:.0f}s)", file=sys.stderr)
    else:
        for i, (pdb_file, chain_spec) in enumerate(entries):
            pdb, pka, status = run_one(pdb_file, chain_spec, args.timeout)
            new_results[(pdb_file, chain_spec)] = (pdb_file, pka, status)
            elapsed = time.time() - start_time
            print(f"  [{i+1}/{len(entries)}] {os.path.basename(pdb_file)}  {pka or status}  ({elapsed:.0f}s)", file=sys.stderr)

    # Merge: keep old entries not re-run, update re-run ones
    merged = dict(previous_results)
    for key, (pdb, pka, status) in new_results.items():
        merged[key] = (pdb, key[1], pka, status)

    # Write output
    with open(args.output, "w", newline="") as f:
        writer = csv.writer(f, delimiter="\t")
        for row in merged.values():
            writer.writerow(row)

    ok_count = sum(1 for r in merged.values() if r[3] == "OK")
    err_count = len(merged) - ok_count
    total_time = time.time() - start_time
    print(f"\n[predict_batch] Done. {ok_count} OK, {err_count} errors in {total_time:.0f}s → {args.output}", file=sys.stderr)

    if err_count > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
