#!/usr/bin/env bash
# =============================================================================
# test_batch.sh — SLURM array job for low-power PDB input validation
# =============================================================================
# Validates each (PDB, chain_spec) entry from an index file:
#   - PDB file exists, is non-empty, and has ATOM records
#   - All chain letters in the chain spec actually exist in the PDB
#   - Chain spec is parseable (two valid parts)
#
# Uses minimal resources (no GPU, 1 CPU, 1G mem, 3 min timeout) so you can
# quickly identify bad inputs before launching the real inference array.
#
# Submit with:
#   sbatch --array=1-<N> scripts/test_batch.sh <index_file> <output_dir>
#
# Output:
#   <output_dir>/task_<ID>.tsv     — per-task results
# =============================================================================

# --- SLURM directives --------------------------------------------------
#SBATCH --job-name=proaffinity-test
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --time=00:03:00
#SBATCH --output=slurm-test_%A_%a.out
#SBATCH --error=slurm-test_%A_%a.err
#SBATCH --export=ALL
#SBATCH --account=def-yanyan-ab

set -euo pipefail

# --- arguments ---------------------------------------------------------
if [ $# -lt 2 ]; then
    echo "Usage: sbatch --array=1-<N> $0 <index_file> <output_dir>" >&2
    exit 1
fi

INDEX_FILE="$(realpath "$1")"
OUTPUT_DIR="$2"
TASK_ID="${SLURM_ARRAY_TASK_ID:-1}"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INDEX_DIR="$(dirname "$INDEX_FILE")"
# Prefer repo root inferred from index path (data/index.tsv → parent) or SLURM submit dir
if [ "$(basename "$INDEX_DIR")" = "data" ] && [ -d "${INDEX_DIR}/pdb" ]; then
    PROJECT_DIR="$(dirname "$INDEX_DIR")"
elif [ -n "${SLURM_SUBMIT_DIR:-}" ] && [ -d "${SLURM_SUBMIT_DIR}/data/pdb" ]; then
    PROJECT_DIR="${SLURM_SUBMIT_DIR}"
else
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
fi

# --- read the assigned line from the index file ------------------------
LINE_COUNT=$(awk 'END { print NR }' "$INDEX_FILE")
if [ "$TASK_ID" -gt "$LINE_COUNT" ]; then
    echo "[test $TASK_ID] TASK_ID ($TASK_ID) exceeds index file line count ($LINE_COUNT) — nothing to do" >&2
    exit 0
fi

INDEX_LINE=$(sed -n "${TASK_ID}p" "$INDEX_FILE")
PDB_FILE=$(echo "$INDEX_LINE" | cut -f1)
CHAIN_SPEC_RAW=$(echo "$INDEX_LINE" | cut -f2)

if [ -z "$PDB_FILE" ] || [ -z "$CHAIN_SPEC_RAW" ]; then
    echo "[test $TASK_ID] ERROR: empty or malformed index line: $INDEX_LINE" >&2
    echo -e "${PDB_FILE:-UNKNOWN}\t${CHAIN_SPEC_RAW:-UNKNOWN}\tFAIL\t0\t-\tbad index line" > "${OUTPUT_DIR}/task_${TASK_ID}.tsv"
    exit 2
fi

# Clean up and normalise chain spec: strip trailing semicolons, remove spaces,
# then convert semicolons to commas for validation.
# Original format:  "B; A;"   or "L, H; I;"   or "A,B" (already normalised)
# Normalised:       "B,A"     or "LH,I"        or "A,B"
CHAIN_SPEC="${CHAIN_SPEC_RAW}"
CHAIN_SPEC="${CHAIN_SPEC%;}"
CHAIN_SPEC="${CHAIN_SPEC// /}"
if echo "$CHAIN_SPEC" | grep -q ';'; then
    NORMALISED_SPEC=""
    IFS=';' read -ra PARTS <<< "$CHAIN_SPEC"
    for part in "${PARTS[@]}"; do
        part="${part//,/}"
        if [ -n "$NORMALISED_SPEC" ]; then
            NORMALISED_SPEC="${NORMALISED_SPEC},${part}"
        else
            NORMALISED_SPEC="$part"
        fi
    done
    CHAIN_SPEC="$NORMALISED_SPEC"
fi
NORMALISED_SPEC="$CHAIN_SPEC"

# --- handle relative / bare-name paths in index file -------------------
resolve_pdb() {
    local f="$1"
    local dir="$2"
    local proj="${3:-${PROJECT_DIR}}"
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

PDB_FILE=$(resolve_pdb "$PDB_FILE" "$INDEX_DIR" "$PROJECT_DIR" || true)

echo "[test $TASK_ID] Validating: $PDB_FILE  chains: $CHAIN_SPEC (raw: $CHAIN_SPEC_RAW)" >&2

# --- run validations ---------------------------------------------------
ERRORS=""
ATOM_COUNT=0
PDB_CHAINS=""

# 1. File exists and is non-empty
if [ ! -f "$PDB_FILE" ]; then
    ERRORS="${ERRORS} file_not_found"
elif [ ! -s "$PDB_FILE" ]; then
    ERRORS="${ERRORS} empty_file"
else
    # 2. ATOM records present
    ATOM_COUNT=$(awk '/^ATOM  |^HETATM/ { count++ } END { print count+0 }' "$PDB_FILE")
    if [ "$ATOM_COUNT" -eq 0 ]; then
        ERRORS="${ERRORS} no_atom_records"
    else
        # 3. Extract chain IDs from PDB
        PDB_CHAINS=$(awk '/^ATOM  |^HETATM/ { chain = substr($0,22,1); if (chain != " " && chain != "") print chain }' "$PDB_FILE" | sort -u | tr -d '\n')

        # 4. Check chain spec parseable (2 parts)
        PART_COUNT=$(echo "$CHAIN_SPEC" | awk -F',' '{ print NF }')
        if [ "$PART_COUNT" -ne 2 ]; then
            ERRORS="${ERRORS} bad_part_count_${PART_COUNT}"
        else
            PART1=$(echo "$CHAIN_SPEC" | cut -d',' -f1)
            PART2=$(echo "$CHAIN_SPEC" | cut -d',' -f2)
            [ -z "$PART1" ] && ERRORS="${ERRORS} empty_part1"
            [ -z "$PART2" ] && ERRORS="${ERRORS} empty_part2"
            if [ -n "$PART1" ] && [ -n "$PART2" ]; then
                echo "$PART1" | grep -qE '^[A-Za-z0-9]+$' || ERRORS="${ERRORS} bad_chars_part1"
                echo "$PART2" | grep -qE '^[A-Za-z0-9]+$' || ERRORS="${ERRORS} bad_chars_part2"

                # 5. Check all spec chain letters exist in PDB
                if [ -n "$PDB_CHAINS" ]; then
                    SPEC_CHAINS=$(echo "$CHAIN_SPEC" | grep -o '[A-Za-z0-9]' | sort -u | tr -d '\n') || true
                    MISSING=""
                    for (( i=0; i<${#SPEC_CHAINS}; i++ )); do
                        c="${SPEC_CHAINS:$i:1}"
                        echo "$PDB_CHAINS" | grep -q "$c" || MISSING="${MISSING}${c}"
                    done
                    [ -n "$MISSING" ] && ERRORS="${ERRORS} missing_chains_${MISSING}"
                fi
            fi
        fi
    fi
fi

PASS="PASS"
[ -n "$ERRORS" ] && PASS="FAIL"

# --- write per-task result TSV -----------------------------------------
{
    echo "# pdb_file	chain_spec	status	atom_count	pdb_chains	errors"
    echo -e "${PDB_FILE}\t${NORMALISED_SPEC}\t${PASS}\t${ATOM_COUNT}\t${PDB_CHAINS:--}\t${ERRORS:--}"
} > "${OUTPUT_DIR}/task_${TASK_ID}.tsv"

echo "[test $TASK_ID] ${PASS} — atom_count=${ATOM_COUNT}  errors=${ERRORS:--}" >&2
echo "[test $TASK_ID] Done at $(date)" >&2
