// =============================================================================
// ntt_if.sv -- pin-level interface + 256x32 BRAM model for pqc_ntt_mont
//
// The BRAM lives inside the interface so UVM components can preload/peek it
// through the virtual interface (backdoor), while the DUT talks to it through
// the real 1-cycle-latency port.  Read/write semantics are identical to the
// tb_batch.v model the ACVP bundle was validated on:
//     always @(posedge clk) begin if (we) mem[a]<=wd; rd<=mem[a]; end
// =============================================================================
`timescale 1ns/1ps
`ifndef UVM_MACROS_SVH
    `include "uvm_macros.svh"
`endif
interface ntt_if (input logic clk);
    import uvm_pkg::*;
    logic        rstn;
    logic        start, inv;
    logic [1:0]  mod_sel;
    logic        busy, done;
    logic [14:0] bram_addr;
    logic [31:0] bram_wdata;
    logic [31:0] bram_rdata;
    logic        bram_we;

    // ---------------------------------------------------------------- BRAM
    logic [31:0] mem [0:255];

    always @(posedge clk) begin
        if (bram_we) mem[bram_addr[7:0]] <= bram_wdata;
        bram_rdata <= mem[bram_addr[7:0]];
    end

    function automatic void bd_write(int unsigned idx, logic [31:0] val);
        mem[idx[7:0]] = val;
    endfunction

    function automatic logic [31:0] bd_read(int unsigned idx);
        return mem[idx[7:0]];
    endfunction

    // ---------------------------------------------------------------- SVA
    // Protocol properties that hold for every operation regardless of data.
    // Failures are routed through UVM so they are counted and the test still
    // reaches its summary instead of stopping the simulator.
`ifndef NTT_NO_SVA
    // done is a single-cycle pulse
    a_done_pulse: assert property (@(posedge clk) disable iff (!rstn)
        done |=> !done)
        else `uvm_error("SVA", $sformatf("SVA: done held high for more than one cycle"))

    // done and busy fall together (S_DONE sets busy<=0, done<=1)
    a_done_not_busy: assert property (@(posedge clk) disable iff (!rstn)
        done |-> !busy)
        else `uvm_error("SVA", $sformatf("SVA: done asserted while busy still high"))

    // DUT never writes outside the 256-word polynomial window
    a_addr_window: assert property (@(posedge clk) disable iff (!rstn)
        bram_we |-> (bram_addr[14:8] == 7'd0))
        else `uvm_error("SVA", $sformatf("SVA: write to address 0x%0h outside 0..255", bram_addr))

    // Coefficients are 23-bit; upper 9 bits of every written word are zero
    a_wdata_upper_zero: assert property (@(posedge clk) disable iff (!rstn)
        bram_we |-> (bram_wdata[31:23] == 9'd0))
        else `uvm_error("SVA", $sformatf("SVA: wdata upper bits non-zero (0x%08h)", bram_wdata))

    // No writes while idle
    a_no_idle_write: assert property (@(posedge clk) disable iff (!rstn)
        (!busy && !done) |-> !bram_we)
        else `uvm_error("SVA", $sformatf("SVA: BRAM write while DUT idle"))

    // Outputs never X after reset
    a_no_x_out: assert property (@(posedge clk) disable iff (!rstn)
        !$isunknown({busy, done, bram_we, bram_addr, bram_wdata}))
        else `uvm_error("SVA", $sformatf("SVA: X/Z on DUT outputs"))
`endif
endinterface
