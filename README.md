# ProAffinity-GNN

ProAffinity-GNN with support for local and SLURM batch inference.

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
| `scripts/build_proteins_index.py` | Alternative index builder for **experimental** crystal structures: scans `proteins/` folder names, maps curated antibody/antigen chain pairs, and optionally downloads PDBs from RCSB (`--download`). Prefer `prepare_proteins.py` for AlphaFold outputs. |
| `scripts/prebuild_pdbqt.sh` | Pre-convert all PDBs in an index to `data/pdbqt/<id>_atom_processed.pdbqt` on a login node. Inference tasks then skip ADFR conversion, saving GPU job time. |

## Typical workflow

**AlphaFold models in `proteins/`:**

```bash
python scripts/prepare_proteins.py
./scripts/prebuild_pdbqt.sh data/index_proteins.txt   # optional, on login node
./scripts/submit_test.sh data/index_proteins.txt
./scripts/submit_array.sh data/index_proteins.txt
```

**Local batch (no SLURM):**

```bash
python scripts/predict_batch.py -i data/index_proteins.txt -o results.tsv
```

After a SLURM run finishes, merge per-task TSVs:

```bash
(head -1 results/run1/task_1.tsv && tail -q -n+2 results/run1/task_*.tsv) > results/run1/results.tsv
```
