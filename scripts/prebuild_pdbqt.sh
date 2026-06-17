#!/usr/bin/env bash
# =============================================================================
# prebuild_pdbqt.sh — pre-convert index PDBs to PDBQT for ProAffinity
# =============================================================================
# Usage:
#   ./scripts/prebuild_pdbqt.sh <index_file> [output_dir] [--force] [--dry-run]
#
# Reads a ProAffinity index TSV:
#   pdb_file<TAB>chain_spec
#
# and creates:
#   data/pdbqt/<pdb_basename>_atom_processed.pdbqt
#
# Those names match the lookup in scripts/predict_one.sh, so inference jobs can
# reuse prebuilt PDBQT files instead of running ADFR per array task.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $0 <index_file> [output_dir] [--force] [--dry-run]"
    echo ""
    echo "Examples:"
    echo "  $0 data/index_proteins.txt"
    echo "  ADFR_PREPARE_RECEPTOR=\$HOME/ADFRsuite/bin/prepare_receptor $0 data/index_proteins.txt"
    echo "  $0 data/index_proteins.txt data/pdbqt --force"
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

INDEX_FILE="$1"
shift

if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: index file not found: $INDEX_FILE" >&2
    exit 2
fi

if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    OUT_DIR="$1"
    shift
else
    OUT_DIR="${PROJECT_DIR}/data/pdbqt"
fi

FORCE=0
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force)
            FORCE=1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage
            ;;
    esac
    shift
done

INDEX_FILE="$(realpath "$INDEX_FILE")"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
LOG_DIR="${OUT_DIR}/logs"
mkdir -p "$LOG_DIR"

find_prepare_receptor() {
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

resolve_pdb() {
    local f="$1"
    local dir="$2"
    local proj="$3"

    [ -f "$f" ] && echo "$f" && return 0
    [ -f "${f}.pdb" ] && echo "${f}.pdb" && return 0
    [ -f "${f}.ent.pdb" ] && echo "${f}.ent.pdb" && return 0
    [ -f "${dir}/${f}" ] && echo "${dir}/${f}" && return 0
    [ -f "${dir}/${f}.pdb" ] && echo "${dir}/${f}.pdb" && return 0
    [ -f "${dir}/${f}.ent.pdb" ] && echo "${dir}/${f}.ent.pdb" && return 0
    [ -f "${proj}/${f}" ] && echo "${proj}/${f}" && return 0
    [ -f "${proj}/${f}.pdb" ] && echo "${proj}/${f}.pdb" && return 0
    [ -f "${proj}/${f}.ent.pdb" ] && echo "${proj}/${f}.ent.pdb" && return 0
    [ -f "${proj}/data/pdb/${f}.pdb" ] && echo "${proj}/data/pdb/${f}.pdb" && return 0
    [ -f "${proj}/data/pdb/${f}.ent.pdb" ] && echo "${proj}/data/pdb/${f}.ent.pdb" && return 0
    [ -f "${proj}/proteins/complexes/${f}" ] && echo "${proj}/proteins/complexes/${f}" && return 0
    [ -f "${proj}/proteins/complexes/${f}.pdb" ] && echo "${proj}/proteins/complexes/${f}.pdb" && return 0
    [ -f "${proj}/AF3Proteins/complexes/${f}" ] && echo "${proj}/AF3Proteins/complexes/${f}" && return 0
    [ -f "${proj}/AF3Proteins/complexes/${f}.pdb" ] && echo "${proj}/AF3Proteins/complexes/${f}.pdb" && return 0
    echo "$f"
    return 1
}

PREPARE_RECEPTOR=""
if [ "$DRY_RUN" -eq 0 ]; then
    PREPARE_RECEPTOR="$(find_prepare_receptor || true)"
    if [ -z "$PREPARE_RECEPTOR" ]; then
        echo "ERROR: ADFR prepare_receptor not found." >&2
        echo "Set one of these before running:" >&2
        echo "  export ADFR_PREPARE_RECEPTOR=/path/to/prepare_receptor" >&2
        echo "  export HPC_ADFRSUITE_BIN=/path/to/ADFRsuite/bin" >&2
        exit 3
    fi
fi

INDEX_DIR="$(dirname "$INDEX_FILE")"
TOTAL=0
BUILT=0
SKIPPED=0
FAILED=0

echo "=============================================="
echo " ProAffinity PDBQT Prebuild"
echo "=============================================="
echo " Index file:       $INDEX_FILE"
echo " Output directory: $OUT_DIR"
echo " Logs:             $LOG_DIR"
if [ "$DRY_RUN" -eq 0 ]; then
    echo " prepare_receptor: $PREPARE_RECEPTOR"
fi
echo "=============================================="

while IFS=$'\t' read -r PDB_FILE _CHAIN_SPEC || [ -n "${PDB_FILE:-}" ]; do
    [ -z "${PDB_FILE// }" ] && continue
    [[ "$PDB_FILE" == \#* ]] && continue
    TOTAL=$((TOTAL + 1))

    PDB_FILE="$(resolve_pdb "$PDB_FILE" "$INDEX_DIR" "$PROJECT_DIR" || true)"
    if [ ! -f "$PDB_FILE" ]; then
        echo "[$TOTAL] ERROR: PDB not found: $PDB_FILE" >&2
        FAILED=$((FAILED + 1))
        continue
    fi

    PDB_BASENAME="$(basename "$PDB_FILE")"
    PDB_ID="${PDB_BASENAME%.pdb}"
    PDB_ID="${PDB_ID%.ent}"
    PDB_ID="$(printf '%s' "$PDB_ID" | tr '[:upper:]' '[:lower:]')"
    OUT_FILE="${OUT_DIR}/${PDB_ID}_atom_processed.pdbqt"
    LOG_FILE="${LOG_DIR}/${PDB_ID}.log"

    if [ -s "$OUT_FILE" ] && [ "$FORCE" -eq 0 ]; then
        echo "[$TOTAL] SKIP  $PDB_ID -> $OUT_FILE"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[$TOTAL] WOULD  $PDB_FILE -> $OUT_FILE"
        continue
    fi

    echo "[$TOTAL] BUILD $PDB_FILE -> $OUT_FILE"
    if "$PREPARE_RECEPTOR" -r "$PDB_FILE" -A hydrogens -o "$OUT_FILE" >"$LOG_FILE" 2>&1 && [ -s "$OUT_FILE" ]; then
        BUILT=$((BUILT + 1))
    else
        echo "[$TOTAL] ERROR building $OUT_FILE (see $LOG_FILE)" >&2
        rm -f "$OUT_FILE"
        FAILED=$((FAILED + 1))
    fi
done < "$INDEX_FILE"

echo ""
echo "Done: total=$TOTAL built=$BUILT skipped=$SKIPPED failed=$FAILED"

if [ "$FAILED" -gt 0 ]; then
    exit 4
fi
