#!/usr/bin/env python3
"""Generate fault-injected copies of pqc_ntt_mont_synth.v to prove the UVM
checkers actually fire.  Each mutant is a single, realistic RTL defect; the
regression must FAIL on every one (a checker that never fails proves nothing).
"""
import pathlib, sys

HERE = pathlib.Path(__file__).resolve().parent
SRC = (HERE / ".." / ".." / "pqc_ntt_mont_synth.v").read_text()

MUTANTS = {
    # wrong n^-1 constant: INTT scaling off, NTT untouched
    "m1_ninv_kem": [("localparam [22:0] NINV_KEM = 23'd3303;",
                     "localparam [22:0] NINV_KEM = 23'd3302;")],
    # drop the REDC conditional subtract for ML-KEM: outputs may land in [q, 2q)
    "m2_no_condsub_kem": [("mul_res <= (redc_pre >= {2'b0, Q_KEM}) ? (redc_pre[22:0] - Q_KEM) : redc_pre[22:0];",
                           "mul_res <= redc_pre[22:0];")],
    # functionally CORRECT but data-dependent timing: stall a cycle when V==0
    "m3_timing_leak": [("S_RD_V: state <= S_LAT_V;",
                        "S_RD_V: state <= (bram_rdata[22:0] == 23'd0 && !leak_r) ? S_RD_V : S_LAT_V;"),
                       ("reg [4:0]  state;", "reg [4:0]  state;\nreg leak_r; always @(posedge clk) leak_r <= (state == S_RD_V);")],
    # a start pulse while busy is (wrongly) honoured: transform aborts early
    "m4_start_while_busy": [("        S_ADDR: state <= S_RD_U;",
                             "        S_ADDR: state <= seen_start ? S_DONE : S_RD_U;"),
                            ("reg [4:0]  state;", "reg [4:0]  state;\nreg seen_start; always @(posedge clk) if (state == S_IDLE) seen_start <= 0; else if (start) seen_start <= 1;")],
    # ML-DSA forward NTT stops one layer early (len==2 instead of len==1)
    "m5_dsa_layers": [("(mod_r && len==8'd1)", "(mod_r && len==8'd2)")],
    # done stretched to two cycles
    "m6_done_two_cycles": [("S_DONE: begin busy<=0; done<=1; state<=S_IDLE; end",
                            "S_DONE: begin busy<=0; done<=1; state<=5'd23; end\n        5'd23: begin done<=1; state<=S_IDLE; end")],
    # ML-DSA INTT uses CT difference (U - tw*V) on the v output instead of GS tw*(V-U)
    "m7_dsa_intt_bfly": [("wire [22:0] bv_r    = direction ? mul_res  : ct_bv_r;",
                          "wire [22:0] bv_r    = (direction && !mod_r) ? mul_res : ct_bv_r;")],
}

out = HERE / "rtl"; out.mkdir(exist_ok=True)
for name, edits in MUTANTS.items():
    s = SRC
    for old, new in edits:
        if s.count(old) != 1:
            sys.exit(f"{name}: pattern not found exactly once: {old!r}")
        s = s.replace(old, new)
    (out / f"{name}.v").write_text(s)
    print(name)
