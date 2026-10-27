// =============================================================================
// ntt_seq_item.svh -- one polynomial operation: NTT or NTT^-1 on 256 coeffs
// =============================================================================
typedef enum int {
    PAT_RANDOM,     // uniform in [0, q)
    PAT_ZERO,       // all 0
    PAT_MAX,        // all q-1 (largest products through the reducer)
    PAT_IMPULSE,    // single non-zero coefficient at a random index
    PAT_SPARSE,     // ~1/16 non-zero
    PAT_ALT,        // 0, q-1, 0, q-1 ...
    PAT_SMALL,      // centered small values {q-eta..q-1, 0..eta} (secret-like)
    PAT_NEAR_Q,     // uniform in [q-16, q)
    PAT_KAT,        // supplied by a NIST-ACVP-derived KAT file
    PAT_CHAINED     // output of a previous HW op (round-trip)
} ntt_pattern_e;

class ntt_seq_item extends uvm_sequence_item;

    // ---------------- stimulus
    rand bit [1:0]      mod_sel;       // bit0 selects modulus; bit1 is don't-care
    rand bit            inv;
    rand ntt_pattern_e  pattern;
    rand int unsigned   idle_cycles;   // gap before start (0 = back-to-back)
    rand int unsigned   glitch_at;     // 0 = none; else re-pulse start N cycles into op
    int unsigned        coeffs_in [256];

    // optional externally-supplied expected result (KAT)
    bit                 has_expected;
    int unsigned        expected  [256];
    string              tag;           // provenance label for reports

    // ---------------- response (filled by driver / monitor)
    int unsigned        coeffs_out [256];
    int unsigned        latency;       // cycles: start accepted -> done
    int unsigned        n_writes;      // BRAM writes observed during the op

    constraint c_pat_default { pattern != PAT_KAT; pattern != PAT_CHAINED; }
    constraint c_idle  { idle_cycles dist { 0 := 2, [1:4] := 3, [5:40] := 1 }; }
    constraint c_glitch { glitch_at == 0; }

    `uvm_object_utils_begin(ntt_seq_item)
        `uvm_field_int (mod_sel,     UVM_ALL_ON)
        `uvm_field_int (inv,         UVM_ALL_ON)
        `uvm_field_enum(ntt_pattern_e, pattern, UVM_ALL_ON)
        `uvm_field_int (idle_cycles, UVM_ALL_ON | UVM_NOCOMPARE)
        `uvm_field_int (glitch_at,   UVM_ALL_ON | UVM_NOCOMPARE)
        `uvm_field_int (latency,     UVM_ALL_ON | UVM_NOCOMPARE)
        `uvm_field_string(tag,       UVM_ALL_ON | UVM_NOCOMPARE)
    `uvm_object_utils_end

    function new(string name = "ntt_seq_item");
        super.new(name);
    endfunction

    function bit dsa();       return mod_sel[0];                     endfunction
    function int unsigned q(); return dsa() ? 8380417 : 3329;        endfunction
    function string mode_str();
        return $sformatf("%s-%s", dsa() ? "ML-DSA" : "ML-KEM", inv ? string'("INTT") : string'("NTT"));
    endfunction

    // Fill coeffs_in from the pattern (KAT / CHAINED are filled by the sequence)
    function void post_randomize();
        int unsigned qq  = q();
        int unsigned eta = dsa() ? 4 : 3;
        int unsigned pos = $urandom_range(255, 0);
        if (pattern == PAT_KAT || pattern == PAT_CHAINED) return;
        for (int i = 0; i < 256; i++) begin
            case (pattern)
                PAT_RANDOM : coeffs_in[i] = $urandom_range(qq-1, 0);
                PAT_ZERO   : coeffs_in[i] = 0;
                PAT_MAX    : coeffs_in[i] = qq - 1;
                PAT_IMPULSE: coeffs_in[i] = (i == pos) ? $urandom_range(qq-1, 1) : 0;
                PAT_SPARSE : coeffs_in[i] = ($urandom_range(15, 0) == 0) ? $urandom_range(qq-1, 1) : 0;
                PAT_ALT    : coeffs_in[i] = i[0] ? qq - 1 : 0;
                PAT_SMALL  : begin
                                 int signed s = $urandom_range(2*eta, 0) - int'(eta);
                                 coeffs_in[i] = (s < 0) ? qq + s : s;
                             end
                PAT_NEAR_Q : coeffs_in[i] = $urandom_range(qq-1, qq-16);
                default    : coeffs_in[i] = 0;
            endcase
        end
    endfunction

    function string convert2string();
        return $sformatf("%s mod_sel=%0d pat=%s idle=%0d glitch=%0d lat=%0d %s",
                         mode_str(), mod_sel, pattern.name(), idle_cycles,
                         glitch_at, latency, tag);
    endfunction
endclass
