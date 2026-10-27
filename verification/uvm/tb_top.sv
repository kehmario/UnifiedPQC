// =============================================================================
// tb_top.sv -- UVM top for pqc_ntt_mont (verification/pqc_ntt_mont_synth.v)
//   +UVM_TESTNAME=ntt_regress_test   (see ntt_env_tests.svh for the list)
// =============================================================================
`timescale 1ns/1ps
module tb_top;
    import uvm_pkg::*;
    import ntt_pkg::*;

    logic clk = 0;
    always #5 clk = ~clk;                 // 100 MHz, matches the timing-closed build

    ntt_if vif (clk);

    pqc_ntt_mont dut (
        .clk        (clk),
        .rstn       (vif.rstn),
        .start      (vif.start),
        .inv        (vif.inv),
        .mod_sel    (vif.mod_sel),
        .busy       (vif.busy),
        .done       (vif.done),
        .bram_addr  (vif.bram_addr),
        .bram_wdata (vif.bram_wdata),
        .bram_rdata (vif.bram_rdata),
        .bram_we    (vif.bram_we)
    );

    initial begin
        vif.rstn    = 1'b0;
        vif.start   = 1'b0;
        vif.inv     = 1'b0;
        vif.mod_sel = 2'b00;
        repeat (5) @(negedge clk);
        vif.rstn = 1'b1;
    end

    initial begin
        uvm_config_db#(virtual ntt_if)::set(null, "uvm_test_top.*", "vif", vif);
        run_test("ntt_smoke_test");
    end

    // hard stop in case a sequence hangs on a DUT that never asserts done
    initial begin
        #500ms;
        $display("TB_TOP: global timeout");
        $finish;
    end
endmodule
