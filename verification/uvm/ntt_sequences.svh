// =============================================================================
// ntt_sequences.svh
// =============================================================================

class ntt_base_seq extends uvm_sequence #(ntt_seq_item);
    `uvm_object_utils(ntt_base_seq)
    function new(string name = "ntt_base_seq"); super.new(name); endfunction

    // one op with a given mode/pattern; returns the completed item
    task do_op(output ntt_seq_item t, input bit [1:0] mod_sel, input bit inv,
               input ntt_pattern_e pat, input int glitch = 0, input int idle = -1);
        t = ntt_seq_item::type_id::create("op");
        start_item(t);
        if (!t.randomize() with { mod_sel == local::mod_sel; inv == local::inv; pattern == local::pat; })
            `uvm_fatal("RAND", "randomize failed")
        t.glitch_at = glitch;
        if (idle >= 0) t.idle_cycles = idle;
        finish_item(t);
    endtask

    // op with explicitly provided coefficients (KAT / chained)
    task do_op_coeffs(output ntt_seq_item t, input bit [1:0] mod_sel, input bit inv,
                      input ntt_pattern_e pat, input poly_t c, input string tag = "");
        t = ntt_seq_item::type_id::create("op");
        start_item(t);
        t.mod_sel = mod_sel; t.inv = inv; t.pattern = pat;
        t.idle_cycles = $urandom_range(3, 0); t.glitch_at = 0; t.tag = tag;
        foreach (c[i]) t.coeffs_in[i] = c[i];
        finish_item(t);
    endtask
endclass

// ---------------------------------------------------------------- smoke
class ntt_smoke_seq extends ntt_base_seq;
    `uvm_object_utils(ntt_smoke_seq)
    function new(string name = "ntt_smoke_seq"); super.new(name); endfunction
    task body();
        ntt_seq_item t;
        for (int ms = 0; ms < 2; ms++)
            for (int iv = 0; iv < 2; iv++) do_op(t, ms, iv, PAT_RANDOM);
    endtask
endclass

// ---------------------------------------------------------------- random
class ntt_rand_seq extends ntt_base_seq;
    `uvm_object_utils(ntt_rand_seq)
    int unsigned num_ops = 40;
    function new(string name = "ntt_rand_seq"); super.new(name); endfunction
    task body();
        ntt_seq_item t;
        repeat (num_ops) begin
            t = ntt_seq_item::type_id::create("op");
            start_item(t);
            if (!t.randomize()) `uvm_fatal("RAND", "randomize failed")
            finish_item(t);
        end
    endtask
endclass

// ---------------------------------------------------------------- corners
// every base pattern x every mod_sel encoding x {NTT, NTT^-1}
class ntt_corner_seq extends ntt_base_seq;
    `uvm_object_utils(ntt_corner_seq)
    function new(string name = "ntt_corner_seq"); super.new(name); endfunction
    task body();
        ntt_seq_item t;
        ntt_pattern_e p;
        for (int ms = 0; ms < 4; ms++)
            for (int iv = 0; iv < 2; iv++) begin
                p = p.first();
                do begin
                    if (p != PAT_KAT && p != PAT_CHAINED) do_op(t, ms, iv, p);
                    p = p.next();
                end while (p != p.first());
            end
    endtask
endclass

