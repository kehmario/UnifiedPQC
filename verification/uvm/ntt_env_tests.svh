// =============================================================================
// ntt_env_tests.svh -- environment and tests
//
//   ntt_smoke_test      one op per mode
//   ntt_kat_test        NIST-ACVP-derived KATs (HW == REF == KAT)
//   ntt_corner_test     8 data patterns x 4 mod_sel encodings x {NTT, INTT}
//   ntt_roundtrip_test  INTT(NTT(x)) == x on hardware only
//   ntt_random_test     constrained-random (+NUM_OPS=n, default 200)
//   ntt_robust_test     start-while-busy glitches + back-to-back ops
//   ntt_regress_test    all of the above in one run, coverage closure required
// =============================================================================
class ntt_env extends uvm_env;
    `uvm_component_utils(ntt_env)
    ntt_agent      agt;
    ntt_scoreboard sb;
    ntt_coverage   cov;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agt = ntt_agent::type_id::create("agt", this);
        sb  = ntt_scoreboard::type_id::create("sb", this);
        cov = ntt_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        agt.mon.ap.connect(sb.mon_fifo.analysis_export);
        agt.drv.ap.connect(sb.drv_fifo.analysis_export);
        agt.drv.ap.connect(cov.analysis_export);
    endfunction
endclass

// ---------------------------------------------------------------- base
class ntt_base_test extends uvm_test;
    `uvm_component_utils(ntt_base_test)
    ntt_env env;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = ntt_env::type_id::create("env", this);
    endfunction

    virtual task run_body(); endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        run_body();
        repeat (20) @(posedge env.agt.drv.vif.clk);
        phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server rs = uvm_report_server::get_server();
        int n_err = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
        if (n_err == 0 && env.sb.n_checked > 0)
            `uvm_info("RESULT", $sformatf("*** UVM TEST PASSED *** (%s, %0d ops)", get_type_name(), env.sb.n_checked), UVM_NONE)
        else
            `uvm_info("RESULT", $sformatf("*** UVM TEST FAILED *** (%s, %0d errors, %0d ops)", get_type_name(), n_err, env.sb.n_checked), UVM_NONE)
    endfunction
endclass

class ntt_smoke_test extends ntt_base_test;
    `uvm_component_utils(ntt_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_body();
        ntt_smoke_seq s = ntt_smoke_seq::type_id::create("s");
        s.start(env.agt.sqr);
    endtask
endclass

class ntt_kat_test extends ntt_base_test;
    `uvm_component_utils(ntt_kat_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_body();
        ntt_kat_seq s = ntt_kat_seq::type_id::create("s");
        s.start(env.agt.sqr);
    endtask
endclass

class ntt_corner_test extends ntt_base_test;
    `uvm_component_utils(ntt_corner_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_body();
        ntt_corner_seq s = ntt_corner_seq::type_id::create("s");
        s.start(env.agt.sqr);
    endtask
endclass

class ntt_roundtrip_test extends ntt_base_test;
    `uvm_component_utils(ntt_roundtrip_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_body();
        ntt_roundtrip_seq s = ntt_roundtrip_seq::type_id::create("s");
        s.start(env.agt.sqr);
    endtask
endclass

class ntt_random_test extends ntt_base_test;
    `uvm_component_utils(ntt_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_body();
        ntt_rand_seq s = ntt_rand_seq::type_id::create("s");
        int n;
        if ($value$plusargs("NUM_OPS=%d", n)) s.num_ops = n; else s.num_ops = 200;
        s.start(env.agt.sqr);
    endtask
endclass

class ntt_robust_test extends ntt_base_test;
    `uvm_component_utils(ntt_robust_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_body();
        ntt_glitch_seq g = ntt_glitch_seq::type_id::create("g");
        ntt_b2b_seq    b = ntt_b2b_seq::type_id::create("b");
        g.start(env.agt.sqr);
        b.start(env.agt.sqr);
    endtask
endclass

class ntt_regress_test extends ntt_base_test;
    `uvm_component_utils(ntt_regress_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
    endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
        env.cov.require_closure = 1;
    endfunction
    task run_body();
        ntt_kat_seq       k = ntt_kat_seq::type_id::create("k");
        ntt_corner_seq    c = ntt_corner_seq::type_id::create("c");
        ntt_roundtrip_seq r = ntt_roundtrip_seq::type_id::create("r");
        ntt_glitch_seq    g = ntt_glitch_seq::type_id::create("g");
        ntt_b2b_seq       b = ntt_b2b_seq::type_id::create("b");
        ntt_rand_seq      x = ntt_rand_seq::type_id::create("x");
        int n;
        if ($value$plusargs("NUM_OPS=%d", n)) x.num_ops = n; else x.num_ops = 60;
        k.start(env.agt.sqr);
        c.start(env.agt.sqr);
        r.start(env.agt.sqr);
        g.start(env.agt.sqr);
        b.start(env.agt.sqr);
        x.start(env.agt.sqr);
    endtask
endclass
