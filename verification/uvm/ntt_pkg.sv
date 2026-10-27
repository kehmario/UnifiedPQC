// =============================================================================
// ntt_pkg.sv -- UVM verification package for the unified ML-KEM/ML-DSA NTT core
// =============================================================================
`timescale 1ns/1ps
package ntt_pkg;
    import uvm_pkg::*;
`ifndef UVM_MACROS_SVH   // Verilator flattened UVM pkg already defines the macros
    `include "uvm_macros.svh"
`endif

    `include "ntt_ref_model.svh"
    `include "ntt_seq_item.svh"
    `include "ntt_agent.svh"
    `include "ntt_sequences.svh"
    `include "ntt_scoreboard.svh"
    `include "ntt_coverage.svh"
    `include "ntt_env_tests.svh"
endpackage
