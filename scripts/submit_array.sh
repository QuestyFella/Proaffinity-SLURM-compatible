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
#   # Rorqual: account is required; extra sbatch args override #SBATCH in slurm_array.sh
#   ./scripts/submit_array.sh my_pdbs.tsv output/ --account=def-yanyan-ab --time=02:00:00
#
#   # MIG slice instead of a full H100 (queues faster; 1 MIG per job)
#   ./scripts/submit_array.sh my_pdbs.tsv output/ --account=def-yanyan-ab \
#       --gpus=nvidia_h100_80gb_hbm3_2g.20gb:1
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
    echo "Examples (Rorqual / Alliance H100):"
    echo "  $0 my_pdbs.tsv"
    echo "  $0 my_pdbs.tsv results/run1 --account=def-yanyan-ab"
    echo "  $0 my_pdbs.tsv output/ --account=def-yanyan-ab --time=02:00:00"
    echo "  $0 my_pdbs.tsv output/ --account=def-yanyan-ab --gpus=nvidia_h100_80gb_hbm3_2g.20gb:1"
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
echo "=============================================="
echo " ProAffinity-GNN SLURM Batch Submission"
echo "=============================================="
echo " Index file:  $INDEX_FILE"
echo " Entries:     $TOTAL"
echo " Output dir:  $OUTPUT_DIR"
echo " Array spec:  1-${TOTAL}"
echo "=============================================="
echo ""

JOB_ID=$(sbatch \
    --array="1-${TOTAL}" \
    --job-name="proaffinity" \
    --account=def-yanyan-ab \
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
echo "After all jobs finish, merge with:"
echo "  (head -1 \"$OUTPUT_DIR/task_1.tsv\" && tail -q -n+2 \"$OUTPUT_DIR\"/task_*.tsv) > \"$OUTPUT_DIR/results.tsv\""
echo ""
echo "Cancel with:"
echo "  scancel $JOB_ID"
