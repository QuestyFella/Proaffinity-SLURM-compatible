#!/usr/bin/env bash
# =============================================================================
# run_af3_batch.sh — prepare and run ProAffinity on one AF3 batch folder
# =============================================================================
# Usage:
#   ./scripts/run_af3_batch.sh batch2 --prepare
#   ./scripts/run_af3_batch.sh batch2 --prebuild
#   ./scripts/run_af3_batch.sh batch2 --test
#   ./scripts/run_af3_batch.sh batch2 --infer
#   ./scripts/run_af3_batch.sh batch2 --collect
#   ./scripts/run_af3_batch.sh batch2 --all
#
# Typical login-node workflow (after rsyncing AF3Proteins/AF3 Structure_batchN/):
#   export PROAFFINITY_SLURM_ACCOUNT=def-yourgroup-ab
#   export PROAFFINITY_VENV=$HOME/proaffinity-env
#   export ADFR_PREPARE_RECEPTOR=$HOME/software/ADFRsuite/bin/prepare_receptor
#   export HF_HOME=$HOME/.cache/huggingface
#   export HUGGINGFACE_HUB_CACHE=$HF_HOME
#   export TRANSFORMERS_CACHE=$HF_HOME
#
#   ./scripts/run_af3_batch.sh batch2 --prepare --prebuild --test
#   ./scripts/run_af3_batch.sh batch2 --infer
#   ./scripts/run_af3_batch.sh batch2 --collect
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    cat <<'EOF'
Usage: ./scripts/run_af3_batch.sh <batch> [step flags] [sbatch args...]

  batch          batch2, batch3, batch4 (or 2, 3, 4)

Step flags (pick one or more):
  --prepare      CIF -> PDB complexes + data/index_af3_batchN.txt
  --prebuild     PDB -> PDBQT on login node (needs ADFR_PREPARE_RECEPTOR)
  --test         SLURM validation array (CPU, no GPU)
  --infer        SLURM inference array (GPU)
  --collect      Merge task_*.tsv into results/af3_batchN/results.csv
  --all          prepare + prebuild + test + infer (not collect)

Environment:
  PROAFFINITY_SLURM_ACCOUNT   SLURM account (or pass --account=...)
  PROAFFINITY_VENV            Python venv for inference
  ADFR_PREPARE_RECEPTOR       prepare_receptor path for --prebuild

Examples:
  ./scripts/run_af3_batch.sh batch2 --prepare --prebuild --test
  ./scripts/run_af3_batch.sh batch3 --infer --account=def-yourgroup-ab
  ./scripts/run_af3_batch.sh 4 --collect
EOF
    exit 1
}

normalize_batch() {
    local raw="${1,,}"
    case "$raw" in
        2 | batch2) echo "batch2" ;;
        3 | batch3) echo "batch3" ;;
        4 | batch4) echo "batch4" ;;
        1 | batch1) echo "batch1" ;;
        *)
            echo "ERROR: batch must be batch1-batch4 (or 1-4), got: $1" >&2
            exit 1
            ;;
    esac
}

if [ $# -lt 1 ]; then
    usage
fi

BATCH="$(normalize_batch "$1")"
shift

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
    echo "ERROR: pick at least one step flag (--prepare, --prebuild, --test, --infer, --collect, --all)" >&2
    usage
fi

INDEX_FILE="${PROJECT_DIR}/data/index_af3_${BATCH}.txt"
RESULTS_DIR="${PROJECT_DIR}/results/af3_${BATCH}"
AF3_BATCH_DIR="${PROJECT_DIR}/AF3Proteins/AF3 Structure_${BATCH}"

cd "$PROJECT_DIR"

echo "=============================================="
echo " AF3 batch: ${BATCH}"
echo " Index:     ${INDEX_FILE#${PROJECT_DIR}/}"
echo " Results:   ${RESULTS_DIR#${PROJECT_DIR}/}"
echo "=============================================="

if [ "$DO_PREPARE" -eq 1 ]; then
    if [ ! -d "$AF3_BATCH_DIR" ]; then
        echo "ERROR: AF3 batch folder not found: $AF3_BATCH_DIR" >&2
        echo "  rsync from your Mac, e.g.:" >&2
        echo "    rsync -av AF3Proteins/AF3\\ Structure_${BATCH}/ \\" >&2
        echo "      user@cluster:.../AF3Proteins/AF3\\ Structure_${BATCH}/" >&2
        exit 1
    fi
    echo "[prepare] Converting CIFs and writing index..."
    python3 "${SCRIPT_DIR}/prepare_af3_proteins.py" --batches "$BATCH" -o "$INDEX_FILE"
fi

if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: index file missing: $INDEX_FILE" >&2
    echo "  Run: ./scripts/run_af3_batch.sh $BATCH --prepare" >&2
    exit 1
fi

N_LINES=$(awk 'NF && $0 !~ /^#/ { n++ } END { print n+0 }' "$INDEX_FILE")
echo "Index entries: $N_LINES"

if [ "$DO_PREBUILD" -eq 1 ]; then
    echo "[prebuild] Converting PDBs to PDBQT..."
    "${SCRIPT_DIR}/prebuild_pdbqt.sh" "$INDEX_FILE"
fi

if [ "$DO_TEST" -eq 1 ]; then
    echo "[test] Submitting validation array..."
    "${SCRIPT_DIR}/submit_test.sh" "$INDEX_FILE" "test_results/af3_${BATCH}" "${SBATCH_ARGS[@]}"
fi

if [ "$DO_INFER" -eq 1 ]; then
    echo "[infer] Submitting inference array..."
    "${SCRIPT_DIR}/submit_array.sh" "$INDEX_FILE" "$RESULTS_DIR" "${SBATCH_ARGS[@]}"
fi

if [ "$DO_COLLECT" -eq 1 ]; then
    if ! compgen -G "${RESULTS_DIR}/task_*.tsv" > /dev/null; then
        echo "ERROR: no task_*.tsv in $RESULTS_DIR" >&2
        exit 1
    fi
    echo "[collect] Writing CSV summary..."
    python3 "${SCRIPT_DIR}/collect_results.py" "$RESULTS_DIR" -i "$INDEX_FILE"
fi

echo "Done."
