# shellcheck shell=bash
# Source from job scripts: source "${PROJECT_DIR}/scripts/activate_env.sh"
# Activate the ProAffinity Python environment (Alliance virtualenv or conda).
#
# Set before sbatch (exported via --export=ALL):
#   export PROAFFINITY_VENV=$HOME/proaffinity-env

_activate_env_die() {
    echo "FATAL: $1" >&2
    exit "${2:-1}"
}

_activate_env_check_python() {
    local label="${1:-}"
    echo "[${label}] checking Python dependencies..." >&2
    python -c 'import torch; print("PyTorch", torch.__version__, "CUDA=", torch.cuda.is_available())' >&2 \
        || _activate_env_die "torch not importable — install PyTorch in your environment"
    python -c 'import torch; assert torch.cuda.is_available()' 2>/dev/null \
        || _activate_env_die "CUDA not available — inference needs a GPU node with CUDA-enabled PyTorch" 9
    python -c 'import torch_geometric; print("PyG", torch_geometric.__version__)' >&2 \
        || _activate_env_die "torch_geometric not installed — pip install torch-geometric (see environment.yml)"
    python -c 'import transformers; print("transformers", transformers.__version__)' >&2 \
        || _activate_env_die "transformers not installed — pip install transformers"
}

# 1. Alliance / virtualenv (preferred on Rorqual)
_VENV="${PROAFFINITY_VENV:-}"
if [ -z "$_VENV" ] && [ -f "${HOME}/proaffinity-env/bin/activate" ]; then
    _VENV="${HOME}/proaffinity-env"
fi
if [ -n "$_VENV" ]; then
    if [ -f "${_VENV}/bin/activate" ]; then
        # shellcheck disable=SC1091
        source "${_VENV}/bin/activate"
        _activate_env_check_python "venv ${_VENV}"
        return 0
    fi
    _activate_env_die "PROAFFINITY_VENV set but not found: ${_VENV}"
fi

# 2. Conda fallback
CONDA_ENV="${CONDA_ENV:-python3.8}"
CONDA_BASE="${CONDA_BASE:-${HOME}/anaconda3}"
if [ -f "${CONDA_BASE}/etc/profile.d/conda.sh" ]; then
    # shellcheck disable=SC1091
    source "${CONDA_BASE}/etc/profile.d/conda.sh"
    conda activate "$CONDA_ENV"
    _activate_env_check_python "conda ${CONDA_ENV}"
    return 0
elif command -v conda &>/dev/null; then
    eval "$(conda shell.bash hook)"
    conda activate "$CONDA_ENV"
    _activate_env_check_python "conda ${CONDA_ENV}"
    return 0
fi

# 3. No env configured — verify current python or fail with instructions
echo "WARNING: No PROAFFINITY_VENV or conda env configured." >&2
echo "  On Rorqual, create a venv and export before sbatch:" >&2
echo "    export PROAFFINITY_VENV=\$HOME/proaffinity-env" >&2
_activate_env_check_python "system"
