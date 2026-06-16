#!/usr/bin/env bash
# =============================================================================
# predict_one.sh — run ProAffinity-GNN on a single PDB file
# =============================================================================
# Usage:
#   ./scripts/predict_one.sh <pdb_file> <chain_spec>
#
# Arguments:
#   pdb_file    Path to a .pdb file (e.g. /data/pdbs/1a22.pdb)
#   chain_spec  Comma-separated chain pair, e.g. "A,B" means
#               part1 = chain A, part2 = chain B
#
# Output:
#   Prints a single line:  pKa:<value>  (e.g. "pKa:7.342")
#   Exit code 0 on success, non-zero on failure.
#
# Dependencies:
#   - ADFR prepare_receptor (or pre-built data/pdbqt/*_atom_processed.pdbqt)
#   - Python env with torch, torch_geometric, transformers (see scripts/activate_env.sh)
#   - ProAffinity-GNN_inference/ directory with model.pkl
# =============================================================================

set -euo pipefail

# --- configurable paths ------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INFERENCE_DIR="${PROJECT_DIR}/ProAffinity-GNN_inference"

ADFR_PREPARE_RECEPTOR="${ADFR_PREPARE_RECEPTOR:-}"

# --- activate Python environment ---------------------------------------
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/activate_env.sh"

# --- usage -------------------------------------------------------------
usage() {
    echo "Usage: $0 <pdb_file> <chain_spec>"
    echo "  pdb_file     Path to a .pdb file"
    echo "  chain_spec   Chain pair, e.g. 'A,B' (part1=A, part2=B)"
    exit 1
}

# --- check arguments ---------------------------------------------------
if [ $# -ne 2 ]; then
    usage
fi

PDB_FILE="$1"
CHAIN_SPEC="$2"

if [ ! -f "$PDB_FILE" ]; then
    echo "ERROR: PDB file not found: $PDB_FILE" >&2
    exit 2
fi

# --- resolve paths -----------------------------------------------------
PDB_FILE="$(realpath "$PDB_FILE")"
PDB_BASENAME="$(basename "$PDB_FILE")"
PDB_ID="${PDB_BASENAME%.pdb}"
PDB_ID="${PDB_ID%.ent}"
PDB_ID="${PDB_ID,,}"
WORK_DIR="$(mktemp -d -t proaffinity_XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

PDBQT_FILE="${WORK_DIR}/${PDB_BASENAME}.pdbqt"
USE_EXISTING_PDBQT=""

# Pre-built PDBQT shipped with the repo (e.g. data/pdbqt/1a22_atom_processed.pdbqt)
for candidate in \
    "${PROJECT_DIR}/data/pdbqt/${PDB_ID}_atom_processed.pdbqt" \
    "${PROJECT_DIR}/data/pdbqt/${PDB_ID}.pdbqt"; do
    if [ -s "$candidate" ]; then
        PDBQT_FILE="$candidate"
        USE_EXISTING_PDBQT=1
        echo "[predict_one] Using pre-built PDBQT: $PDBQT_FILE" >&2
        break
    fi
done

_find_prepare_receptor() {
    local pr="${ADFR_PREPARE_RECEPTOR:-prepare_receptor}"
    if command -v "$pr" &>/dev/null; then
        echo "$pr"
        return 0
    fi
    if [ -n "${HPC_ADFRSUITE_BIN:-}" ] && [ -x "${HPC_ADFRSUITE_BIN}/prepare_receptor" ]; then
        echo "${HPC_ADFRSUITE_BIN}/prepare_receptor"
        return 0
    fi
    if command -v module &>/dev/null; then
        module load StdEnv/2023 2>/dev/null || true
        module load adfrsuite 2>/dev/null || module load ADFRsuite 2>/dev/null || true
        if command -v prepare_receptor &>/dev/null; then
            echo prepare_receptor
            return 0
        fi
    fi
    return 1
}

# --- step 1: PDB → PDBQT (ADFR prepare_receptor) ----------------------
if [ -z "$USE_EXISTING_PDBQT" ]; then
    echo "[predict_one] Converting PDB → PDBQT: $PDB_FILE" >&2

    if ! ADFR_PREPARE_RECEPTOR="$(_find_prepare_receptor || true)"; then
        echo "ERROR: ADFR prepare_receptor not found." >&2
        echo "  On Rorqual try: module spider adfrsuite" >&2
        echo "  Then:           module load adfrsuite" >&2
        echo "  Or set:         export ADFR_PREPARE_RECEPTOR=/path/to/prepare_receptor" >&2
        exit 3
    fi

    "$ADFR_PREPARE_RECEPTOR" -r "$PDB_FILE" -A hydrogens -o "$PDBQT_FILE" 2>&1 | tail -5 >&2

    if [ ! -s "$PDBQT_FILE" ]; then
        echo "ERROR: prepare_receptor produced an empty PDBQT file." >&2
        exit 4
    fi
fi

# --- step 2: run ProAffinity-GNN inference -----------------------------
echo "[predict_one] Running GNN inference on chains: $CHAIN_SPEC" >&2

cd "$INFERENCE_DIR"

# The inference script prints "pKa: <value>" to stdout and also writes
# a result file. We capture stdout and extract the pKa line.
STDOUT_LOG="${WORK_DIR}/inference_stdout.txt"

set +e
python ProAffinity-GNN_inference.py -f "$PDBQT_FILE" -c "$CHAIN_SPEC" > "$STDOUT_LOG" 2>&1
RC=$?
set -e

if [ $RC -ne 0 ]; then
    echo "ERROR: Inference script failed (exit code $RC)." >&2
    echo "--- stdout/stderr ---" >&2
    cat "$STDOUT_LOG" >&2
    echo "--- end ---" >&2
    exit 5
fi

# --- step 3: extract and print the pKa value ---------------------------
PKA_LINE=$(grep -i 'pKa:' "$STDOUT_LOG" | tail -1)

if [ -z "$PKA_LINE" ]; then
    echo "ERROR: Could not find pKa value in inference output." >&2
    cat "$STDOUT_LOG" >&2
    exit 6
fi

echo "$PKA_LINE"
exit 0
