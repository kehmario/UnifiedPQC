// =============================================================================
// ntt_agent.svh -- driver, monitor, agent
//
// Transaction level = one whole polynomial operation.  The driver preloads the
// BRAM by backdoor, pulses start, waits for done and reads the result back
// (so sequences can chain ops, e.g. NTT -> NTT^-1).  The monitor is fully
// independent of the driver: it reconstructs every operation from the pins
// (start accepted while idle -> done), snapshots BRAM at both ends, counts
// latency and bus writes, and checks bus-level legality against q.
// =============================================================================

typedef virtual ntt_if ntt_vif_t;

// ----------------------------------------------------------------- driver
class ntt_driver extends uvm_driver #(ntt_seq_item);
    `uvm_component_utils(ntt_driver)
    ntt_vif_t vif;
    uvm_analysis_port #(ntt_seq_item) ap;   // stimulus intent, published on completion

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(ntt_vif_t)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "ntt_vif not set")
    endfunction

    task run_phase(uvm_phase phase);
        vif.start   <= 1'b0;
        vif.inv     <= 1'b0;
        vif.mod_sel <= 2'b00;
        wait (vif.rstn === 1'b1);
        forever begin
            seq_item_port.get_next_item(req);
            drive_op(req);
            ap.write(req);
            seq_item_port.item_done();
        end
    endtask

    task drive_op(ntt_seq_item t);
        repeat (t.idle_cycles) @(negedge vif.clk);
        @(negedge vif.clk);
        while (vif.busy === 1'b1) @(negedge vif.clk);

        for (int i = 0; i < 256; i++) vif.bd_write(i, {9'd0, t.coeffs_in[i][22:0]});

        vif.inv     = t.inv;
        vif.mod_sel = t.mod_sel;
        vif.start   = 1'b1;
        @(negedge vif.clk);
        vif.start   = 1'b0;

        // Robustness: re-pulse start mid-operation with the opposite mode.
        // The DUT samples start only in S_IDLE, so this must be ignored.
        if (t.glitch_at != 0) begin
            repeat (t.glitch_at - 1) @(negedge vif.clk);
            if (vif.busy === 1'b1) begin
                vif.inv     = ~t.inv;
                vif.mod_sel = ~t.mod_sel;
                vif.start   = 1'b1;
                @(negedge vif.clk);
                vif.start   = 1'b0;
                vif.inv     = t.inv;
                vif.mod_sel = t.mod_sel;
            end else
                `uvm_warning("GLITCH", "op finished before glitch point; glitch skipped")
        end

        do @(posedge vif.clk); while (vif.done !== 1'b1);
        @(negedge vif.clk);
        for (int i = 0; i < 256; i++) t.coeffs_out[i] = vif.bd_read(i) & 32'h7F_FFFF;
    endtask
endclass

// ----------------------------------------------------------------- monitor
class ntt_monitor extends uvm_monitor;
    `uvm_component_utils(ntt_monitor)
    ntt_vif_t vif;
    uvm_analysis_port #(ntt_seq_item) ap;
    int unsigned n_ops;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(ntt_vif_t)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "ntt_vif not set")
    endfunction

    task run_phase(uvm_phase phase);
        ntt_seq_item t;
        bit          active = 0;
        int unsigned q = 0;
        wait (vif.rstn === 1'b1);
        forever begin
            @(posedge vif.clk);
            if (vif.rstn !== 1'b1) begin active = 0; continue; end

            if (!active) begin
                // start is accepted on the edge where the DUT is in S_IDLE
                if (vif.start === 1'b1 && vif.busy === 1'b0) begin
                    t = ntt_seq_item::type_id::create($sformatf("mon_op%0d", n_ops));
                    t.mod_sel  = vif.mod_sel;
                    t.inv      = vif.inv;
                    t.pattern  = PAT_RANDOM;          // unknown at pin level
                    t.latency  = 0;
                    t.n_writes = 0;
                    q          = t.q();
                    for (int i = 0; i < 256; i++) t.coeffs_in[i] = vif.bd_read(i) & 32'h7F_FFFF;
                    active = 1;
                end
            end else begin
                t.latency++;
                if (vif.bram_we === 1'b1) begin
                    t.n_writes++;
                    if (vif.bram_wdata[22:0] >= q)
                        `uvm_error("BUS", $sformatf("%s: wrote non-canonical 0x%0h (>= q=%0d) to [%0d]",
                                   t.mode_str(), vif.bram_wdata[22:0], q, vif.bram_addr))
                end
                if (vif.done === 1'b1) begin
                    for (int i = 0; i < 256; i++) t.coeffs_out[i] = vif.bd_read(i) & 32'h7F_FFFF;
                    n_ops++;
                    ap.write(t);
                    active = 0;
                end
            end
        end
    endtask
endclass

// ----------------------------------------------------------------- agent
class ntt_agent extends uvm_agent;
    `uvm_component_utils(ntt_agent)
    ntt_driver                   drv;
    ntt_monitor                  mon;
    uvm_sequencer #(ntt_seq_item) sqr;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mon = ntt_monitor::type_id::create("mon", this);
        if (get_is_active() == UVM_ACTIVE) begin
            drv = ntt_driver::type_id::create("drv", this);
            sqr = uvm_sequencer#(ntt_seq_item)::type_id::create("sqr", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        if (get_is_active() == UVM_ACTIVE)
            drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass
