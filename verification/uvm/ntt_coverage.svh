// =============================================================================
// ntt_coverage.svh -- functional coverage on driven operations
//
// Two forms of the same model:
//   * a SystemVerilog covergroup (for the simulator's coverage database / xcrg)
//   * an explicit bin table that is checked at end of test, so closure is a
//     PASS/FAIL fact in the log and does not depend on any coverage tool.
// =============================================================================
class ntt_coverage extends uvm_subscriber #(ntt_seq_item);
    `uvm_component_utils(ntt_coverage)

    bit          require_closure;     // set by tests that must close all bins
    int unsigned hits [string];
    string       required [$];

`ifndef NTT_NO_COVERGROUP
    ntt_seq_item tr;
    covergroup cg_ntt;
        option.per_instance = 1;
        cp_mod_sel : coverpoint tr.mod_sel { bins v[] = {[0:3]}; }
        cp_dsa     : coverpoint tr.mod_sel[0] { bins kem = {0}; bins dsa = {1}; }
        cp_inv     : coverpoint tr.inv;
        cp_pattern : coverpoint tr.pattern;
        cp_b2b     : coverpoint (tr.idle_cycles == 0) { bins back_to_back = {1}; bins gapped = {0}; }
        cp_glitch  : coverpoint (tr.glitch_at != 0) { bins none = {0}; bins start_while_busy = {1}; }
        x_modsel_inv  : cross cp_mod_sel, cp_inv;
        x_pat_mode    : cross cp_pattern, cp_dsa, cp_inv {
            ignore_bins kat_inv     = binsof(cp_pattern) intersect {PAT_KAT}     && binsof(cp_inv) intersect {1};
            ignore_bins chained_fwd = binsof(cp_pattern) intersect {PAT_CHAINED} && binsof(cp_inv) intersect {0};
        }
        x_glitch_mode : cross cp_glitch, cp_dsa, cp_inv;
        x_b2b_mode    : cross cp_b2b, cp_dsa, cp_inv;
    endgroup
`endif

    function new(string name, uvm_component parent);
        super.new(name, parent);
`ifndef NTT_NO_COVERGROUP
        cg_ntt = new();
`endif
        build_required();
    endfunction

    static function string mode_key(bit dsa, bit inv);
        return $sformatf("%s/%s", dsa ? "DSA" : "KEM", inv ? string'("INTT") : string'("NTT"));
    endfunction

    function void build_required();
        ntt_pattern_e p;
        for (int ms = 0; ms < 4; ms++)
            for (int iv = 0; iv < 2; iv++)
                required.push_back($sformatf("modsel%0d/%s", ms, iv ? string'("INTT") : string'("NTT")));
        for (int d = 0; d < 2; d++)
            for (int iv = 0; iv < 2; iv++) begin
                p = p.first();
                do begin
                    if (!(p == PAT_KAT && iv == 1) && !(p == PAT_CHAINED && iv == 0))
                        required.push_back({mode_key(d, iv), "/", p.name()});
                    p = p.next();
                end while (p != p.first());
                required.push_back({mode_key(d, iv), "/start_while_busy"});
                required.push_back({mode_key(d, iv), "/back_to_back"});
            end
    endfunction

    function void bump(string k);
        if (!hits.exists(k)) hits[k] = 0;
        hits[k]++;
    endfunction

    function void write(ntt_seq_item t);
        string mk = mode_key(t.dsa(), t.inv);
`ifndef NTT_NO_COVERGROUP
        tr = t;
        cg_ntt.sample();
`endif
        bump($sformatf("modsel%0d/%s", t.mod_sel, t.inv ? string'("INTT") : string'("NTT")));
        bump({mk, "/", t.pattern.name()});
        if (t.glitch_at != 0)   bump({mk, "/start_while_busy"});
        if (t.idle_cycles == 0) bump({mk, "/back_to_back"});
    endfunction

    function void report_phase(uvm_phase phase);
        int unsigned n_hit = 0;
        string missing = "";
        foreach (required[i])
            if (hits.exists(required[i])) n_hit++;
            else missing = {missing, "\n    ", required[i]};
`ifndef NTT_NO_COVERGROUP
        `uvm_info("COV", $sformatf("covergroup cg_ntt: %0.1f%%", cg_ntt.get_inst_coverage()), UVM_NONE)
`endif
        `uvm_info("COV", $sformatf("bin table: %0d/%0d required bins hit%s", n_hit, required.size(),
                  missing == "" ? string'("") : {"; missing:", missing}), UVM_NONE)
        if (require_closure && n_hit != required.size())
            `uvm_error("COV", "functional coverage not closed")
    endfunction
endclass
