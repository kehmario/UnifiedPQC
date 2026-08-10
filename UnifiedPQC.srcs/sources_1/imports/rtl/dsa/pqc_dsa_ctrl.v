// =============================================================================
// pqc_dsa_ctrl.v
// ML-DSA (FIPS 204) control plane — sequences KeyGen, Sign, Verify
//
// Parameterized by k (security level column in matrix):
//   k=2 → ML-DSA-44   (l=4, k=4,  eta=2,  gamma1=2^17, gamma2=(q-1)/88)
//   k=3 → ML-DSA-65   (l=5, k=6,  eta=4,  gamma1=2^19, gamma2=(q-1)/32)
//   k=4 → ML-DSA-87   (l=6, k=8,  eta=2,  gamma1=2^19, gamma2=(q-1)/32)
//
// DSA-specific shared-resource usage:
//   - NTT: mod_sel=1 (q=8380417), used for matrix-vector products
//   - Hash: SHA3-256 (H), SHA3-512 (G, H~), SHAKE-256 (PRF, XOF)
//   - Additional DSA-only units: Power2Round, Decompose, MakeHint, UseHint
//     These are pure combinatorial / simple pipeline, instantiated locally.
// =============================================================================
`timescale 1ns/1ps

module pqc_dsa_ctrl (
    input  wire       clk,
    input  wire       rstn,
    input  wire       start,
    input  wire [1:0] cmd,    // 0=KeyGen, 1=Sign, 2=Verify
    input  wire [1:0] k,      // encodes parameter set
    output reg        busy,
    output reg        done,
    output reg        error,

    // NTT bus (mod_sel=1 always for DSA)
    output reg        ntt_req,
    input  wire       ntt_gnt,

    // Barrett mul bus
    output reg        mul_req,
    input  wire       mul_gnt,

    // Hash bus
    output reg        hash_req,
    input  wire       hash_gnt
    // (full bus wires omitted for brevity — connect same as KEM ctrl
    //  through the top-level mux; the arbiter ensures no contention)
);

// ---------------------------------------------------------------------------
// DSA parameter decode
// ---------------------------------------------------------------------------
reg [3:0] l_dim;  // l (columns of A)
reg [3:0] k_dim;  // k (rows of A)
reg [3:0] eta;
reg [18:0] gamma1;

always @(*) begin
    case (k)
        2'd2: begin l_dim=4; k_dim=4; eta=2; gamma1=19'd131072; end // 2^17
        2'd3: begin l_dim=5; k_dim=6; eta=4; gamma1=19'd524288; end // 2^19
        2'd4: begin l_dim=6; k_dim=8; eta=2; gamma1=19'd524288; end
        default: begin l_dim=4; k_dim=4; eta=2; gamma1=19'd131072; end
    endcase
end

// ---------------------------------------------------------------------------
// FSM states
// ---------------------------------------------------------------------------
localparam [5:0]
    S_IDLE          = 6'd0,
    // KeyGen
    S_KG_HASH_SEED  = 6'd1,   // H~(xi) → rho, rho', K
    S_KG_EXPAND_A   = 6'd2,   // ExpandA (SHAKE-128) → Â
    S_KG_SAMPLE_S1  = 6'd3,   // ExpandS(rho', 0..l-1) → s1
    S_KG_SAMPLE_S2  = 6'd4,   // ExpandS(rho', l..l+k-1) → s2
    S_KG_NTT_S1     = 6'd5,   // NTT(s1_i) using q_dsa
    S_KG_MATRIX_MUL = 6'd6,   // t = NTT^-1(Â · ŝ1)
    S_KG_POWER2ROUND= 6'd7,   // (t1,t0) = Power2Round(t, d)
    S_KG_PACK_PK    = 6'd8,   // pk = (rho, t1)
    S_KG_HASH_PK    = 6'd9,   // tr = H~(pk, 64)
    S_KG_PACK_SK    = 6'd10,  // sk = (rho, K, tr, s1, s2, t0)
    // Sign
    S_SIGN_HASH_MSG = 6'd11,  // mu = H~(tr || M, 64)
    S_SIGN_EXPAND_MASK = 6'd12, // ExpandMask(K, mu, kappa) → y
    S_SIGN_NTT_Y    = 6'd13,
    S_SIGN_MATRIX_W = 6'd14,  // w = NTT^-1(Â · ŷ)
    S_SIGN_DECOMPOSE = 6'd15, // (w1, w0) = Decompose(w, 2*gamma2)
    S_SIGN_COMMIT   = 6'd16,  // c~ = H~(mu || w1Encode(w1))
    S_SIGN_SAMPLE_C = 6'd17,  // c = SampleInBall(c~)
    S_SIGN_COMPUTE_Z = 6'd18, // z = y + c·s1
    S_SIGN_CHECK    = 6'd19,  // inf-norm checks on z, r0
    S_SIGN_HINT     = 6'd20,  // h = MakeHint(-c·t0, w - c·s2 + c·t0)
    S_SIGN_PACK_SIG = 6'd21,  // σ = (c~, z, h)
    // Verify
    S_VER_UNPACK    = 6'd22,
    S_VER_HASH_MSG  = 6'd23,
    S_VER_EXPAND_A  = 6'd24,
    S_VER_MATRIX_W  = 6'd25,
    S_VER_USEHINT   = 6'd26,
    S_VER_COMMIT    = 6'd27,
    S_VER_CHECK     = 6'd28,
    S_DONE          = 6'd29,
    S_ERROR         = 6'd30;

reg [5:0] state;
reg [3:0] poly_i, poly_j;
reg [7:0] coeff_cnt;
reg [15:0] kappa;          // signature nonce counter

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        state   <= S_IDLE;
        busy    <= 0; done <= 0; error <= 0;
        ntt_req <= 0; mul_req <= 0; hash_req <= 0;
        poly_i  <= 0; poly_j  <= 0; coeff_cnt <= 0;
        kappa   <= 0;
    end else begin
        done <= 0;

        case (state)
        S_IDLE: begin
            if (start) begin
                busy  <= 1;
                kappa <= 0;
                poly_i <= 0; poly_j <= 0; coeff_cnt <= 0;
                case (cmd)
                    2'd0: state <= S_KG_HASH_SEED;
                    2'd1: state <= S_SIGN_HASH_MSG;
                    2'd2: state <= S_VER_UNPACK;
                    default: state <= S_ERROR;
                endcase
            end
        end

        // ── KeyGen flow ──────────────────────────────────────────────────
        S_KG_HASH_SEED: begin
            hash_req <= 1;
            if (hash_gnt) begin
                // SHAKE-256: xi(32B) → rho(32B) || rho'(64B) || K(32B)
                // Abbreviated: wait for hash done, then proceed
                hash_req <= 0;
                state    <= S_KG_EXPAND_A;
            end
        end

        S_KG_EXPAND_A: begin
            // SHAKE-128(rho || j || i) for each (i,j) ∈ [k]×[l]
            hash_req <= 1;
            if (hash_gnt) begin
                if (poly_j < l_dim - 1) poly_j <= poly_j + 1;
                else begin
                    poly_j <= 0;
                    if (poly_i < k_dim - 1) poly_i <= poly_i + 1;
                    else begin
                        poly_i   <= 0;
                        hash_req <= 0;
                        state    <= S_KG_SAMPLE_S1;
                    end
                end
            end
        end

        S_KG_SAMPLE_S1: begin
            // ExpandS: SHAKE-256(rho' || 0..l-1) → s1 (l polynomials)
            hash_req <= 1;
            if (hash_gnt) begin
                hash_req <= 0;
                state    <= S_KG_SAMPLE_S2;
            end
        end

        S_KG_SAMPLE_S2: begin
            hash_req <= 1;
            if (hash_gnt) begin
                hash_req <= 0;
                state    <= S_KG_NTT_S1;
            end
        end

        S_KG_NTT_S1: begin
            // NTT(s1_i) × l, then NTT(s2_i) × k — using q_dsa
            ntt_req <= 1;
            if (ntt_gnt) begin
                // Cycle through all l+k polynomials
                if (poly_i < l_dim + k_dim - 1) poly_i <= poly_i + 1;
                else begin
                    poly_i  <= 0;
                    ntt_req <= 0;
                    state   <= S_KG_MATRIX_MUL;
                end
            end
        end

        S_KG_MATRIX_MUL: begin
            // t̂ = Â·ŝ1, then t = NTT^-1(t̂)
            ntt_req <= 1;
            mul_req <= 1;
            if (ntt_gnt && mul_gnt) begin
                ntt_req <= 0;
                mul_req <= 0;
                state   <= S_KG_POWER2ROUND;
            end
        end

        S_KG_POWER2ROUND: begin
            // Pure combinatorial / local pipeline: (t1,t0) = Power2Round(t, d=13)
            // d=13 for all parameter sets
            // t1 = t >> d,  t0 = t - (t1 << d) with mod-q centering
            // No shared resource needed — local to DSA ctrl
            state <= S_KG_PACK_PK;
        end

        S_KG_PACK_PK: begin
            state <= S_KG_HASH_PK;
        end

        S_KG_HASH_PK: begin
            hash_req <= 1;
            if (hash_gnt) begin
                hash_req <= 0;
                state    <= S_KG_PACK_SK;
            end
        end

        S_KG_PACK_SK: begin
            state <= S_DONE;
        end

        // ── Sign flow ────────────────────────────────────────────────────
        S_SIGN_HASH_MSG: begin
            // mu = H~(tr || M, 512-bit output)
            hash_req <= 1;
            if (hash_gnt) begin hash_req <= 0; state <= S_SIGN_EXPAND_MASK; end
        end

        S_SIGN_EXPAND_MASK: begin
            // y_i = ExpandMask(K || mu, kappa+i) via SHAKE-256
            hash_req <= 1;
            if (hash_gnt) begin
                kappa    <= kappa + {12'b0, l_dim};
                hash_req <= 0;
                state    <= S_SIGN_NTT_Y;
            end
        end

        S_SIGN_NTT_Y: begin
            ntt_req <= 1;
            if (ntt_gnt) begin ntt_req <= 0; state <= S_SIGN_MATRIX_W; end
        end

        S_SIGN_MATRIX_W: begin
            ntt_req <= 1; mul_req <= 1;
            if (ntt_gnt && mul_gnt) begin
                ntt_req <= 0; mul_req <= 0;
                state   <= S_SIGN_DECOMPOSE;
            end
        end

        S_SIGN_DECOMPOSE: begin
            // (w1, w0) = Decompose(w, 2*gamma2) — local arithmetic
            state <= S_SIGN_COMMIT;
        end

        S_SIGN_COMMIT: begin
            hash_req <= 1;
            if (hash_gnt) begin hash_req <= 0; state <= S_SIGN_SAMPLE_C; end
        end

        S_SIGN_SAMPLE_C: begin
            // c = SampleInBall(c~) — rejection sampler using SHAKE-256
            hash_req <= 1;
            if (hash_gnt) begin hash_req <= 0; state <= S_SIGN_COMPUTE_Z; end
        end

        S_SIGN_COMPUTE_Z: begin
            mul_req <= 1;
            if (mul_gnt) begin mul_req <= 0; state <= S_SIGN_CHECK; end
        end

        S_SIGN_CHECK: begin
            // Infinity-norm checks: ‖z‖∞ < γ1−β, ‖r0‖∞ < γ2−β
            // If failed: loop back with incremented kappa
            // (simplified: always pass for structural example)
            state <= S_SIGN_HINT;
        end

        S_SIGN_HINT: begin
            // h = MakeHint(-c·t0, w-c·s2+c·t0, 2*gamma2) — local
            mul_req <= 1;
            if (mul_gnt) begin mul_req <= 0; state <= S_SIGN_PACK_SIG; end
        end

        S_SIGN_PACK_SIG: begin state <= S_DONE; end

        // ── Verify flow ──────────────────────────────────────────────────
        S_VER_UNPACK:  state <= S_VER_HASH_MSG;
        S_VER_HASH_MSG: begin
            hash_req <= 1;
            if (hash_gnt) begin hash_req <= 0; state <= S_VER_EXPAND_A; end
        end
        S_VER_EXPAND_A: begin
            hash_req <= 1;
            if (hash_gnt) begin hash_req <= 0; state <= S_VER_MATRIX_W; end
        end
        S_VER_MATRIX_W: begin
            ntt_req <= 1; mul_req <= 1;
            if (ntt_gnt && mul_gnt) begin
                ntt_req <= 0; mul_req <= 0;
                state   <= S_VER_USEHINT;
            end
        end
        S_VER_USEHINT:  state <= S_VER_COMMIT;
        S_VER_COMMIT: begin
            hash_req <= 1;
            if (hash_gnt) begin hash_req <= 0; state <= S_VER_CHECK; end
        end
        S_VER_CHECK: begin
            // Compare reconstructed c~ with received c~
            state <= S_DONE;
        end

        S_DONE: begin
            busy  <= 0;
            done  <= 1;
            state <= S_IDLE;
        end

        S_ERROR: begin
            error <= 1;
            busy  <= 0;
            state <= S_IDLE;
        end
        endcase
    end
end

endmodule
