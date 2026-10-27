# UVM environment — unified ML-KEM / ML-DSA NTT core (`pqc_ntt_mont`)

Transaction-level UVM wrapper around `verification/pqc_ntt_mont_synth.v`. One UVM
transaction = one whole polynomial operation (256-coefficient NTT or NTT⁻¹, either
modulus). Extends the existing ACVP bundle from "forward NTT on 16 KATs" to forward
**and inverse**, constrained-random, corner, robustness and timing properties.

## Architecture

```
 sequences ─► sequencer ─► driver ──(backdoor preload, start pulse, readback)──┐
                             │ ap (intent)                                       │
                             ▼                                                   ▼
                    ┌── scoreboard ◄── monitor ◄──── pins ◄──── pqc_ntt_mont ◄─► ntt_if
                    │      ▲  (observed op: start-accept → done)               (BRAM model
                    │      └── ntt_ref_model (FIPS 203 Alg 9/10, FIPS 204 Alg 41/42)  + SVA)
                    └── coverage (covergroup + closure bin table)
```

| File | Role |
|---|---|
| `ntt_if.sv` | Pins, 256×32 BRAM with the same 1-cycle semantics as `tb_batch.v`, backdoor `bd_write/bd_read`, 6 SVA properties |
| `ntt_ref_model.svh` | Spec-literal reference. Zetas computed from 17 / 1753 by modexp (not from the Montgomery twiddle ROM); plain `%q` arithmetic; FIPS 204 Alg 42 kept with `z = −zetas[m]` |
| `ntt_seq_item.svh` | Op: `mod_sel[1:0]`, `inv`, data pattern, idle gap, start-glitch point |
| `ntt_agent.svh` | Driver, independent pin-level monitor, agent |
| `ntt_scoreboard.svh` | The five checks below |
| `ntt_coverage.svh` | Covergroup + explicit 52-bin closure table |
| `ntt_sequences.svh`, `ntt_env_tests.svh` | Sequences, env, tests |
| `mutants/` | Fault-injection campaign proving every checker fires |

### What the scoreboard checks, per op
1. **Harness consistency** — monitor-observed mode/inputs/outputs equal what the driver intended (catches TB bugs).
2. **Functional** — HW output == reference, all 256 coefficients.
3. **KAT anchoring** — on ACVP-derived items, HW == KAT **and** REF == KAT (the oracle is itself anchored to NIST, not assumed).
4. **Structure** — exact BRAM write count (1792 / 2048 / 2048 / 2304), plus the monitor flags any write ≥ q.
5. **Constant-time** — latency must be identical for every op of a mode, any data. Data-dependent timing is an error.

Plus INTT(NTT(x)) == x round-trips run on hardware only — a property with no reference model in the loop.

## Tests

| Test | Content |
|---|---|
| `ntt_smoke_test` | 1 op per mode |
| `ntt_kat_test` | 16 NIST-ACVP-derived KATs from `../kem_batch.mem`, `../dsa_batch.mem` (`+KEM_KAT=`, `+DSA_KAT=` to override) |
| `ntt_corner_test` | 8 patterns (zero, all q−1, impulse, sparse, alternating, centered-small/secret-like, near-q, random) × 4 `mod_sel` encodings × {NTT, NTT⁻¹} |
| `ntt_roundtrip_test` | INTT(NTT(x)) == x, both moduli |
| `ntt_random_test` | Constrained random, `+NUM_OPS=n` (default 200) |
| `ntt_robust_test` | `start` re-pulsed mid-op with opposite mode (must be ignored); back-to-back ops |
| `ntt_regress_test` | All of the above; **requires 52/52 coverage bins** |

## Running

**Vivado XSim** (UVM 1.2 ships with Vivado 2019.2+), from this folder:
```
vivado -mode batch -source run_xsim.tcl                        # all tests
vivado -mode batch -source run_xsim.tcl -tclargs ntt_kat_test  # one test
run_xsim.bat ntt_regress_test                                  # Windows shortcut
```

**Verilator** (needs a recent build from source — 5.020 from apt cannot run UVM — plus `z3` for randomization):
```
make VERILATOR_ROOT=~/vl_src          # build (~2 min)
make regress                          # all tests
make run TEST=ntt_random_test SEED=42 PLUSARGS=+NUM_OPS=1000
mutants/run_mutants.sh ~/vl_src       # fault-injection campaign
```

## Results (Verilator 5.053-devel @ 5a410e9, UVM 2017-1.0, 2026-10-27)

All 7 tests PASS. `ntt_regress_test`: 184 ops, 0 failures, 16/16 ACVP KATs with HW == REF == KAT, covergroup 100 %, 52/52 bins. `ntt_random_test` additionally clean at 300 ops on seeds 7, 42, 1234.

| Mode | Latency (cycles, constant across all data) | BRAM writes |
|---|---|---|
| ML-KEM NTT | 9 985 | 1 792 |
| ML-KEM NTT⁻¹ | 12 033 | 2 048 |
| ML-DSA NTT | 11 521 | 2 048 |
| ML-DSA NTT⁻¹ | 13 569 | 2 304 |

New coverage over the original bundle: the **inverse NTT and its n⁻¹ scaling pass were never exercised by `tb_batch.v`**; they now pass against the reference and via hardware round-trip in both moduli. `mod_sel[1]` is confirmed don't-care. A `start` pulse during `busy` is ignored.

### Fault injection — every checker is shown to fire
Each mutant is a single RTL defect; the regression must fail on all of them.

| Mutant | Defect | Caught by |
|---|---|---|
| m1 | wrong n⁻¹ (3302) for ML-KEM | functional, round-trip |
| m2 | REDC conditional subtract removed (ML-KEM) | bus ≥ q check, functional, KAT |
| m3 | functionally correct, 1 stall cycle when V == 0 | **constant-time only** |
| m4 | `start` honoured while busy | functional, structure, timing |
| m5 | ML-DSA forward NTT one layer short | functional, structure, KAT |
| m6 | `done` held two cycles | SVA `a_done_pulse` |
| m7 | ML-DSA INTT uses CT instead of GS butterfly | functional, round-trip |

See `mutants/mutation_results.txt` for per-checker error counts.

## Scope (what this does and does not prove)

Simulation only. Proves the NTT datapath and its control are correct, constant-cycle and
protocol-clean against an independent spec-literal model and NIST-derived KATs, on the
bundled BRAM model. Does **not** prove: silicon presence (keep the hierarchical-utilization
check in `../README.md`), behaviour with a different BRAM latency, full KEM/DSA operations
(not in this core), or resistance to power/EM side channels — cycle-count constancy is
necessary, not sufficient. Not yet run on XSim in this environment; the XSim scripts follow
the existing `run_xsim.tcl` flow and should be cross-checked against the Verilator result,
as the bundle already does for Icarus vs XSim.
