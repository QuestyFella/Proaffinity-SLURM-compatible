#!/usr/bin/env bash
# =============================================================================
# submit_test.sh — submit ProAffinity-GNN input validation SLURM array job
# =============================================================================
# Usage:
#   ./scripts/submit_test.sh <index_file> [output_dir] [sbatch_extra_args...]
#
# Runs a quick, low-resource validation (no GPU) on every (PDB, chain_spec)
# entry in the index file to catch bad inputs before the real inference.
#
# The index file is a TSV where each line is:
#   pdb_file<TAB>chain_spec
#
# Examples:
#   # Basic usage
#   ./scripts/submit_test.sh my_pdbs.tsv
#
#   # Custom output directory
#   ./scripts/submit_test.sh my_pdbs.tsv test_results/
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SCRIPT="${SCRIPT_DIR}/test_batch.sh"

# --- usage -------------------------------------------------------------
usage() {
    echo "Usage: $0 <index_file> [output_dir] [sbatch_extra_args...]"
    echo ""
    echo "  index_file     TSV file: pdb_file<TAB>chain_spec"
    echo "  output_dir     Where test results go (default: test_results/<timestamp>)"
    echo "  sbatch args    Passed through to sbatch"
    echo ""
    echo "Examples:"
    echo "  $0 index.tsv"
    echo "  $0 data/index_example.txt test_results/"
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
    OUTPUT_DIR="test_results/$(date +%Y%m%d_%H%M%S)"
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
echo " ProAffinity-GNN Input Validation"
echo "=============================================="
echo " Index file:  $INDEX_FILE"
echo " Entries:     $TOTAL"
echo " Output dir:  $OUTPUT_DIR"
echo " Array spec:  1-${TOTAL}"
echo " Resources:   1 CPU, 2G mem, 5 min (no GPU)"
echo "=============================================="
echo ""

JOB_ID=$(sbatch \
    --array="1-${TOTAL}" \
    --job-name="proaffinity-test" \
    "$@" \
    "$TEST_SCRIPT" "$INDEX_FILE" "$OUTPUT_DIR" \
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
echo ""
echo "Results in: $OUTPUT_DIR/"
echo "  Per-task:    $OUTPUT_DIR/task_*.tsv"
echo ""
echo "After all jobs finish, merge with:"
echo "  (head -1 \"$OUTPUT_DIR/task_1.tsv\" && tail -q -n+2 \"$OUTPUT_DIR\"/task_*.tsv) > \"$OUTPUT_DIR/test_results.tsv\""
echo "  cat $OUTPUT_DIR/test_results.tsv"
echo ""
echo "Quick summary of failures:"
echo "  grep -v 'PASS' $OUTPUT_DIR/test_results.tsv | grep -v '^#'"
echo ""
echo "Cancel with:"
echo "  scancel $JOB_ID"
