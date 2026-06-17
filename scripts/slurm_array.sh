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

# --- SLURM directives (Rorqual / Alliance H100 MIG) ----------------------
#SBATCH --job-name=proaffinity
#SBATCH --gpus=nvidia_h100_80gb_hbm3_2g.20gb:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=00:30:00
#SBATCH --output=slurm-infer_%A_%a.out
#SBATCH --error=slurm-infer_%A_%a.err
#SBATCH --export=ALL
# Account: set via submit_array.sh (PROAFFINITY_SLURM_ACCOUNT or --account=...)
# Larger options if the 20 GB MIG slice is not enough:
##SBATCH --gpus=h100:1
##SBATCH --gpus=nvidia_h100_80gb_hbm3_3g.40gb:1

set -euo pipefail

# --- arguments ---------------------------------------------------------
if [ $# -lt 2 ]; then
    echo "Usage: sbatch --array=1-<N> $0 <index_file> <output_dir>" >&2
    echo "  index_file   TSV: pdb_file<TAB>chain_spec" >&2
    echo "  output_dir   Where to write per-task results and results.tsv" >&2
    exit 1
fi

INDEX_FILE="$(realpath "$1")"
OUTPUT_DIR="$2"
TASK_ID="${SLURM_ARRAY_TASK_ID:-1}"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# --- resolve project paths ---------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INDEX_DIR="$(dirname "$INDEX_FILE")"
if [ "$(basename "$INDEX_DIR")" = "data" ] && [ -d "${INDEX_DIR}/pdb" ]; then
    PROJECT_DIR="$(dirname "$INDEX_DIR")"
elif [ -n "${SLURM_SUBMIT_DIR:-}" ] && [ -d "${SLURM_SUBMIT_DIR}/data/pdb" ]; then
    PROJECT_DIR="${SLURM_SUBMIT_DIR}"
else
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
fi
INFERENCE_DIR="${PROJECT_DIR}/ProAffinity-GNN_inference"
PREDICT_ONE="${PROJECT_DIR}/scripts/predict_one.sh"

# Alliance modules (ADFR for PDB→PDBQT on custom structures)
if command -v module &>/dev/null; then
    module load StdEnv/2023 2>/dev/null || true
    module load adfrsuite 2>/dev/null || module load ADFRsuite 2>/dev/null || true
fi

# --- load environment --------------------------------------------------
echo "[task $TASK_ID] Loading Python environment..." >&2
# shellcheck disable=SC1091
source "${PROJECT_DIR}/scripts/activate_env.sh"

# HuggingFace: use login-node cache only (compute nodes have no internet)
# Model lands in $HF_HOME/models--* when TRANSFORMERS_CACHE=$HF_HOME (not under hub/)
export HF_HOME="${HF_HOME:-${HOME}/.cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-${HF_HOME}}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-${HF_HOME}}"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
echo "[task $TASK_ID] HF_HOME=$HF_HOME HUGGINGFACE_HUB_CACHE=$HUGGINGFACE_HUB_CACHE" >&2
python -c "from transformers import AutoTokenizer; AutoTokenizer.from_pretrained('facebook/esm2_t33_650M_UR50D', local_files_only=True); print('[task ${TASK_ID}] ESM-2 cache OK')" >&2 \
    || { echo "[task $TASK_ID] FATAL: ESM-2 not cached at HF_HOME=$HF_HOME — download on login node first" >&2; exit 10; }

# --- read the assigned line from the index file ------------------------
LINE_COUNT=$(awk 'END { print NR }' "$INDEX_FILE")
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
# --- handle relative / bare-name paths in index file -------------------
# Try, in order: as-is, .pdb suffix, .ent.pdb suffix, relative to index dir, etc.
resolve_pdb() {
    local f="$1"
    local dir="$2"
    local proj="$3"
    # Exact path
    [ -f "$f" ] && echo "$f" && return 0
    # Try extension suffixes
    [ -f "${f}.pdb" ] && echo "${f}.pdb" && return 0
    [ -f "${f}.ent.pdb" ] && echo "${f}.ent.pdb" && return 0
    # Relative to index file directory (index often lives in data/)
    [ -f "${dir}/${f}" ] && echo "${dir}/${f}" && return 0
    [ -f "${dir}/${f}.pdb" ] && echo "${dir}/${f}.pdb" && return 0
    [ -f "${dir}/${f}.ent.pdb" ] && echo "${dir}/${f}.ent.pdb" && return 0
    [ -f "${dir}/pdb/${f}.pdb" ] && echo "${dir}/pdb/${f}.pdb" && return 0
    [ -f "${dir}/pdb/${f}.ent.pdb" ] && echo "${dir}/pdb/${f}.ent.pdb" && return 0
    # PROJECT_DIR-relative (for bare names and relative paths when running from any CWD)
    [ -f "${proj}/${f}" ] && echo "${proj}/${f}" && return 0
    [ -f "${proj}/${f}.pdb" ] && echo "${proj}/${f}.pdb" && return 0
    [ -f "${proj}/${f}.ent.pdb" ] && echo "${proj}/${f}.ent.pdb" && return 0
    [ -f "${proj}/data/pdb/${f}.pdb" ] && echo "${proj}/data/pdb/${f}.pdb" && return 0
    [ -f "${proj}/data/pdb/${f}.ent.pdb" ] && echo "${proj}/data/pdb/${f}.ent.pdb" && return 0
    [ -f "${proj}/samples/${f}.pdb" ] && echo "${proj}/samples/${f}.pdb" && return 0
    [ -f "${proj}/pdbs/${f}.pdb" ] && echo "${proj}/pdbs/${f}.pdb" && return 0
    [ -f "${proj}/data/${f}.pdb" ] && echo "${proj}/data/${f}.pdb" && return 0
    [ -f "${proj}/proteins/complexes/${f}" ] && echo "${proj}/proteins/complexes/${f}" && return 0
    [ -f "${proj}/proteins/complexes/${f}.pdb" ] && echo "${proj}/proteins/complexes/${f}.pdb" && return 0
    [ -f "${proj}/AF3Proteins/complexes/${f}" ] && echo "${proj}/AF3Proteins/complexes/${f}" && return 0
    [ -f "${proj}/AF3Proteins/complexes/${f}.pdb" ] && echo "${proj}/AF3Proteins/complexes/${f}.pdb" && return 0
    echo "$f"
    return 1
}

INDEX_DIR="$(dirname "$INDEX_FILE")"
PDB_FILE=$(resolve_pdb "$PDB_FILE" "$INDEX_DIR" "$PROJECT_DIR" || true)

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
    PKA_LINE=$(grep -i 'pKa:' "$TASK_OUT" | tail -1 || true)
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
    ERR_MSG=$(tail -5 "$TASK_OUT" | grep -i 'error\|ERROR' | tail -1 | cut -c1-120 || true)
    echo -e "${PDB_FILE}\t${CHAIN_SPEC}\t\tERROR: ${ERR_MSG:-exit code $RC}\t${ELAPSED}s" >> "$TASK_TSV"
    echo "[task $TASK_ID] FAILED — exit code $RC (${ELAPSED}s)" >&2
fi

echo "[task $TASK_ID] Done at $(date)" >&2
