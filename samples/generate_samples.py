#!/usr/bin/env python3
"""Generate minimal sample input files for the ProAffinity-GNN pipeline."""

import os

SAMPLES_DIR = os.path.dirname(os.path.abspath(__file__))
PDB_ID = "sample"
PDB_ID_UPPER = "SAMPLE"

# ── 1. Sample PDB file ──────────────────────────────────────────────────────
# A minimal PDB with 2 chains (A, B), each with a few residues.
# Coordinates are roughly placed so chains are adjacent (~10 Å apart).

pdb_content = """HEADER    SAMPLE COMPLEX                          06-JUN-26   SAMP
TITLE     SAMPLE PROTEIN-PROTEIN COMPLEX FOR ProAffinity-GNN
REMARK    This is a minimal synthetic sample for testing the pipeline.
REMARK    Chain A: 5-residue peptide
REMARK    Chain B: 5-residue peptide
REMARK    Chains are positioned ~10 Angstroms apart for inter-chain edges.
ATOM      1  N   ALA A   1      10.000   5.000  10.000  1.00  0.00           N
ATOM      2  CA  ALA A   1      11.000   5.500  11.000  1.00  0.00           C
ATOM      3  C   ALA A   1      11.500   4.500  12.000  1.00  0.00           C
ATOM      4  O   ALA A   1      12.000   4.800  13.000  1.00  0.00           O
ATOM      5  CB  ALA A   1      10.500   6.800  11.500  1.00  0.00           C
ATOM      6  N   GLY A   2      11.500   3.300  11.500  1.00  0.00           N
ATOM      7  CA  GLY A   2      12.000   2.200  12.300  1.00  0.00           C
ATOM      8  C   GLY A   2      11.000   1.500  13.200  1.00  0.00           C
ATOM      9  O   GLY A   2      11.300   0.800  14.000  1.00  0.00           O
ATOM     10  N   SER A   3      11.000   1.800  14.500  1.00  0.00           N
ATOM     11  CA  SER A   3      10.000   1.200  15.400  1.00  0.00           C
ATOM     12  C   SER A   3       9.000   2.200  16.000  1.00  0.00           C
ATOM     13  O   SER A   3       8.500   2.000  17.000  1.00  0.00           O
ATOM     14  CB  SER A   3      10.600   0.300  16.500  1.00  0.00           C
ATOM     15  OG  SER A   3      11.500  -0.600  15.800  1.00  0.00           O
ATOM     16  N   PHE A   4       8.000   3.000  17.500  1.00  0.00           N
ATOM     17  CA  PHE A   4       7.000   4.000  18.000  1.00  0.00           C
ATOM     18  C   PHE A   4       7.500   5.200  18.800  1.00  0.00           C
ATOM     19  O   PHE A   4       7.000   5.500  19.800  1.00  0.00           O
ATOM     20  CB  PHE A   4       6.200   4.500  16.800  1.00  0.00           C
ATOM     21  CG  PHE A   4       5.500   3.400  16.000  1.00  0.00           C
ATOM     22  CD1 PHE A   4       4.200   3.500  15.500  1.00  0.00           C
ATOM     23  CD2 PHE A   4       6.200   2.300  15.500  1.00  0.00           C
ATOM     24  CE1 PHE A   4       3.500   2.500  14.800  1.00  0.00           C
ATOM     25  CE2 PHE A   4       5.500   1.300  14.800  1.00  0.00           C
ATOM     26  CZ  PHE A   4       4.200   1.400  14.500  1.00  0.00           C
ATOM     27  N   LEU A   5       7.500   4.000  19.500  1.00  0.00           N
ATOM     28  CA  LEU A   5       8.000   5.000  20.500  1.00  0.00           C
ATOM     29  C   LEU A   5       9.000   4.500  21.500  1.00  0.00           C
ATOM     30  O   LEU A   5       9.000   5.000  22.500  1.00  0.00           O
ATOM     31  CB  LEU A   5       6.800   5.500  21.300  1.00  0.00           C
ATOM     32  CG  LEU A   5       5.800   6.300  20.500  1.00  0.00           C
ATOM     33  CD1 LEU A   5       4.800   6.800  21.500  1.00  0.00           C
ATOM     34  CD2 LEU A   5       6.500   7.500  19.800  1.00  0.00           C
TER      35      LEU A   5
ATOM     36  N   ALA B   1      22.000   5.000  10.000  1.00  0.00           N
ATOM     37  CA  ALA B   1      23.000   5.500  11.000  1.00  0.00           C
ATOM     38  C   ALA B   1      23.500   4.500  12.000  1.00  0.00           C
ATOM     39  O   ALA B   1      24.000   4.800  13.000  1.00  0.00           O
ATOM     40  CB  ALA B   1      22.500   6.800  11.500  1.00  0.00           C
ATOM     41  N   GLY B   2      23.500   3.300  11.500  1.00  0.00           N
ATOM     42  CA  GLY B   2      24.000   2.200  12.300  1.00  0.00           C
ATOM     43  C   GLY B   2      23.000   1.500  13.200  1.00  0.00           C
ATOM     44  O   GLY B   2      23.300   0.800  14.000  1.00  0.00           O
ATOM     45  N   SER B   3      23.000   1.800  14.500  1.00  0.00           N
ATOM     46  CA  SER B   3      22.000   1.200  15.400  1.00  0.00           C
ATOM     47  C   SER B   3      21.000   2.200  16.000  1.00  0.00           C
ATOM     48  O   SER B   3      20.500   2.000  17.000  1.00  0.00           O
ATOM     49  CB  SER B   3      22.600   0.300  16.500  1.00  0.00           C
ATOM     50  OG  SER B   3      23.500  -0.600  15.800  1.00  0.00           O
ATOM     51  N   VAL B   4      20.000   1.000  13.500  1.00  0.00           N
ATOM     52  CA  VAL B   4      19.000   2.000  14.000  1.00  0.00           C
ATOM     53  C   VAL B   4      19.500   3.200  14.800  1.00  0.00           C
ATOM     54  O   VAL B   4      19.000   3.500  15.800  1.00  0.00           O
ATOM     55  CB  VAL B   4      18.200   2.500  12.800  1.00  0.00           C
ATOM     56  CG1 VAL B   4      17.500   1.400  12.000  1.00  0.00           C
ATOM     57  CG2 VAL B   4      19.100   3.300  11.800  1.00  0.00           C
ATOM     58  N   ILE B   5      19.500   4.000  15.500  1.00  0.00           N
ATOM     59  CA  ILE B   5      20.000   5.000  16.500  1.00  0.00           C
ATOM     60  C   ILE B   5      21.000   4.500  17.500  1.00  0.00           C
ATOM     61  O   ILE B   5      21.000   5.000  18.500  1.00  0.00           O
ATOM     62  CB  ILE B   5      18.800   5.500  17.300  1.00  0.00           C
ATOM     63  CG1 ILE B   5      17.800   4.300  17.500  1.00  0.00           C
ATOM     64  CG2 ILE B   5      18.200   6.800  16.800  1.00  0.00           C
ATOM     65  CD1 ILE B   5      16.500   4.800  18.000  1.00  0.00           C
TER      66      ILE B   5
END
"""

