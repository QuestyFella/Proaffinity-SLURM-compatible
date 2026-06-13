# ProAffinity-GNN

ProAffinity-GNN with support for SLURM batching.

See `scripts/` for batch inference tools:

- `predict_one.sh` — single-PDB inference
- `predict_batch.py` — local batch orchestrator
- `slurm_array.sh` — SLURM array job template
- `submit_array.sh` — sbatch launcher
