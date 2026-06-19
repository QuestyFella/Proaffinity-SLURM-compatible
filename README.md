# ProAffinity-GNN

ProAffinity-GNN with support for local and SLURM batch inference.

## Directory layout

Scripts assume this layout under the repo root. Only `data/` is tracked in git; large inputs and outputs are local.

| Path | Purpose |
|------|---------|
| `data/` | Index files (`index_*.txt`), example crystal PDBs (`data/pdb/`), pre-built PDBQT (`data/pdbqt/`). |
| `proteins/` | Per-chain AlphaFold models (input to `prepare_proteins.py`). |
| `proteins/complexes/` | Merged complex PDBs written by `prepare_proteins.py` (lowercase names, e.g. `5l6y.pdb`). |
| `proteins/pdb/` | Experimental crystal PDBs for `build_proteins_index.py --download`. |
| `AF3Proteins/` | AlphaFold3 batch outputs (input to `prepare_af3_proteins.py`). |
| `AF3Proteins/complexes/` | PDBs converted from AF3 CIFs (lowercase names, e.g. `5l6y.pdb`). |
| `results/` | SLURM inference output (per-run subdirs with `task_*.tsv`). |
| `test_results/` | SLURM validation output. |

**AlphaFold per-chain folders** under `proteins/` must match:

```
NNN_<PDBID>_<antibody|antigen>_chain<LETTER>/
  ranked_0.pdb
```

Example: `016_5L6Y_antibody_chainH/ranked_0.pdb`. Folders that do not match this pattern are ignored.

**AlphaFold3 batch folders** under `AF3Proteins/` must be named `AF3 Structure_batch<N>` (e.g. `AF3 Structure_batch1`). Each fold directory inside is either `fold_<pdbid>` or `<pdbid>` and must contain `*job_request.json` and `*model_*.cif`.

**Index files** live in `data/` as `index_<name>.txt` (e.g. `data/index_proteins.txt`, `data/index_af3_batch1.txt`). Each line points at a PDB path relative to the repo root, such as `proteins/complexes/5l6y.pdb` or `AF3Proteins/complexes/5l6y.pdb`.

**PDB resolution:** batch scripts also accept bare PDB IDs (e.g. `5l6y`) and search, in order, `data/pdb/`, `proteins/complexes/`, `AF3Proteins/complexes/`, and a few other repo-relative paths.

**Pre-built PDBQT** files must be named `data/pdbqt/<pdb_id_lowercase>_atom_processed.pdbqt` for inference to skip on-the-fly conversion.

## HPC configuration

SLURM submit scripts require an allocation account. Set it once per session:

```bash
export PROAFFINITY_SLURM_ACCOUNT=def-yourgroup-ab
```

Or pass `--account=def-yourgroup-ab` on the `submit_array.sh` / `submit_test.sh` command line (overrides the env var).

Other useful environment variables:

| Variable | Purpose |
|----------|---------|
| `PROAFFINITY_VENV` | Path to the Python virtualenv (default: `$HOME/proaffinity-env` if present). |
| `PROAFFINITY_ARRAY_CONCURRENCY` | Max concurrent inference array tasks (default `2`). |
| `PROAFFINITY_TEST_CONCURRENCY` | Max concurrent validation array tasks (default `10`). |
| `HF_HOME` | HuggingFace model cache (default `$HOME/.cache/huggingface`). Pre-download ESM-2 on a login node before GPU jobs. |

Default GPU resources in `slurm_array.sh` target Alliance Rorqual H100 MIG (`nvidia_h100_80gb_hbm3_2g.20gb`). Override with extra `sbatch` args, e.g. `--gpus=h100:1 --mem=32G`.

## Index file format

Batch scripts read a TSV with one entry per line (no header):

```
pdb_file<TAB>chain_spec
```

`chain_spec` is a two-part binding pair: antibody chains, then antigen chains. Use `;` between parts and omit spaces, e.g. `H,L;C` (Fab chains H+L vs antigen C). Semicolon-separated specs are normalised automatically by the scripts.

## Scripts

### Core inference

