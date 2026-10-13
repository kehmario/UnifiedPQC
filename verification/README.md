# Self-verification bundle — unified ML-KEM/ML-DSA NTT core

Everything needed to independently verify the shared NTT engine of the unified
PQC accelerator, on **Windows** (native) or Linux/macOS/WSL. The principle: check
the hardware against an **independent** NIST-anchored reference, never against its
own output.

Two halves of verification:
- **"Is the math byte-exact?"** — run the NTT on NIST-ACVP-derived vectors and
  compare (reproduce.py / reproduce.sh; Icarus Verilog or Vivado XSim).
- **"Is the logic actually in silicon?"** — confirm synthesis did not trim the
  datapath (Vivado hierarchical utilization; see the last section).

---

## Files

| File | What it is |
|---|---|
| `reproduce.py` | **Native Windows** reproduction (no bash/WSL). Downloads NIST vectors, screens them with the reference, extracts KATs, runs the HW NTT. |
| `reproduce.sh` | Same chain as a bash script (Linux/macOS/WSL/Git-Bash). |
| `run_xsim.bat` | Runs the HW NTT check in **Vivado XSim** (no Icarus needed). Windows batch. |
| `run_xsim.tcl` | Same XSim check via `vivado -mode batch -source run_xsim.tcl`. |
| `pqc_ntt_mont_synth.v` | The synthesizable dual-modulus NTT engine (device under test). |
| `twiddle_init.vh` | Twiddle-factor ROM init, included by the NTT. |
| `tb_batch.v` | Testbench: drives extracted KATs through the NTT, byte-compares. |
| `kem_batch.mem` | Pre-extracted ML-KEM NTT KATs (reproduce.py regenerates these). |
| `dsa_batch.mem` | Pre-extracted ML-DSA NTT KATs. |
| `NIST_ACVP_RAW_REPORT.txt` | The original validation log (provenance, hashes, results). |

---

## Prerequisites

| To run... | You need |
|---|---|
| reproduce.py (full chain) | Python 3.8+, Git for Windows, and either Icarus Verilog **or** Vivado |
| run_xsim.bat / .tcl | **Vivado only** (bundles xvlog/xelab/xsim) |
| Silicon-presence check | **Vivado only** |

Downloads (all free): Python <https://python.org>, Git <https://git-scm.com/download/win>,
Icarus Verilog <https://bleyer.org/icarus>. `pycryptodome` and the FIPS reference
models install automatically — no manual step.

---

## Quick start (Windows, PowerShell)

```powershell
# 1. Full NIST-anchored chain (download -> screen -> extract -> simulate)
python reproduce.py
```

Expected:
```
ML-KEM KeyGen: PASS= 75  FAIL= 0     (and Encaps 75, Decaps 30)
ML-DSA KeyGen: PASS= 75  FAIL= 0     (and SigGen 420, SigVer 180)
KEM: 8 KATs extracted, 8/8 KeyGen public keys == ACVP expected
DSA: 8 KATs extracted, 8/8 KeyGen public keys == ACVP expected
ACVP NTT batch (ML-KEM): 8/8 KATs byte-exact
ACVP NTT batch (ML-DSA): 8/8 KATs byte-exact
```

If `iverilog` is not on PATH, step 6 self-skips with instructions; use the Vivado
path below instead.

```powershell
# 2. Same HW check in Vivado XSim (run from "Vivado <ver> Tcl Shell")
run_xsim.bat
```

**Cross-check:** Icarus and XSim should both report `8/8 byte-exact`. Agreement on
two independent simulators is stronger than either alone; a disagreement is itself a
finding worth investigating.

---

## Notes / gotchas

- **NIST hashes will differ** from `NIST_ACVP_RAW_REPORT.txt` section [1] — NIST
  updates the vectors over time. Expected, not a failure: the screening and
  extraction re-validate against whatever is current.
- Run simulators **from this folder** so the relative `MEM=` filename resolves
  (short paths avoid a filename-buffer truncation issue on long Windows paths).
- XSim needs `--sv` (in the scripts) for the testbench's `void'` cast.

---

## The other half: confirm the logic is really in silicon

Byte-exact simulation does not prove synthesis kept the logic (a simulator drives
every net regardless). In the **Vivado Tcl Console**, on the routed checkpoint:

```tcl
open_checkpoint <your>_routed.dcp
report_utilization -hierarchical -hierarchical_depth 5 -file util_hier.rpt
```

Open `util_hier.rpt` and confirm the Keccak core (`u_keccak`) still shows
**>= 1600 flip-flops** — the Keccak-f[1600] state alone mandates 1600 FFs, so a
count below that proves the datapath was optimized away (the "silent trim" failure).
A healthy build shows ~5,000 FFs total; a trimmed shell shows ~160.

---

## Scope (what this does and does not prove)

Proves: the shared **arithmetic NTT datapath** is byte-exact against NIST-anchored
reference intermediates, for both moduli, and present in silicon. Does **not** prove
full ML-KEM/ML-DSA operations — Encaps/Decaps and Sign/Verify (FO transform,
encode/decode, hint logic, rejection loop) are not in this core. Full scheme-level
ACVP is future work.