with open(os.path.join(SAMPLES_DIR, f"{PDB_ID}.pdb"), "w") as f:
    f.write(pdb_content)
print(f"Created samples/{PDB_ID}.pdb")

# ── 2. Sample PDBQT file ────────────────────────────────────────────────────
# Same atoms as PDB but in PDBQT format with AutoDock atom types.
# Column positions must match what get_residue_list_from_file() expects:
#   [0:6]=ATOM/TER, [12:16]=atom name, [17:20]=res name,
#   [21]=chain, [22:27]=resnum, [30:38]=x, [38:46]=y, [46:54]=z, [77:79]=type

def fmt_atom(serial, atom_name, res_name, chain, res_num, x, y, z, occ, bfact, charge, pdbqt_type):
    """Format a PDBQT ATOM record with correct fixed-width columns."""
    return (
        f"ATOM  {serial:>5} {atom_name:<4} {res_name:>3} {chain}{res_num:>4}    "
        f"{x:>8.3f}{y:>8.3f}{z:>8.3f}"
        f"{occ:>6.2f}{bfact:>6.2f}    {charge:>6.3f} {pdbqt_type:<2}"
        f"\n"
    )

def fmt_ter(serial, res_name, chain, res_num):
    return f"TER   {serial:>5}      {res_name:>3} {chain}{res_num:>4}\n"

