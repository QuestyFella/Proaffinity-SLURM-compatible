#!/usr/bin/env bash
# =============================================================================
# slurm_array.sh — SLURM array job for ProAffinity-GNN inference
# =============================================================================
# Submit with:
#   sbatch --array=1-<N> scripts/slurm_array.sh <index_file> <output_dir>
#
# The index file is a TSV where each line is:
#   pdb_file<TAB>chain_spec
# Line N corresponds to array task ID N.
#
# Each task writes its result to <output_dir>/task_<TASK_ID>.txt and
# appends a line to <output_dir>/results.tsv.
# =============================================================================

# --- SLURM directives --------------------------------------------------
#SBATCH --job-name=proaffinity
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --output=logs/slurm_%A_%a.out
#SBATCH --error=logs/slurm_%A_%a.err
#SBATCH --export=ALL

# Uncomment and adjust as needed:
##SBATCH --partition=gpu
##SBATCH --account=your_account
##SBATCH --constraint=a100

set -euo pipefail

# --- arguments ---------------------------------------------------------
if [ $# -lt 2 ]; then
    echo "Usage: sbatch --array=1-<N> $0 <index_file> <output_dir>" >&2
    echo "  index_file   TSV: pdb_file<TAB>chain_spec" >&2
    echo "  output_dir   Where to write per-task results and results.tsv" >&2
    exit 1
fi

INDEX_FILE="$(realpath "$1")"
OUTPUT_DIR="$(realpath "$2")"
TASK_ID="${SLURM_ARRAY_TASK_ID:-1}"

mkdir -p "$OUTPUT_DIR"
mkdir -p logs

# --- resolve project paths ---------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INFERENCE_DIR="${PROJECT_DIR}/ProAffinity-GNN_inference"
PREDICT_ONE="${SCRIPT_DIR}/predict_one.sh"

# --- load environment --------------------------------------------------
echo "[task $TASK_ID] Loading conda environment..." >&2

# Try to locate conda — adjust CONDA_BASE if needed
CONDA_BASE="${CONDA_BASE:-${HOME}/anaconda3}"
if [ -f "${CONDA_BASE}/etc/profile.d/conda.sh" ]; then
    source "${CONDA_BASE}/etc/profile.d/conda.sh"
    conda activate python3.8
elif command -v conda &>/dev/null; then
    # conda is on PATH but may not be initialised in non-interactive shell
    eval "$(conda shell.bash hook)"
    conda activate python3.8
else
    echo "[task $TASK_ID] WARNING: conda not found — assuming environment is already active" >&2
fi

# Verify key dependencies are available
python -c "import torch; print(f'PyTorch {torch.__version__}  CUDA={torch.cuda.is_available()}')" >&2
if ! python -c "import torch; assert torch.cuda.is_available(), 'CUDA not available'" 2>/dev/null; then
    echo "[task $TASK_ID] FATAL: CUDA not available — ESM-2 650M on CPU will OOM or timeout" >&2
    exit 9
fi
python -c "import torch_geometric; print(f'PyG {torch_geometric.__version__}')" >&2

# --- read the assigned line from the index file ------------------------
LINE_COUNT=$(wc -l < "$INDEX_FILE")
if [ "$TASK_ID" -gt "$LINE_COUNT" ]; then
    echo "[task $TASK_ID] TASK_ID ($TASK_ID) exceeds index file line count ($LINE_COUNT) — nothing to do" >&2
    exit 0
fi

INDEX_LINE=$(sed -n "${TASK_ID}p" "$INDEX_FILE")
PDB_FILE=$(echo "$INDEX_LINE" | cut -f1)
CHAIN_SPEC=$(echo "$INDEX_LINE" | cut -f2)

# Clean up chain spec: remove trailing semicolons, convert semicolons to commas.
# The index file uses ';' to separate parts and ',' to join chains within a part.
# The inference script -c flag uses ',' to separate parts and concatenates chains
# within each part (e.g. 'AB,C'). So 'L,H; I' → 'LH,I', not 'L,H,I'.
CHAIN_SPEC="${CHAIN_SPEC%;}"
CHAIN_SPEC="${CHAIN_SPEC// /}"
if [[ "$CHAIN_SPEC" == *";"* ]]; then
    # Convert: replace intra-part commas, then convert ';' to ','
    IFS=';' read -ra PARTS <<< "$CHAIN_SPEC"
    CHAIN_SPEC=""
    for part in "${PARTS[@]}"; do
        part="${part//,/}"  # collapse intra-part commas (e.g. 'L,H' → 'LH')
        if [ -n "$CHAIN_SPEC" ]; then
            CHAIN_SPEC="${CHAIN_SPEC},${part}"
        else
            CHAIN_SPEC="$part"
        fi
    done
fi

if [ -z "$PDB_FILE" ] || [ -z "$CHAIN_SPEC" ]; then
    echo "[task $TASK_ID] ERROR: could not parse index line: $INDEX_LINE" >&2
    echo -e "${PDB_FILE:-UNKNOWN}\t${CHAIN_SPEC:-UNKNOWN}\t\tERROR: bad index line" > "${OUTPUT_DIR}/task_${TASK_ID}.tsv"
    exit 2
fi

echo "[task $TASK_ID] PDB: $PDB_FILE  chains: $CHAIN_SPEC" >&2

# --- handle relative paths in index file -------------------------------
# If PDB_FILE is relative, resolve it relative to the index file's directory
if [[ "$PDB_FILE" != /* ]]; then
    INDEX_DIR="$(dirname "$INDEX_FILE")"
    if [ -f "${INDEX_DIR}/${PDB_FILE}" ]; then
        PDB_FILE="${INDEX_DIR}/${PDB_FILE}"
    fi
fi

if [ ! -f "$PDB_FILE" ]; then
    echo "[task $TASK_ID] ERROR: PDB file not found: $PDB_FILE" >&2
    echo -e "${PDB_FILE}\t${CHAIN_SPEC}\t\tERROR: file not found" > "${OUTPUT_DIR}/task_${TASK_ID}.tsv"
    exit 3
fi

# --- run inference -----------------------------------------------------
TASK_OUT="${OUTPUT_DIR}/task_${TASK_ID}.txt"

echo "[task $TASK_ID] Starting inference at $(date)" >&2

START_TS=$(date +%s)

set +e
bash "$PREDICT_ONE" "$PDB_FILE" "$CHAIN_SPEC" > "$TASK_OUT" 2>&1
RC=$?
set -e

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))

# --- write per-task result TSV (avoids concurrent-write corruption) ----
TASK_TSV="${OUTPUT_DIR}/task_${TASK_ID}.tsv"

echo "# pdb_file	chain_spec	pKa	status	elapsed" > "$TASK_TSV"

if [ $RC -eq 0 ]; then
    PKA_LINE=$(grep -i 'pKa:' "$TASK_OUT" | tail -1)
    if [ -n "$PKA_LINE" ]; then
        PKA_VAL=$(echo "$PKA_LINE" | sed 's/.*pKa:\s*//i')
        echo -e "${PDB_FILE}\t${CHAIN_SPEC}\t${PKA_VAL}\tOK\t${ELAPSED}s" >> "$TASK_TSV"
        echo "[task $TASK_ID] SUCCESS — pKa: $PKA_VAL (${ELAPSED}s)" >&2
    else
        echo -e "${PDB_FILE}\t${CHAIN_SPEC}\t\tERROR: no pKa in output\t${ELAPSED}s" >> "$TASK_TSV"
        echo "[task $TASK_ID] FAILED — no pKa found in output" >&2
    fi
else
    # Extract a short error message from the log
    ERR_MSG=$(tail -5 "$TASK_OUT" | grep -i 'error\|ERROR' | tail -1 | cut -c1-120)
    echo -e "${PDB_FILE}\t${CHAIN_SPEC}\t\tERROR: ${ERR_MSG:-exit code $RC}\t${ELAPSED}s" >> "$TASK_TSV"
    echo "[task $TASK_ID] FAILED — exit code $RC (${ELAPSED}s)" >&2
fi

echo "[task $TASK_ID] Done at $(date)" >&2