| Script | Purpose |
|--------|---------|
| `scripts/predict_one.sh` | Run ProAffinity-GNN on a single PDB. Converts PDB→PDBQT (ADFR or pre-built `data/pdbqt/`), runs the GNN, and prints `pKa:<value>`. |
| `scripts/predict_batch.py` | Local batch orchestrator. Reads an index file (or scans a PDB directory) and calls `predict_one.sh` for each entry. Supports parallelism (`-p`), resume (`--skip-existing`), and dry-run. Use on a workstation; use SLURM for HPC. |

### SLURM inference (GPU)

| Script | Purpose |
|--------|---------|
| `scripts/slurm_array.sh` | SLURM array **worker** script. Each array task reads one line from the index file, resolves the PDB path, runs `predict_one.sh`, and writes `task_<ID>.txt` (full log) and `task_<ID>.tsv` (pKa result). Configured for Alliance/Rorqual H100 MIG by default. Submit via `submit_array.sh`, not directly. |
| `scripts/submit_array.sh` | **Launcher** for the inference array job. Counts index lines, submits `sbatch --array=1-N%2` (2 concurrent tasks by default), and prints monitor/merge commands. Extra `sbatch` args (account, GPUs, time) are passed through. |

```bash
export PROAFFINITY_SLURM_ACCOUNT=def-yourgroup-ab
./scripts/submit_array.sh data/index_proteins.txt results/run1
```

Set `PROAFFINITY_ARRAY_CONCURRENCY` to change how many tasks run at once (default `2`).

### Post-processing

| Script | Purpose |
|--------|---------|
| `scripts/collect_results.py` | Merge per-task `task_*.tsv` outputs from a SLURM run into a sorted CSV (`pdb_id`, `partner1`, `partner2`, `pka`, `status`, `elapsed_sec`). Chain specs are split into readable columns; pass `-i` to use the index file for partner names. |

```bash
python scripts/collect_results.py results/run1
python scripts/collect_results.py results/run1 -i data/index_proteins.txt
python scripts/collect_results.py results/run1 -o results/run1/summary.csv
```

### SLURM input validation (CPU)

| Script | Purpose |
|--------|---------|
| `scripts/test_batch.sh` | SLURM array **worker** for cheap pre-flight checks (no GPU). Validates each index entry: PDB exists, has ATOM records, chain spec parses as two parts, and all chain letters are present in the file. Writes `task_<ID>.tsv` with PASS/FAIL. |
| `scripts/submit_test.sh` | **Launcher** for the validation array job. Same index format as inference; defaults to 10 concurrent CPU-only tasks (`PROAFFINITY_TEST_CONCURRENCY`). Run this before `submit_array.sh` to catch bad inputs early. |

```bash
./scripts/submit_test.sh data/index_proteins.txt test_results/
```

### Protein preparation & PDBQT prebuild

| Script | Purpose |
|--------|---------|
| `scripts/prepare_proteins.py` | Merge per-chain AlphaFold models under `proteins/` into complex PDBs in `proteins/complexes/`, then write `data/index_proteins.txt` using only chains you modeled. |
| `scripts/prepare_af3_proteins.py` | Convert AF3 CIF models under `AF3Proteins/AF3 Structure_batch*/` into PDBs in `AF3Proteins/complexes/`, then write `data/index_af3_batch<N>.txt`. |
| `scripts/prepare_colabfold_proteins.py` | Remap ColabFold multimer PDB chain IDs (A/B/C) back to the chain IDs encoded in folder names, then write `data/index_colabfold_fast.txt`. |
| `scripts/run_af3_batch.sh` | Convenience wrapper: `--prepare`, `--prebuild`, `--test`, `--infer`, `--collect` for one AF3 batch (batch2–batch4). Add `--all-models` for all 5 AF3 models. |
| `scripts/run_proteins.sh` | Same for stitched `proteins/` complexes; `--all-ranks` for all 5 AlphaFold ranks. |
| `scripts/run_colabfold_batch.sh` | Same wrapper for ColabFold multimer PDBs in `colabfold_fast_results/`. |
| `scripts/build_proteins_index.py` | Alternative index builder for **experimental** crystal structures: scans `proteins/` folder names, maps curated antibody/antigen chain pairs, and optionally downloads PDBs from RCSB into `proteins/pdb/` (`--download`). Prefer `prepare_proteins.py` for AlphaFold outputs. |
| `scripts/prebuild_pdbqt.sh` | Pre-convert all PDBs in an index to `data/pdbqt/<id>_atom_processed.pdbqt` on a login node. Inference tasks then skip ADFR conversion, saving GPU job time. |

