#!/usr/bin/env python3
"""Prepare AlphaFold3 full-complex CIF models for ProAffinity.

AF3 outputs one mmCIF per fold with all chains in native binding geometry
(label_asym A, B, C, ... in job_request.json entity order). ProAffinity needs
PDB files with chain IDs matching antibody/antigen chain specs.

This script:
  1. Scans AF3Proteins/AF3 Structure_batch*/ folders
  2. Reads job_request.json for entity order
  3. Maps AF3 chains to ProAffinity chain letters (curated + heuristics)
  4. Converts model_<n>.cif to PDB in AF3Proteins/complexes/
  5. Writes a ProAffinity index TSV (pdb_path<TAB>chain_spec)

Usage:
    python scripts/prepare_af3_proteins.py --dry-run
    python scripts/prepare_af3_proteins.py --batches batch1
    python scripts/prepare_af3_proteins.py --batches batch1 --overlap-only
    python scripts/prepare_af3_proteins.py --batches batch1,batch2,batch3,batch4

Then on Fir:
    ./scripts/submit_test.sh data/index_af3_batch1.txt
    ./scripts/prebuild_pdbqt.sh data/index_af3_batch1.txt
    ./scripts/submit_array.sh data/index_af3_batch1.txt
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
DEFAULT_AF3_DIR = PROJECT_DIR / "AF3Proteins"
DEFAULT_COMPLEX_DIR = DEFAULT_AF3_DIR / "complexes"
DEFAULT_INDEX = PROJECT_DIR / "data" / "index_af3_batch1.txt"

BATCH_GLOB = "AF3 Structure_batch*"
AB_ORDER = "HLABDM"

# 18 complexes overlapping proteins/ — chain specs aligned with data/index_proteins.txt
# where possible; Fab complexes use full H+L when AF3 models both chains.
CHAIN_SPECS: dict[str, str] = {
    "1DZB": "A;X",
    "1I8K": "A,B;C",
    "1IQD": "A,B;C",
    "1JPS": "H,L;T",
    "1ZVY": "A;B",
    "2FX7": "H,L;P",
    "2FX9": "H,L;P",
    "2HKF": "H,L;P",
    "2NY1": "D,L;A",
    "2ZPK": "H,M;Q",
    "3G5V": "A,B;C",
    "3P0Y": "H,L;A",
    "3ZKQ": "D;A",
    "4G6M": "H,L;A",
    "5B71": "A,D;F",
    "5E8E": "A,B;H",
    "5FCU": "H,L;G",
    "5L6Y": "H,L;C",
}

# AF3 entity index (0-based) -> ProAffinity chain letter for the 18 overlap set.
# Derived by matching AF3 sequences to proteins/ ranked_0.pdb and crystal chain IDs.
AF3_ENTITY_CHAINS: dict[str, list[str]] = {
    "1DZB": ["X", "A"],
    "1I8K": ["C", "A", "B"],
    "1IQD": ["C", "A", "B"],
    "1JPS": ["T", "H", "L"],
    "1ZVY": ["B", "A"],
    "2FX7": ["P", "H", "L"],
    "2FX9": ["P", "H", "L"],
    "2HKF": ["P", "H", "L"],
    "2NY1": ["A", "D", "L"],
    "2ZPK": ["Q", "H", "M"],
    "3G5V": ["C", "A", "B"],
    "3P0Y": ["A", "H", "L"],
    "3ZKQ": ["A", "D"],
    "4G6M": ["A", "H", "L"],
    "5B71": ["F", "D", "A"],
    "5E8E": ["H", "A", "B"],
    "5FCU": ["G", "H", "L"],
    "5L6Y": ["C", "H", "L"],
}

# Batch1-only extras (same antigen as 3G5V; Fab-like triplets; 2-chain nanobodies)
BATCH1_EXTRA_SPECS: dict[str, str] = {
    "3G5Y": "A,B;C",
    "5IP4": "A;B",
    "6B0S": "H,L;A",
    "6DDM": "H,L;A",
    "6FLC": "H,L;A",
}

BATCH1_EXTRA_ENTITY_CHAINS: dict[str, list[str]] = {
    "3G5Y": ["C", "A", "B"],
    "5IP4": ["B", "A"],
    "6B0S": ["A", "H", "L"],
    "6DDM": ["A", "H", "L"],
    "6FLC": ["A", "H", "L"],
}

# MHC/peptide complexes — skip unless explicitly mapped
SKIP_PDBS = {"4JFF", "4MNQ"}

HEAVY_RE = re.compile(
    r"^(?:[ED]?[IV][VQ]L|QVQL|VQLV|VQLQ|EVQL|IQLV|EIIL|IQLQ|VQLI)",
)
LIGHT_RE = re.compile(
    r"^(?:[DY]?I[EQV]L|DIQMT|EIVLT|DIVMT|DVVMT|SVLTQ|YELTQ|YVLTQ|EIILT|TVVTQ|IALTQ|DILMT)",
)


def chain_sort_key(chain: str) -> tuple[int, str]:
    idx = AB_ORDER.find(chain)
    return (idx if idx >= 0 else len(AB_ORDER), chain)


def sort_antibody_chains(chains: list[str]) -> list[str]:
    return sorted(chains, key=chain_sort_key)


def chain_spec(antibody: list[str], antigen: list[str]) -> str:
    ab = ",".join(sort_antibody_chains(antibody))
    ag = ",".join(sorted(antigen))
    return f"{ab};{ag}"


def classify_entity(seq: str) -> str:
    if LIGHT_RE.match(seq):
        return "light"
    if HEAVY_RE.match(seq):
        return "heavy"
    return "antigen"


def infer_entity_chains(pdb_id: str, sequences: list[str]) -> tuple[list[str], str]:
    """Return per-entity ProAffinity chain letters and chain_spec."""
    if pdb_id in AF3_ENTITY_CHAINS:
        letters = AF3_ENTITY_CHAINS[pdb_id]
        if len(letters) != len(sequences):
            raise ValueError(f"entity count mismatch for {pdb_id}")
        spec = CHAIN_SPECS[pdb_id]
        return letters, spec

    if pdb_id in BATCH1_EXTRA_ENTITY_CHAINS:
        letters = BATCH1_EXTRA_ENTITY_CHAINS[pdb_id]
        spec = BATCH1_EXTRA_SPECS[pdb_id]
        return letters, spec

    roles = [classify_entity(s) for s in sequences]
    n_ab = sum(1 for r in roles if r in ("heavy", "light"))
    n_ag = sum(1 for r in roles if r == "antigen")

    letters: list[str] = []
    ab_used: list[str] = []
    ag_used: list[str] = []

    if len(sequences) == 2:
        if roles[0] == "antigen" and roles[1] in ("heavy", "light", "antigen"):
            if roles[1] == "antigen":
                # nanobody/single-domain: shorter IG-like chain is antibody
                if len(sequences[0]) >= len(sequences[1]):
                    roles = ["antigen", "heavy"]
                else:
                    roles = ["heavy", "antigen"]
            ag_used = ["B"]
            ab_used = ["A"]
            letters = ["B", "A"] if roles[0] == "antigen" else ["A", "B"]
        elif roles[1] == "antigen":
            ab_used = ["A"]
            ag_used = ["B"]
            letters = ["A", "B"]
        else:
            ab_used = ["A"]
            ag_used = ["B"]
            letters = ["A", "B"]
        return letters, chain_spec(ab_used, ag_used)

    # 3+ entities: typical Fab + antigen (antigen often first in AF3 server jobs)
    heavy_i = [i for i, r in enumerate(roles) if r == "heavy"]
    light_i = [i for i, r in enumerate(roles) if r == "light"]
    ag_i = [i for i, r in enumerate(roles) if r == "antigen"]

    if n_ab >= 2 and n_ag >= 1:
        ab_letters: dict[int, str] = {}
        if heavy_i:
            ab_letters[heavy_i[0]] = "H"
        if light_i:
            ab_letters[light_i[0]] = "L"
        for i, r in enumerate(roles):
            if r in ("heavy", "light") and i not in ab_letters:
                ab_letters[i] = "A"
        ag_letters = {i: chr(ord("A") + len(ab_letters) + j) for j, i in enumerate(ag_i)}
        # Prefer B for single antigen when H/L used
        if len(ag_i) == 1 and "H" in ab_letters.values() and "L" in ab_letters.values():
            ag_letters[ag_i[0]] = "A" if "A" not in ab_letters.values() else "B"
        letters = [""] * len(sequences)
        for i, ch in ab_letters.items():
            letters[i] = ch
            ab_used.append(ch)
        for i, ch in ag_letters.items():
            letters[i] = ch
            ag_used.append(ch)
        return letters, chain_spec(ab_used, ag_used)

    # fallback: label sequentially, last entity antigen if only one long chain
    letters = [chr(ord("A") + i) for i in range(len(sequences))]
    if n_ag == 1:
        ag_idx = roles.index("antigen")
        ag_used = [letters[ag_idx]]
        ab_used = [c for i, c in enumerate(letters) if i != ag_idx]
    else:
        ab_used = letters[:1]
        ag_used = letters[1:]
    return letters, chain_spec(ab_used, ag_used)


def scan_af3_dir(af3_dir: Path, batches: list[str] | None) -> list[dict]:
    """Find all AF3 fold directories across batch folders."""
    entries: list[dict] = []
    batch_dirs = sorted(af3_dir.glob(BATCH_GLOB))
    if batches:
        wanted = {b.lower().replace("batch", "") for b in batches}
        batch_dirs = [d for d in batch_dirs if any(f"batch{w}" in d.name.lower() for w in wanted)]

    for batch_dir in batch_dirs:
        batch_name = batch_dir.name.replace("AF3 Structure_", "")
        for fold_dir in sorted(batch_dir.iterdir()):
            if not fold_dir.is_dir():
                continue
            name = fold_dir.name
            if name.startswith("fold_"):
                pdb_id = name[5:].upper()
            else:
                pdb_id = name.upper()

            jr_files = sorted(fold_dir.glob("*job_request.json"))
            if not jr_files:
                continue

            cif_files = sorted(fold_dir.glob("*model_*.cif"))
            if not cif_files:
                continue

            entries.append(
                {
                    "pdb_id": pdb_id,
                    "batch": batch_name,
                    "fold_dir": fold_dir,
                    "job_request": jr_files[0],
                    "cif_files": cif_files,
                }
            )
    return entries


def read_job_request(path: Path) -> tuple[str, list[str]]:
    data = json.loads(path.read_text())
    job = data[0] if isinstance(data, list) else data
    name = job.get("name", path.parent.name).upper()
    sequences = [e["proteinChain"]["sequence"] for e in job["sequences"]]
    return name, sequences


def parse_mmcif_atom_site(path: Path) -> tuple[list[str], list[list[str]]]:
    """Parse _atom_site loop from mmCIF; return column names and row values."""
    lines = path.read_text().splitlines()
    i = 0
    while i < len(lines):
        if lines[i].strip() == "loop_":
            j = i + 1
            cols: list[str] = []
            while j < len(lines) and lines[j].startswith("_atom_site."):
                cols.append(lines[j].split(".", 1)[1])
                j += 1
            if cols:
                rows: list[list[str]] = []
                while j < len(lines):
                    stripped = lines[j].strip()
                    if not stripped or stripped.startswith("#") or stripped.startswith("_") or stripped == "loop_":
                        break
                    rows.append(stripped.split())
                    j += 1
                return cols, rows
        i += 1
    raise ValueError(f"no _atom_site loop in {path}")


def cif_to_pdb_lines(
    cif_path: Path,
    af3_to_pa: dict[str, str],
    pdb_id: str,
) -> list[str]:
    """Convert mmCIF atom_site records to PDB ATOM lines with remapped chains."""
    cols, rows = parse_mmcif_atom_site(cif_path)
    col_idx = {c: n for n, c in enumerate(cols)}

    required = ["group_PDB", "label_asym_id", "label_comp_id", "label_atom_id", "Cartn_x", "Cartn_y", "Cartn_z"]
    for req in required:
        if req not in col_idx:
            raise ValueError(f"missing _atom_site.{req} in {cif_path}")

    out: list[str] = [
        "REMARK   1 converted from AlphaFold3 mmCIF via prepare_af3_proteins.py",
        f"REMARK   1 source {cif_path.name}",
        f"REMARK   1 AF3 chain map {af3_to_pa}",
    ]
    serial = 0
    last_chain = ""
    last_res = ""
    last_pa_chain = ""

    for row in rows:
        if row[col_idx["group_PDB"]] not in ("ATOM", "HETATM"):
            continue

        af3_chain = row[col_idx["label_asym_id"]]
        pa_chain = af3_to_pa.get(af3_chain, af3_chain)
        resname = row[col_idx["label_comp_id"]]
        atom_name = row[col_idx["label_atom_id"]]
        x, y, z = row[col_idx["Cartn_x"]], row[col_idx["Cartn_y"]], row[col_idx["Cartn_z"]]

        res_seq = row[col_idx["auth_seq_id"]] if "auth_seq_id" in col_idx else row[col_idx.get("label_seq_id", 0)]
        if res_seq == "?":
            res_seq = "1"

        res_key = f"{pa_chain}:{resname}:{res_seq}"
        if res_key != last_res and last_res:
            serial += 1
            out.append(f"TER   {serial:5d}      {last_res[:3]:<3} {last_pa_chain}")
        last_res = f"{resname} {pa_chain}"
        last_pa_chain = pa_chain
        last_chain = pa_chain

        serial += 1
        element = row[col_idx["type_symbol"]] if "type_symbol" in col_idx else atom_name[0]
        line = (
            f"ATOM  {serial:5d} {atom_name:>4s} {resname:>3s} {pa_chain:1s}"
            f"{int(res_seq):4d}    {float(x):8.3f}{float(y):8.3f}{float(z):8.3f}"
            f"  1.00  0.00          {element:>2s}"
        )
        out.append(line)

    if last_chain:
        serial += 1
        out.append(f"TER   {serial:5d}      {last_res[:3]:<3} {last_pa_chain}")
    out.append("END")
    return out


def pick_model(cif_files: list[Path], model: int) -> Path:
    target = f"model_{model}.cif"
    for p in cif_files:
        if p.name.endswith(target):
            return p
    return sorted(cif_files)[0]


def main() -> None:
    parser = argparse.ArgumentParser(description="Prepare AF3Proteins for ProAffinity")
    parser.add_argument(
        "-d",
        "--af3-dir",
        type=Path,
        default=DEFAULT_AF3_DIR,
        help=f"AF3 output root (default: {DEFAULT_AF3_DIR})",
    )
    parser.add_argument(
        "--complex-dir",
        type=Path,
        default=DEFAULT_COMPLEX_DIR,
        help=f"Output PDB dir (default: {DEFAULT_COMPLEX_DIR})",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=DEFAULT_INDEX,
        help=f"Index TSV output (default: {DEFAULT_INDEX})",
    )
    parser.add_argument(
        "--batches",
        default="batch1",
        help="Comma-separated batch names, e.g. batch1 or batch1,batch2 (default: batch1)",
    )
    parser.add_argument(
        "--overlap-only",
        action="store_true",
        help="Only include the 18 complexes overlapping proteins/",
    )
    parser.add_argument(
        "--model",
        type=int,
        default=0,
        help="AF3 model index to use (default: 0)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned work without writing files",
    )
    args = parser.parse_args()

    batches = [b.strip() for b in args.batches.split(",") if b.strip()]
    if args.output == DEFAULT_INDEX and len(batches) == 1:
        batch_name = batches[0].lower()
        if not batch_name.startswith("batch"):
            batch_name = f"batch{batch_name}"
        args.output = PROJECT_DIR / "data" / f"index_af3_{batch_name}.txt"

    entries = scan_af3_dir(args.af3_dir, batches)
    if not entries:
        print(f"ERROR: no AF3 folds found under {args.af3_dir}", file=sys.stderr)
        sys.exit(1)

    overlap_set = set(CHAIN_SPECS)
    index_lines: list[str] = []
    skipped: list[str] = []

    print(
        f"Preparing AF3 complexes from {args.af3_dir} "
        f"(batches={','.join(batches)}, model={args.model}, overlap_only={args.overlap_only}):",
        file=sys.stderr,
    )

    for entry in entries:
        pdb_id = entry["pdb_id"]
        batch = entry["batch"]

        if args.overlap_only and pdb_id not in overlap_set:
            continue
        if pdb_id in SKIP_PDBS:
            skipped.append(f"{pdb_id} (MHC complex — add manual mapping to run)")
            print(f"  SKIP {pdb_id}: MHC/peptide complex needs manual chain map", file=sys.stderr)
            continue

        try:
            _, sequences = read_job_request(entry["job_request"])
            entity_chains, spec = infer_entity_chains(pdb_id, sequences)
        except (json.JSONDecodeError, KeyError, ValueError) as exc:
            skipped.append(f"{pdb_id} ({exc})")
            print(f"  SKIP {pdb_id}: {exc}", file=sys.stderr)
            continue

        af3_labels = [chr(ord("A") + i) for i in range(len(sequences))]
        af3_to_pa = dict(zip(af3_labels, entity_chains))

        cif_path = pick_model(entry["cif_files"], args.model)
        rel_pdb = args.complex_dir.relative_to(PROJECT_DIR) / f"{pdb_id.lower()}.pdb"
        dest = args.complex_dir / f"{pdb_id.lower()}.pdb"

        try:
            lines = cif_to_pdb_lines(cif_path, af3_to_pa, pdb_id)
        except (ValueError, OSError) as exc:
            skipped.append(f"{pdb_id} ({exc})")
            print(f"  SKIP {pdb_id}: {exc}", file=sys.stderr)
            continue

        n_atoms = sum(1 for ln in lines if ln.startswith("ATOM"))
        print(
            f"  OK   {pdb_id} [{batch}]: {spec}  map={af3_to_pa}  "
            f"({n_atoms} atoms -> {rel_pdb})",
            file=sys.stderr,
        )

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
    print(f"\nWrote {len(index_lines)} PDBs -> {args.complex_dir}", file=sys.stderr)
    print(f"Wrote index -> {args.output}", file=sys.stderr)
    out_rel = args.output if not args.output.is_absolute() else args.output.relative_to(PROJECT_DIR)
    print(
        "\nNext steps:\n"
        f"  ./scripts/prebuild_pdbqt.sh {out_rel}\n"
        f"  ./scripts/submit_test.sh {out_rel}\n"
        f"  ./scripts/submit_array.sh {out_rel}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
