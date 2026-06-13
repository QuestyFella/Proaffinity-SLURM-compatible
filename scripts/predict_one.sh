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
#   - ADFR suite (prepare_receptor on PATH or set $ADFR_PREPARE_RECEPTOR)
#   - conda environment 'python3.8' (set $CONDA_ENV to override)
#   - ProAffinity-GNN_inference/ directory with model.pkl
# =============================================================================

set -euo pipefail

# --- configurable paths ------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INFERENCE_DIR="${PROJECT_DIR}/ProAffinity-GNN_inference"

ADFR_PREPARE_RECEPTOR="${ADFR_PREPARE_RECEPTOR:-prepare_receptor}"
CONDA_ENV="${CONDA_ENV:-python3.8}"
CONDA_BASE="${CONDA_BASE:-${HOME}/anaconda3}"

# --- activate conda environment (for standalone use) -------------------
if [ -f "${CONDA_BASE}/etc/profile.d/conda.sh" ]; then
    source "${CONDA_BASE}/etc/profile.d/conda.sh"
    conda activate "$CONDA_ENV" 2>/dev/null || true
elif command -v conda &>/dev/null; then
    eval "$(conda shell.bash hook)" 2>/dev/null || true
    conda activate "$CONDA_ENV" 2>/dev/null || true
fi

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
PDB_BASENAME="$(basename "$PDB_FILE" .pdb)"
WORK_DIR="$(mktemp -d -t proaffinity_XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

PDBQT_FILE="${WORK_DIR}/${PDB_BASENAME}.pdbqt"

# --- step 1: PDB → PDBQT (ADFR prepare_receptor) ----------------------
echo "[predict_one] Converting PDB → PDBQT: $PDB_FILE" >&2

if ! command -v "$ADFR_PREPARE_RECEPTOR" &>/dev/null; then
    echo "ERROR: ADFR prepare_receptor not found ('$ADFR_PREPARE_RECEPTOR')." >&2
    echo "       Install ADFR or set ADFR_PREPARE_RECEPTOR to the full path." >&2
    exit 3
fi

"$ADFR_PREPARE_RECEPTOR" -r "$PDB_FILE" -A hydrogens -o "$PDBQT_FILE" 2>&1 | tail -5 >&2

if [ ! -s "$PDBQT_FILE" ]; then
    echo "ERROR: prepare_receptor produced an empty PDBQT file." >&2
    exit 4
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