// ---------------------------------------------------------------- ACVP KATs
// Reads the bundle's kem_batch.mem / dsa_batch.mem (N, then 256 in + 256 out
// hex words per KAT) -- vectors extracted from NIST ACVP KeyGen cases whose
// public keys matched ACVP-expected (see reproduce.py).
class ntt_kat_seq extends ntt_base_seq;
    `uvm_object_utils(ntt_kat_seq)
    string kem_file = "../kem_batch.mem";
    string dsa_file = "../dsa_batch.mem";
    int unsigned n_loaded;
    function new(string name = "ntt_kat_seq"); super.new(name); endfunction

    task run_file(string fname, bit dsa);
        int fd, np, r;
        poly_t vin, vexp;
        ntt_seq_item t;
        fd = $fopen(fname, "r");
        if (fd == 0) begin
            `uvm_error("KAT", {"cannot open ", fname, " (pass +KEM_KAT=/+DSA_KAT= or run from verification/uvm)"})
            return;
        end
        r = $fscanf(fd, "%d\n", np);
        for (int p = 0; p < np; p++) begin
            for (int i = 0; i < 256; i++) r = $fscanf(fd, "%h\n", vin[i]);
            for (int i = 0; i < 256; i++) r = $fscanf(fd, "%h\n", vexp[i]);
            t = ntt_seq_item::type_id::create("kat");
            start_item(t);
            t.mod_sel = {1'b0, dsa}; t.inv = 0; t.pattern = PAT_KAT;
            t.idle_cycles = 1; t.glitch_at = 0;
            t.tag = $sformatf("ACVP-KAT#%0d", p);
            t.has_expected = 1;
            foreach (vin[i]) begin t.coeffs_in[i] = vin[i]; t.expected[i] = vexp[i]; end
            finish_item(t);
            n_loaded++;
        end
        $fclose(fd);
    endtask

    task body();
        void'($value$plusargs("KEM_KAT=%s", kem_file));
        void'($value$plusargs("DSA_KAT=%s", dsa_file));
        run_file(kem_file, 0);
        run_file(dsa_file, 1);
        `uvm_info("KAT", $sformatf("%0d ACVP-derived KATs driven", n_loaded), UVM_LOW)
    endtask
endclass

// ---------------------------------------------------------------- round-trip
// x -> HW NTT -> HW NTT^-1 must return x exactly.  This is a property of the
// hardware alone (no reference model in the loop), so it independently
// checks the INTT and the n^-1 scaling pass.
class ntt_roundtrip_seq extends ntt_base_seq;
    `uvm_object_utils(ntt_roundtrip_seq)
    int unsigned num_iter = 6;
    int unsigned n_fail;
    function new(string name = "ntt_roundtrip_seq"); super.new(name); endfunction
    task body();
        ntt_seq_item f, b;
        poly_t y;
        for (int it = 0; it < num_iter; it++)
            for (int d = 0; d < 2; d++) begin
                ntt_pattern_e p = (it % 3 == 0) ? PAT_SMALL : (it % 3 == 1) ? PAT_RANDOM : PAT_MAX;
                do_op(f, {1'b0, d[0]}, 0, p);
                foreach (y[i]) y[i] = f.coeffs_out[i];
                do_op_coeffs(b, {1'b0, d[0]}, 1, PAT_CHAINED, y, $sformatf("roundtrip#%0d", it));
                for (int i = 0; i < 256; i++)
                    if (b.coeffs_out[i] != f.coeffs_in[i]) begin
                        `uvm_error("ROUNDTRIP", $sformatf("%s INTT(NTT(x))[%0d] = %0d, x = %0d",
                                   d ? "ML-DSA" : "ML-KEM", i, b.coeffs_out[i], f.coeffs_in[i]))
                        n_fail++;
                        break;
                    end
            end
    endtask
endclass

// ---------------------------------------------------------------- robustness
class ntt_glitch_seq extends ntt_base_seq;
    `uvm_object_utils(ntt_glitch_seq)
    function new(string name = "ntt_glitch_seq"); super.new(name); endfunction
    task body();
        ntt_seq_item t;
        for (int ms = 0; ms < 2; ms++)
            for (int iv = 0; iv < 2; iv++) begin
                do_op(t, ms, iv, PAT_RANDOM, 1);                        // right after accept
                do_op(t, ms, iv, PAT_RANDOM, $urandom_range(900, 2));   // mid-flight
            end
    endtask
endclass

class ntt_b2b_seq extends ntt_base_seq;
    `uvm_object_utils(ntt_b2b_seq)
    function new(string name = "ntt_b2b_seq"); super.new(name); endfunction
    task body();
        ntt_seq_item t;
        repeat (3)
            for (int ms = 0; ms < 2; ms++)
                for (int iv = 0; iv < 2; iv++)
                    do_op(t, ms, iv, PAT_RANDOM, 0, 0);
    endtask
endclass