lines = []

# Chain A residues
chain_a_residues = [
    ("ALA", 1, [
        ("N   ", 10.000, 5.000, 10.000, "N "),
        ("CA  ", 11.000, 5.500, 11.000, "C "),
        ("C   ", 11.500, 4.500, 12.000, "C "),
        ("O   ", 12.000, 4.800, 13.000, "OA"),
        ("CB  ", 10.500, 6.800, 11.500, "C "),
    ]),
    ("GLY", 2, [
        ("N   ", 11.500, 3.300, 11.500, "N "),
        ("CA  ", 12.000, 2.200, 12.300, "C "),
        ("C   ", 11.000, 1.500, 13.200, "C "),
        ("O   ", 11.300, 0.800, 14.000, "OA"),
    ]),
    ("SER", 3, [
        ("N   ", 11.000, 1.800, 14.500, "N "),
        ("CA  ", 10.000, 1.200, 15.400, "C "),
        ("C   ",  9.000, 2.200, 16.000, "C "),
        ("O   ",  8.500, 2.000, 17.000, "OA"),
        ("CB  ", 10.600, 0.300, 16.500, "C "),
        ("OG  ", 11.500,-0.600, 15.800, "OA"),
    ]),
    ("PHE", 4, [
        ("N   ",  8.000, 3.000, 17.500, "N "),
        ("CA  ",  7.000, 4.000, 18.000, "C "),
        ("C   ",  7.500, 5.200, 18.800, "C "),
        ("O   ",  7.000, 5.500, 19.800, "OA"),
        ("CB  ",  6.200, 4.500, 16.800, "C "),
        ("CG  ",  5.500, 3.400, 16.000, "A "),
        ("CD1 ",  4.200, 3.500, 15.500, "A "),
        ("CD2 ",  6.200, 2.300, 15.500, "A "),
        ("CE1 ",  3.500, 2.500, 14.800, "A "),
        ("CE2 ",  5.500, 1.300, 14.800, "A "),
        ("CZ  ",  4.200, 1.400, 14.500, "A "),
    ]),
    ("LEU", 5, [
        ("N   ",  7.500, 4.000, 19.500, "N "),
        ("CA  ",  8.000, 5.000, 20.500, "C "),
        ("C   ",  9.000, 4.500, 21.500, "C "),
        ("O   ",  9.000, 5.000, 22.500, "OA"),
        ("CB  ",  6.800, 5.500, 21.300, "C "),
        ("CG  ",  5.800, 6.300, 20.500, "C "),
        ("CD1 ",  4.800, 6.800, 21.500, "C "),
        ("CD2 ",  6.500, 7.500, 19.800, "C "),
    ]),
]

