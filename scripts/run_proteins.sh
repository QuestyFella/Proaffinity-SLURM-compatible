#!/usr/bin/env bash
# =============================================================================
# run_proteins.sh — prepare and run ProAffinity on stitched proteins/ complexes
# =============================================================================
# Usage:
#   ./scripts/run_proteins.sh --prepare
#   ./scripts/run_proteins.sh --all-ranks --prepare --prebuild --test
#   ./scripts/run_proteins.sh --all-ranks --infer
#   ./scripts/run_proteins.sh --collect
#
# Default uses rank 0 only (data/index_proteins.txt).
# --all-ranks prepares ranks 0-4 as <pdb>_rank<N>.pdb (index *_allranks.txt).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    cat <<'EOF'
Usage: ./scripts/run_proteins.sh [step flags] [sbatch args...]

Step flags:
  --prepare      Merge per-chain AF models + write index
  --all-ranks    Use all 5 AlphaFold ranks (index index_proteins_allranks.txt)
  --prebuild     PDB -> PDBQT on login node
  --test         SLURM validation array
  --infer        SLURM inference array
  --collect      Merge task_*.tsv into results CSV
  --all          prepare + prebuild + test + infer

Examples:
  ./scripts/run_proteins.sh --prepare --prebuild --test
  ./scripts/run_proteins.sh --all-ranks --prepare --prebuild --test
  ./scripts/run_proteins.sh --all-ranks --infer
EOF
    exit 1
}

DO_PREPARE=0
DO_PREBUILD=0
DO_TEST=0
DO_INFER=0
DO_COLLECT=0
ALL_RANKS=0
SBATCH_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --prepare) DO_PREPARE=1 ;;
        --all-ranks) ALL_RANKS=1 ;;
        --prebuild) DO_PREBUILD=1 ;;
        --test) DO_TEST=1 ;;
        --infer) DO_INFER=1 ;;
        --collect) DO_COLLECT=1 ;;
        --all)
            DO_PREPARE=1
            DO_PREBUILD=1
            DO_TEST=1
            DO_INFER=1
            ;;
        -h | --help) usage ;;
        *) SBATCH_ARGS+=("$1") ;;
    esac
    shift
done

if [ "$DO_PREPARE$DO_PREBUILD$DO_TEST$DO_INFER$DO_COLLECT" = "00000" ]; then
    echo "ERROR: pick at least one step flag" >&2
    usage
fi

INDEX_SUFFIX=""
RESULTS_SUFFIX=""
if [ "$ALL_RANKS" -eq 1 ]; then
    INDEX_SUFFIX="_allranks"
    RESULTS_SUFFIX="_allranks"
fi

INDEX_FILE="${PROJECT_DIR}/data/index_proteins${INDEX_SUFFIX}.txt"
RESULTS_DIR="${PROJECT_DIR}/results/proteins${RESULTS_SUFFIX}"

cd "$PROJECT_DIR"

echo "=============================================="
echo " proteins/ batch"
echo " Index:   ${INDEX_FILE#${PROJECT_DIR}/}"
echo " Results: ${RESULTS_DIR#${PROJECT_DIR}/}"
echo "=============================================="

if [ "$DO_PREPARE" -eq 1 ]; then
    PREPARE_ARGS=(-o "$INDEX_FILE")
    if [ "$ALL_RANKS" -eq 1 ]; then
        PREPARE_ARGS+=(--all-ranks)
    fi
    echo "[prepare] Merging chain models..."
    python3 "${SCRIPT_DIR}/prepare_proteins.py" "${PREPARE_ARGS[@]}"
fi

if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: index file missing: $INDEX_FILE" >&2
    exit 1
fi

N_LINES=$(awk 'NF && $0 !~ /^#/ { n++ } END { print n+0 }' "$INDEX_FILE")
echo "Index entries: $N_LINES"

if [ "$DO_PREBUILD" -eq 1 ]; then
    "${SCRIPT_DIR}/prebuild_pdbqt.sh" "$INDEX_FILE"
fi

if [ "$DO_TEST" -eq 1 ]; then
    "${SCRIPT_DIR}/submit_test.sh" "$INDEX_FILE" "test_results/proteins${RESULTS_SUFFIX}" "${SBATCH_ARGS[@]}"
fi

if [ "$DO_INFER" -eq 1 ]; then
    "${SCRIPT_DIR}/submit_array.sh" "$INDEX_FILE" "$RESULTS_DIR" "${SBATCH_ARGS[@]}"
fi

if [ "$DO_COLLECT" -eq 1 ]; then
    python3 "${SCRIPT_DIR}/collect_results.py" "$RESULTS_DIR" -i "$INDEX_FILE"
fi

echo "Done."
