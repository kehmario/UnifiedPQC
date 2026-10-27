// =============================================================================
// ntt_scoreboard.svh -- end-to-end checking
//
// Pairs each monitor-observed op (pins) with the driver's intent and checks:
//   1. harness consistency  : observed mode / inputs == what was driven
//   2. functional           : HW output == spec-literal reference (ntt_ref_model)
//   3. KAT anchoring        : for ACVP-derived items, HW == KAT AND ref == KAT
//   4. structure            : BRAM write count == exact butterfly/scale count
//   5. constant-time        : latency identical across every op of a mode
//                             (data-independent schedule; side-channel property)
// =============================================================================
class ntt_scoreboard extends uvm_component;
    `uvm_component_utils(ntt_scoreboard)

    uvm_tlm_analysis_fifo #(ntt_seq_item) drv_fifo;
    uvm_tlm_analysis_fifo #(ntt_seq_item) mon_fifo;

    int unsigned n_checked, n_fail, n_kat;
    int unsigned pass_by_mode [string];
    int unsigned fail_by_mode [string];
    int unsigned lat_by_mode  [string];
    int unsigned max_report = 8;   // mismatching coefficients printed per op

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv_fifo = new("drv_fifo", this);
        mon_fifo = new("mon_fifo", this);
    endfunction

    function void start_of_simulation_phase(uvm_phase phase);
        string msg;
        if (!ntt_ref_model::self_check(msg))
            `uvm_fatal("REF", {"reference model constant check failed: ", msg})
        `uvm_info("REF", "reference constants derived and verified (zeta orders, n^-1)", UVM_LOW)
    endfunction

    static function int unsigned expected_writes(bit dsa, bit inv);
        int unsigned w = dsa ? 8*128*2 : 7*128*2;   // layers * butterflies * 2 writes
        return inv ? w + 256 : w;                   // + n^-1 scaling pass
    endfunction

    task run_phase(uvm_phase phase);
        ntt_seq_item d, m;
        forever begin
            mon_fifo.get(m);
            drv_fifo.get(d);
            check_op(d, m);
        end
    endtask

    function void check_op(ntt_seq_item d, ntt_seq_item m);
        poly_t in_p, ref_p;
        string mode = m.mode_str();
        int unsigned errs = 0, shown = 0;
        bit ok = 1;

        n_checked++;
        d.latency  = m.latency;           // hand observed metrics back for coverage
        d.n_writes = m.n_writes;

        // 1. harness consistency -------------------------------------------
        if (d.mod_sel != m.mod_sel || d.inv != m.inv) begin
            `uvm_error("SB/HARNESS", $sformatf("observed %s mod_sel=%0d, driven %s mod_sel=%0d",
                       mode, m.mod_sel, d.mode_str(), d.mod_sel))
            ok = 0;
        end
        for (int i = 0; i < 256; i++) begin
            if (m.coeffs_in[i] != (d.coeffs_in[i] & 32'h7F_FFFF)) begin
                `uvm_error("SB/HARNESS", $sformatf("input[%0d] observed %0d driven %0d",
                           i, m.coeffs_in[i], d.coeffs_in[i]))
                ok = 0; break;
            end
            if (m.coeffs_out[i] != d.coeffs_out[i]) begin
                `uvm_error("SB/HARNESS", $sformatf("output[%0d] monitor %0d driver %0d",
                           i, m.coeffs_out[i], d.coeffs_out[i]))
                ok = 0; break;
            end
        end

        // 2. functional vs reference ----------------------------------------
        for (int i = 0; i < 256; i++) in_p[i] = m.coeffs_in[i];
        ntt_ref_model::compute(m.dsa(), m.inv, in_p, ref_p);
        for (int i = 0; i < 256; i++)
            if (m.coeffs_out[i] != ref_p[i]) begin
                errs++;
                if (shown < max_report) begin
                    shown++;
                    `uvm_error("SB/MISMATCH", $sformatf("%s [%s] coeff[%0d]: got %0d exp %0d (in=%0d)",
                               mode, d.pattern.name(), i, m.coeffs_out[i], ref_p[i], m.coeffs_in[i]))
                end
            end
        if (errs) begin
            `uvm_error("SB/FAIL", $sformatf("%s [%s%s]: %0d/256 coefficients wrong",
                       mode, d.pattern.name(), d.tag == "" ? string'("") : {" ", d.tag}, errs))
            ok = 0;
        end

        // 3. KAT anchoring --------------------------------------------------
        if (d.has_expected) begin
            int unsigned e_hw = 0, e_ref = 0;
            n_kat++;
            for (int i = 0; i < 256; i++) begin
                if (m.coeffs_out[i] != d.expected[i]) e_hw++;
                if (ref_p[i]        != d.expected[i]) e_ref++;
            end
            if (e_hw)  begin `uvm_error("SB/KAT", $sformatf("%s %s: HW differs from KAT in %0d coeffs",  mode, d.tag, e_hw))  ok = 0; end
            if (e_ref) begin `uvm_error("SB/KAT", $sformatf("%s %s: REF differs from KAT in %0d coeffs", mode, d.tag, e_ref)) ok = 0; end
            if (!e_hw && !e_ref)
                `uvm_info("SB/KAT", $sformatf("%s %s: HW == REF == ACVP-derived KAT (256/256)", mode, d.tag), UVM_MEDIUM)
        end

        // 4. structural write count -----------------------------------------
        if (m.n_writes != expected_writes(m.dsa(), m.inv)) begin
            `uvm_error("SB/STRUCT", $sformatf("%s: %0d BRAM writes, expected %0d",
                       mode, m.n_writes, expected_writes(m.dsa(), m.inv)))
            ok = 0;
        end

        // 5. constant-time --------------------------------------------------
        if (!lat_by_mode.exists(mode)) lat_by_mode[mode] = m.latency;
        else if (lat_by_mode[mode] != m.latency) begin
            `uvm_error("SB/TIMING", $sformatf("%s [%s]: latency %0d != %0d seen earlier (data-dependent timing)",
                       mode, d.pattern.name(), m.latency, lat_by_mode[mode]))
            ok = 0;
        end

        if (ok) begin
            if (!pass_by_mode.exists(mode)) pass_by_mode[mode] = 0;
            pass_by_mode[mode]++;
        end else begin
            if (!fail_by_mode.exists(mode)) fail_by_mode[mode] = 0;
            fail_by_mode[mode]++;
            n_fail++;
        end
        `uvm_info("SB", $sformatf("%s %s", ok ? "PASS" : "FAIL", d.convert2string()), UVM_HIGH)
    endfunction

    function void check_phase(uvm_phase phase);
        if (!drv_fifo.is_empty() || !mon_fifo.is_empty())
            `uvm_error("SB/DRAIN", $sformatf("unmatched ops at end: drv=%0d mon=%0d",
                       drv_fifo.used(), mon_fifo.used()))
    endfunction

    function void report_phase(uvm_phase phase);
        string s, modes[$] = '{"ML-KEM-NTT", "ML-KEM-INTT", "ML-DSA-NTT", "ML-DSA-INTT"};
        s = "\n  mode          pass   fail   latency(cyc)  writes\n";
        foreach (modes[i]) begin
            string k = modes[i];
            bit is_dsa = (k.substr(3, 5) == "DSA");
            bit is_inv = (k.len() > 10);
            s = {s, $sformatf("  %-12s %5d  %5d   %11s  %6d\n", k,
                 pass_by_mode.exists(k) ? pass_by_mode[k] : 0,
                 fail_by_mode.exists(k) ? fail_by_mode[k] : 0,
                 lat_by_mode.exists(k)  ? $sformatf("%0d", lat_by_mode[k]) : "-",
                 expected_writes(is_dsa, is_inv))};
        end
        s = {s, $sformatf("  ops checked: %0d   failed: %0d   ACVP-KAT ops: %0d", n_checked, n_fail, n_kat)};
        `uvm_info("SB/SUMMARY", s, UVM_NONE)
    endfunction
endclass
