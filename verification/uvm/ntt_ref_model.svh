// =============================================================================
// ntt_ref_model.svh -- spec-literal FIPS 203 / FIPS 204 NTT reference
//
// Deliberately INDEPENDENT of the hardware:
//   * zetas are computed here by modular exponentiation from the primitive
//     roots in the standards (17 for q=3329, 1753 for q=8380417), not taken
//     from twiddle_init.vh (which stores Montgomery-domain values)
//   * plain (a*b) % q arithmetic, no Montgomery / Barrett
//   * loop structure transcribed from the standards:
//       ML-KEM  NTT  = FIPS 203 Alg. 9,  NTT^-1 = Alg. 10 (scale by 3303)
//       ML-DSA  NTT  = FIPS 204 Alg. 41, NTT^-1 = Alg. 42 (scale by 8347681,
//                      with the spec's z = -zetas[m] form kept verbatim)
// The KAT test also cross-checks this model against the NIST-ACVP-derived
// vectors, so the oracle itself is anchored, not assumed.
// =============================================================================
typedef int unsigned poly_t [256];

class ntt_ref_model;

    localparam longint unsigned Q_KEM = 3329;
    localparam longint unsigned Q_DSA = 8380417;

    static function longint unsigned q_of(bit dsa);
        return dsa ? Q_DSA : Q_KEM;
    endfunction

    static function longint unsigned powmod(longint unsigned b,
                                            longint unsigned e,
                                            longint unsigned m);
        longint unsigned r = 1;
        b = b % m;
        while (e != 0) begin
            if (e[0]) r = (r * b) % m;
            b = (b * b) % m;
            e = e >> 1;
        end
        return r;
    endfunction

    static function int unsigned brv(int unsigned x, int unsigned bits);
        int unsigned r = 0;
        for (int i = 0; i < bits; i++) r = (r << 1) | ((x >> i) & 1);
        return r;
    endfunction

    static function longint unsigned zeta(bit dsa, int unsigned k);
        if (dsa) return powmod(1753, brv(k, 8), Q_DSA);
        else     return powmod(17,   brv(k, 7), Q_KEM);
    endfunction

    // ------------------------------------------------------------------ NTT
    static function void compute(bit dsa, bit inv, input poly_t a, output poly_t f);
        longint unsigned q = q_of(dsa);
        longint unsigned w[256];
        longint unsigned z, t;
        int unsigned k;
        for (int i = 0; i < 256; i++) w[i] = a[i] % q;

        if (!dsa && !inv) begin                        // FIPS 203 Alg. 9
            k = 1;
            for (int len = 128; len >= 2; len /= 2)
                for (int start = 0; start < 256; start += 2*len) begin
                    z = zeta(0, k); k++;
                    for (int j = start; j < start + len; j++) begin
                        t          = (z * w[j+len]) % q;
                        w[j+len]   = (w[j] + q - t) % q;
                        w[j]       = (w[j] + t) % q;
                    end
                end
        end else if (!dsa && inv) begin                // FIPS 203 Alg. 10
            k = 127;
            for (int len = 2; len <= 128; len *= 2)
                for (int start = 0; start < 256; start += 2*len) begin
                    z = zeta(0, k); k--;
                    for (int j = start; j < start + len; j++) begin
                        t          = w[j];
                        w[j]       = (t + w[j+len]) % q;
                        w[j+len]   = (z * ((w[j+len] + q - t) % q)) % q;
                    end
                end
            for (int i = 0; i < 256; i++) w[i] = (w[i] * 3303) % q;
        end else if (dsa && !inv) begin                // FIPS 204 Alg. 41
            k = 0;
            for (int len = 128; len >= 1; len /= 2)
                for (int start = 0; start < 256; start += 2*len) begin
                    k++; z = zeta(1, k);
                    for (int j = start; j < start + len; j++) begin
                        t          = (z * w[j+len]) % q;
                        w[j+len]   = (w[j] + q - t) % q;
                        w[j]       = (w[j] + t) % q;
                    end
                end
        end else begin                                 // FIPS 204 Alg. 42
            k = 256;
            for (int len = 1; len < 256; len *= 2)
                for (int start = 0; start < 256; start += 2*len) begin
                    k--; z = (q - zeta(1, k)) % q;     // z = -zetas[m]
                    for (int j = start; j < start + len; j++) begin
                        t          = w[j];
                        w[j]       = (t + w[j+len]) % q;
                        w[j+len]   = (t + q - w[j+len]) % q;
                        w[j+len]   = (z * w[j+len]) % q;
                    end
                end
            for (int i = 0; i < 256; i++) w[i] = (w[i] * 8347681) % q;
        end
        for (int i = 0; i < 256; i++) f[i] = int'(w[i]);
    endfunction

    // Sanity: spec constants derived, not trusted
    static function bit self_check(output string msg);
        if (powmod(17, 256, Q_KEM) != 1 || powmod(17, 128, Q_KEM) == 1) begin
            msg = "17 is not a primitive 256th root of unity mod 3329"; return 0;
        end
        if (powmod(1753, 512, Q_DSA) != 1 || powmod(1753, 256, Q_DSA) == 1) begin
            msg = "1753 is not a primitive 512th root of unity mod 8380417"; return 0;
        end
        if ((128 * 3303) % Q_KEM != 1) begin msg = "3303 != 128^-1 mod 3329"; return 0; end
        if ((256 * 8347681) % Q_DSA != 1) begin msg = "8347681 != 256^-1 mod q_dsa"; return 0; end
        msg = "ok"; return 1;
    endfunction
endclass
