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
./scripts/submit_array.sh data/index_proteins.txt results/run1 --account=def-yanyan-ab
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
| `scripts/build_proteins_index.py` | Alternative index builder for **experimental** crystal structures: scans `proteins/` folder names, maps curated antibody/antigen chain pairs, and optionally downloads PDBs from RCSB into `proteins/pdb/` (`--download`). Prefer `prepare_proteins.py` for AlphaFold outputs. |
| `scripts/prebuild_pdbqt.sh` | Pre-convert all PDBs in an index to `data/pdbqt/<id>_atom_processed.pdbqt` on a login node. Inference tasks then skip ADFR conversion, saving GPU job time. |

## Typical workflow

**AlphaFold models in `proteins/`:**

```bash
python scripts/prepare_proteins.py
./scripts/prebuild_pdbqt.sh data/index_proteins.txt   # optional, on login node
./scripts/submit_test.sh data/index_proteins.txt
./scripts/submit_array.sh data/index_proteins.txt results/proteins_run1
python scripts/collect_results.py results/proteins_run1 -i data/index_proteins.txt
```

**AlphaFold3 models in `AF3Proteins/`:**

```bash
python scripts/prepare_af3_proteins.py --batches batch1
./scripts/prebuild_pdbqt.sh data/index_af3_batch1.txt   # optional
./scripts/submit_test.sh data/index_af3_batch1.txt
./scripts/submit_array.sh data/index_af3_batch1.txt results/af3_batch1
python scripts/collect_results.py results/af3_batch1 -i data/index_af3_batch1.txt
```

**Local batch (no SLURM):**

```bash
python scripts/predict_batch.py -i data/index_proteins.txt -o results.tsv
```

After a SLURM run finishes, collect per-task TSVs into a readable CSV (see Post-processing above).
