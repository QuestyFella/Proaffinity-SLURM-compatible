#!/usr/bin/env bash
# =============================================================================
# run_colabfold_batch.sh — prepare and run ProAffinity on ColabFold multimers
# =============================================================================
# Usage:
#   ./scripts/run_colabfold_batch.sh --prepare --prebuild --test
#   ./scripts/run_colabfold_batch.sh --infer
#   ./scripts/run_colabfold_batch.sh --collect
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    cat <<'EOF'
Usage: ./scripts/run_colabfold_batch.sh [step flags] [sbatch args...]

Step flags:
  --prepare      Remap ColabFold chains + write data/index_colabfold_fast.txt
  --prebuild     PDB -> PDBQT on login node
  --test         SLURM validation array
  --infer        SLURM inference array
  --collect      Merge task_*.tsv into results CSV
  --all          prepare + prebuild + test + infer

Examples:
  ./scripts/run_colabfold_batch.sh --prepare --prebuild --test
  ./scripts/run_colabfold_batch.sh --infer
  ./scripts/run_colabfold_batch.sh --collect
EOF
    exit 1
}

DO_PREPARE=0
DO_PREBUILD=0
DO_TEST=0
DO_INFER=0
DO_COLLECT=0
SBATCH_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --prepare) DO_PREPARE=1 ;;
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

INDEX_FILE="${PROJECT_DIR}/data/index_colabfold_fast.txt"
RESULTS_DIR="${PROJECT_DIR}/results/colabfold_fast"
COLABFOLD_DIR="${PROJECT_DIR}/colabfold_fast_results"

cd "$PROJECT_DIR"

echo "=============================================="
echo " ColabFold batch"
echo " Index:   ${INDEX_FILE#${PROJECT_DIR}/}"
echo " Results: ${RESULTS_DIR#${PROJECT_DIR}/}"
echo "=============================================="

if [ "$DO_PREPARE" -eq 1 ]; then
    if [ ! -d "$COLABFOLD_DIR" ]; then
        echo "ERROR: ColabFold folder not found: $COLABFOLD_DIR" >&2
        exit 1
    fi
    echo "[prepare] Remapping ColabFold chains and writing index..."
    python3 "${SCRIPT_DIR}/prepare_colabfold_proteins.py" -o "$INDEX_FILE"
fi

if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: index file missing: $INDEX_FILE" >&2
    echo "  Run: ./scripts/run_colabfold_batch.sh --prepare" >&2
    exit 1
fi

N_LINES=$(awk 'NF && $0 !~ /^#/ { n++ } END { print n+0 }' "$INDEX_FILE")
echo "Index entries: $N_LINES"

if [ "$DO_PREBUILD" -eq 1 ]; then
    "${SCRIPT_DIR}/prebuild_pdbqt.sh" "$INDEX_FILE"
fi

if [ "$DO_TEST" -eq 1 ]; then
    "${SCRIPT_DIR}/submit_test.sh" "$INDEX_FILE" "test_results/colabfold_fast" "${SBATCH_ARGS[@]}"
fi

if [ "$DO_INFER" -eq 1 ]; then
    "${SCRIPT_DIR}/submit_array.sh" "$INDEX_FILE" "$RESULTS_DIR" "${SBATCH_ARGS[@]}"
fi

if [ "$DO_COLLECT" -eq 1 ]; then
    python3 "${SCRIPT_DIR}/collect_results.py" "$RESULTS_DIR" -i "$INDEX_FILE"
fi

echo "Done."
