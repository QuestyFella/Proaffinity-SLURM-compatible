#!/usr/bin/env bash
# =============================================================================
# submit_array.sh — submit ProAffinity-GNN SLURM array job
# =============================================================================
# Usage:
#   ./scripts/submit_array.sh <index_file> [output_dir] [sbatch_extra_args...]
#
# The index file is a TSV where each line is:
#   pdb_file<TAB>chain_spec
#
# The script counts the lines, submits a SLURM array job (1..N), and prints
# the job ID.
#
# Examples:
#   # Basic usage
#   ./scripts/submit_array.sh my_pdbs.tsv
#
#   # Custom output directory
#   ./scripts/submit_array.sh my_pdbs.tsv results/run1
#
#   export PROAFFINITY_SLURM_ACCOUNT=def-yourgroup-ab   # or pass --account= on the command line
#   ./scripts/submit_array.sh my_pdbs.tsv output/ --time=02:00:00
#
#   # Default uses a 20 GB H100 MIG slice and runs at most 2 tasks concurrently.
#   # Override concurrency if needed:
#   PROAFFINITY_ARRAY_CONCURRENCY=1 ./scripts/submit_array.sh my_pdbs.tsv
#
#   # Override to a full H100 if the MIG slice is not enough:
#   ./scripts/submit_array.sh my_pdbs.tsv output/ \
#       --gpus=h100:1 --mem=32G --cpus-per-task=8
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLURM_SCRIPT="${SCRIPT_DIR}/slurm_array.sh"

# --- usage -------------------------------------------------------------
usage() {
    echo "Usage: $0 <index_file> [output_dir] [sbatch_extra_args...]"
    echo ""
    echo "  index_file     TSV file: pdb_file<TAB>chain_spec"
    echo "  output_dir     Where results go (default: results/<timestamp>)"
    echo "  sbatch args    Passed through to sbatch (--account, --gpus, --time, etc.)"
    echo ""
    echo "Environment (set before submit, exported via --export=ALL):"
    echo "  export PROAFFINITY_SLURM_ACCOUNT=def-yourgroup-ab   # required unless --account= passed"
    echo "  export PROAFFINITY_VENV=\$HOME/proaffinity-env"
    echo ""
    echo "Examples (Alliance H100 MIG on Rorqual):"
    echo "  export PROAFFINITY_SLURM_ACCOUNT=def-yourgroup-ab"
    echo "  $0 my_pdbs.tsv"
    echo "  $0 my_pdbs.tsv results/run1"
    echo "  PROAFFINITY_ARRAY_CONCURRENCY=1 $0 my_pdbs.tsv"
    echo "  $0 my_pdbs.tsv output/ --gpus=h100:1 --mem=32G"
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

INDEX_FILE="$1"
shift

# --- validate index file -----------------------------------------------
if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: Index file not found: $INDEX_FILE" >&2
    exit 2
fi

INDEX_FILE="$(realpath "$INDEX_FILE")"

# --- output directory --------------------------------------------------
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    OUTPUT_DIR="$1"
    shift
else
    OUTPUT_DIR="results/$(date +%Y%m%d_%H%M%S)"
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# --- count entries -----------------------------------------------------
# Count physical lines (must match the job script's sed line reading)
TOTAL=$(awk 'END { print NR }' "$INDEX_FILE")
if [ "$TOTAL" -eq 0 ]; then
    echo "ERROR: Index file is empty: $INDEX_FILE" >&2
    exit 3
fi

# --- submit ------------------------------------------------------------
ARRAY_CONCURRENCY="${PROAFFINITY_ARRAY_CONCURRENCY:-2}"
if [[ "$ARRAY_CONCURRENCY" =~ ^[0-9]+$ ]] && [ "$ARRAY_CONCURRENCY" -gt 0 ]; then
    ARRAY_SPEC="1-${TOTAL}%${ARRAY_CONCURRENCY}"
else
    ARRAY_SPEC="1-${TOTAL}"
fi

echo "=============================================="
echo " ProAffinity-GNN SLURM Batch Submission"
echo "=============================================="
echo " Index file:  $INDEX_FILE"
echo " Entries:     $TOTAL"
echo " Output dir:  $OUTPUT_DIR"
echo " Array spec:  $ARRAY_SPEC"
echo " Resources:   20 GB H100 MIG, 4 CPU, 16G mem, 30 min per task"
echo "=============================================="
echo ""

has_account=false
for arg in "$@"; do
    case "$arg" in
        --account|--account=*) has_account=true ;;
    esac
done

SBATCH_ACCOUNT_ARGS=()
if ! $has_account; then
    if [ -z "${PROAFFINITY_SLURM_ACCOUNT:-}" ]; then
        echo "ERROR: set PROAFFINITY_SLURM_ACCOUNT or pass --account=<allocation>" >&2
        exit 5
    fi
    SBATCH_ACCOUNT_ARGS=(--account="${PROAFFINITY_SLURM_ACCOUNT}")
fi

JOB_ID=$(sbatch \
    --array="$ARRAY_SPEC" \
    --job-name="proaffinity" \
    "${SBATCH_ACCOUNT_ARGS[@]}" \
    "$@" \
    "$SLURM_SCRIPT" "$INDEX_FILE" "$OUTPUT_DIR" \
    | awk '{print $NF}')

if [ -z "$JOB_ID" ]; then
    echo "ERROR: sbatch submission failed." >&2
    exit 4
fi

echo ""
echo "Job submitted: $JOB_ID"
echo ""
echo "Monitor with:"
echo "  squeue -j $JOB_ID"
echo "  watch -n 5 'squeue -j $JOB_ID'"
echo ""
echo "Results will be in: $OUTPUT_DIR/"
echo "  Per-task logs:   $OUTPUT_DIR/task_*.txt"
echo "  Per-task TSVs:   $OUTPUT_DIR/task_*.tsv"
echo ""
echo "After all jobs finish, collect results with:"
echo "  python scripts/collect_results.py \"$OUTPUT_DIR\" -i \"$INDEX_FILE\""
echo ""
echo "Cancel with:"
echo "  scancel $JOB_ID"