# Chain B residues
chain_b_residues = [
    ("ALA", 1, [
        ("N   ", 22.000, 5.000, 10.000, "N "),
        ("CA  ", 23.000, 5.500, 11.000, "C "),
        ("C   ", 23.500, 4.500, 12.000, "C "),
        ("O   ", 24.000, 4.800, 13.000, "OA"),
        ("CB  ", 22.500, 6.800, 11.500, "C "),
    ]),
    ("GLY", 2, [
        ("N   ", 23.500, 3.300, 11.500, "N "),
        ("CA  ", 24.000, 2.200, 12.300, "C "),
        ("C   ", 23.000, 1.500, 13.200, "C "),
        ("O   ", 23.300, 0.800, 14.000, "OA"),
    ]),
    ("SER", 3, [
        ("N   ", 23.000, 1.800, 14.500, "N "),
        ("CA  ", 22.000, 1.200, 15.400, "C "),
        ("C   ", 21.000, 2.200, 16.000, "C "),
        ("O   ", 20.500, 2.000, 17.000, "OA"),
        ("CB  ", 22.600, 0.300, 16.500, "C "),
        ("OG  ", 23.500,-0.600, 15.800, "OA"),
    ]),
    ("VAL", 4, [
        ("N   ", 20.000, 1.000, 13.500, "N "),
        ("CA  ", 19.000, 2.000, 14.000, "C "),
        ("C   ", 19.500, 3.200, 14.800, "C "),
        ("O   ", 19.000, 3.500, 15.800, "OA"),
        ("CB  ", 18.200, 2.500, 12.800, "C "),
        ("CG1 ", 17.500, 1.400, 12.000, "C "),
        ("CG2 ", 19.100, 3.300, 11.800, "C "),
    ]),
    ("ILE", 5, [
        ("N   ", 19.500, 4.000, 15.500, "N "),
        ("CA  ", 20.000, 5.000, 16.500, "C "),
        ("C   ", 21.000, 4.500, 17.500, "C "),
        ("O   ", 21.000, 5.000, 18.500, "OA"),
        ("CB  ", 18.800, 5.500, 17.300, "C "),
        ("CG1 ", 17.800, 4.300, 17.500, "C "),
        ("CG2 ", 18.200, 6.800, 16.800, "C "),
        ("CD1 ", 16.500, 4.800, 18.000, "C "),
    ]),
]

serial = 0
for res_name, res_num, atoms in chain_a_residues:
    for atom_name, x, y, z, pdbqt_type in atoms:
        serial += 1
        lines.append(fmt_atom(serial, atom_name, res_name, "A", res_num, x, y, z, 1.00, 0.00, 0.000, pdbqt_type))
serial += 1
lines.append(fmt_ter(serial, "LEU", "A", 5))

for res_name, res_num, atoms in chain_b_residues:
    for atom_name, x, y, z, pdbqt_type in atoms:
        serial += 1
        lines.append(fmt_atom(serial, atom_name, res_name, "B", res_num, x, y, z, 1.00, 0.00, 0.000, pdbqt_type))
serial += 1
lines.append(fmt_ter(serial, "ILE", "B", 5))
lines.append("END\n")

pdbqt_content = "".join(lines)
pdbqt_path = os.path.join(SAMPLES_DIR, f"{PDB_ID}_atom_processed.pdbqt")
with open(pdbqt_path, "w") as f:
    f.write(pdbqt_content)
print(f"Created samples/{PDB_ID}_atom_processed.pdbqt")

# ── 3. FASTA files ──────────────────────────────────────────────────────────

fasta_1 = f""">SAMPLE_1|Chain A|SAMPLE PEPTIDE A|Synthetic
ALGSFLE
"""
fasta_2 = f""">SAMPLE_2|Chain B|SAMPLE PEPTIDE B|Synthetic
AGSVLI
"""

for i, fasta_content in enumerate([fasta_1, fasta_2], 1):
    fasta_path = os.path.join(SAMPLES_DIR, "FASTA", f"{PDB_ID_UPPER}_{i}.fasta")
    with open(fasta_path, "w") as f:
        f.write(fasta_content)
    print(f"Created samples/FASTA/{PDB_ID_UPPER}_{i}.fasta")

# ── 4. Chain index file ─────────────────────────────────────────────────────

index_content = f"{PDB_ID}\tB;\tA;\n"
index_path = os.path.join(SAMPLES_DIR, "index_example.txt")
with open(index_path, "w") as f:
    f.write(index_content)
print("Created samples/index_example.txt")

# ── 5. Binding affinity data ────────────────────────────────────────────────

affinity_content = f"{PDB_ID}\t7.50\n"
affinity_path = os.path.join(SAMPLES_DIR, "PPIdataindex.txt")
with open(affinity_path, "w") as f:
    f.write(affinity_content)
print("Created samples/PPIdataindex.txt")

print("\nDone! Sample input files are in samples/")
print(f"  PDBQT:  samples/{PDB_ID}_atom_processed.pdbqt")
print(f"  PDB:    samples/{PDB_ID}.pdb")
print(f"  FASTA:  samples/FASTA/{PDB_ID_UPPER}_1.fasta, {PDB_ID_UPPER}_2.fasta")
print(f"  Index:  samples/index_example.txt")
print(f"  Labels: samples/PPIdataindex.txt")