## Typical workflow

**AlphaFold models in `proteins/`:**

```bash
export PROAFFINITY_SLURM_ACCOUNT=def-yourgroup-ab
python scripts/prepare_proteins.py
./scripts/prebuild_pdbqt.sh data/index_proteins.txt   # optional, on login node
./scripts/submit_test.sh data/index_proteins.txt
./scripts/submit_array.sh data/index_proteins.txt results/proteins_run1
python scripts/collect_results.py results/proteins_run1 -i data/index_proteins.txt

# All 5 AlphaFold ranks per complex:
./scripts/run_proteins.sh --all-ranks --prepare --prebuild --test
./scripts/run_proteins.sh --all-ranks --infer
./scripts/run_proteins.sh --all-ranks --collect
```

**AlphaFold3 models in `AF3Proteins/`:**

```bash
export PROAFFINITY_SLURM_ACCOUNT=def-yourgroup-ab
export PROAFFINITY_VENV=$HOME/proaffinity-env
export ADFR_PREPARE_RECEPTOR=$HOME/software/ADFRsuite/bin/prepare_receptor
export HF_HOME=$HOME/.cache/huggingface
export HUGGINGFACE_HUB_CACHE=$HF_HOME
export TRANSFORMERS_CACHE=$HF_HOME

# One batch at a time (batch1 already done):
./scripts/run_af3_batch.sh batch2 --prepare --prebuild --test
./scripts/run_af3_batch.sh batch2 --infer
./scripts/run_af3_batch.sh batch2 --collect

# All 5 AF3 models per complex (5x SLURM tasks):
./scripts/run_af3_batch.sh batch1 --all-models --prepare --prebuild --test
./scripts/run_af3_batch.sh batch1 --all-models --infer
./scripts/run_af3_batch.sh batch1 --all-models --collect

# Or step by step:
python scripts/prepare_af3_proteins.py --batches batch2
./scripts/prebuild_pdbqt.sh data/index_af3_batch2.txt
./scripts/submit_test.sh data/index_af3_batch2.txt
./scripts/submit_array.sh data/index_af3_batch2.txt results/af3_batch2
python scripts/collect_results.py results/af3_batch2 -i data/index_af3_batch2.txt
```

| Batch | Index file | Complexes |
|-------|------------|-----------|
| batch1 | `data/index_af3_batch1.txt` | 23 |
| batch2 | `data/index_af3_batch2.txt` | 21 |
| batch3 | `data/index_af3_batch3.txt` | 35 |
| batch4 | `data/index_af3_batch4.txt` | 19 |

Before running on the cluster, rsync each batch folder from your Mac:

```bash
rsync -av "AF3Proteins/AF3 Structure_batch2/" \
  user@cluster:.../AF3Proteins/AF3\ Structure_batch2/
```

**ColabFold multimer PDBs in `colabfold_fast_results/`:**

```bash
export PROAFFINITY_SLURM_ACCOUNT=def-yourgroup-ab
export PROAFFINITY_VENV=$HOME/proaffinity-env
export ADFR_PREPARE_RECEPTOR=$HOME/software/ADFRsuite/bin/prepare_receptor
export HF_HOME=$HOME/.cache/huggingface
export HUGGINGFACE_HUB_CACHE=$HF_HOME
export TRANSFORMERS_CACHE=$HF_HOME

./scripts/run_colabfold_batch.sh --prepare --prebuild --test
./scripts/run_colabfold_batch.sh --infer
./scripts/run_colabfold_batch.sh --collect
```

**Local batch (no SLURM):**

```bash
python scripts/predict_batch.py -i data/index_proteins.txt -o results.tsv
```

After a SLURM run finishes, collect per-task TSVs into a readable CSV (see Post-processing above).
