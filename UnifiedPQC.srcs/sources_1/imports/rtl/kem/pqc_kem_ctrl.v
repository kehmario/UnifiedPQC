// =============================================================================
// pqc_kem_ctrl.v
// ML-KEM (FIPS 203) control plane — sequences KeyGen, Encaps, Decaps
//
// Parameterized by k (security level):
//   k=2: ML-KEM-512   (n=256, q=3329, 2 polynomials)
//   k=3: ML-KEM-768
//   k=4: ML-KEM-1024
//
// Operation sequence (KeyGen example):
//   1. Request hash engine → run H(d) to get rho, sigma
//   2. Request NTT → ExpandA: for each (i,j) run SampleNTT via SHAKE-128
//   3. Request hash → CBD(sigma, eta) to sample s, e
//   4. Request NTT → NTT(s), NTT(e)
//   5. Request mul+add → t̂ = Â·ŝ + ê
//   6. Pack and store pk = (rho, ByteEncode(t̂))
//   7. Pack sk = (dk_pke, ek, H(ek), z)
//   8. Assert done
// =============================================================================
`timescale 1ns/1ps

module pqc_kem_ctrl (
    input  wire       clk,
    input  wire       rstn,
    input  wire       start,
    input  wire [1:0] cmd,    // 0=KeyGen, 1=Encaps, 2=Decaps
    input  wire [1:0] k,      // 2/3/4
    output reg        busy,
    output reg        done,
    output reg        error,

    // NTT bus
    output reg        ntt_req,
    input  wire       ntt_gnt,
    output reg        ntt_start,
    output reg        ntt_inv,
    output reg [1:0]  ntt_mod_sel,
    input  wire       ntt_busy,
    input  wire       ntt_done,

    // Barrett mul bus
    output reg        mul_req,
    input  wire       mul_gnt,
    output reg [1:0]  mul_mod_sel,
    output reg [22:0] mul_a,
    output reg [22:0] mul_b,
    output reg        mul_valid_in,
    input  wire [22:0] mul_result,
    input  wire       mul_valid_out,

    // Hash bus
    output reg        hash_req,
    input  wire       hash_gnt,
    output reg [2:0]  hash_fn,
    output reg        hash_init,
    output reg        hash_absorb,
    output reg        hash_squeeze,
    output reg [63:0] hash_din,
    output reg [3:0]  hash_din_valid,
    input  wire [63:0] hash_dout,
    input  wire       hash_dout_valid,
    input  wire       hash_busy,

    // BRAM port B
    output reg [14:0] bram_addr,
    output reg [31:0] bram_wdata,
    input  wire [31:0] bram_rdata,
    output reg        bram_we
);

// ---------------------------------------------------------------------------
// BRAM address layout for KEM
// ---------------------------------------------------------------------------
localparam BRAM_S1      = 15'h0000;  // s vector (k polys × 256 words)
localparam BRAM_E       = 15'h0400;  // e vector
localparam BRAM_T_HAT   = 15'h0800;  // t̂ = Â·ŝ+ê (k polys)
localparam BRAM_A_HAT   = 15'h0C00;  // Â matrix (k×k polys)
localparam BRAM_KEY     = 15'h2000;  // rho(32B), sigma(32B), shared secret(32B)
localparam BRAM_MSG     = 15'h2100;  // message m (32B)
localparam BRAM_COIN    = 15'h2110;  // coins r (32B)

// ---------------------------------------------------------------------------
// FSM states
// ---------------------------------------------------------------------------
localparam [4:0]
    S_IDLE         = 5'd0,
    S_KG_HASH_SEED = 5'd1,   // H(d) → rho, sigma
    S_KG_EXPAND_A  = 5'd2,   // SampleNTT for each Â[i][j]
    S_KG_SAMPLE_S  = 5'd3,   // CBD_eta(sigma, 0..k-1) → s
    S_KG_SAMPLE_E  = 5'd4,   // CBD_eta(sigma, k..2k-1) → e
    S_KG_NTT_S     = 5'd5,   // NTT(s_i)
    S_KG_NTT_E     = 5'd6,   // NTT(e_i)
    S_KG_MATRIX_MUL= 5'd7,   // t̂ ← Â·ŝ
    S_KG_ADD_E     = 5'd8,   // t̂ ← t̂ + ê
    S_KG_PACK_PK   = 5'd9,   // ByteEncode(t̂) || rho
    S_KG_PACK_SK   = 5'd10,  // pack decryption key
    S_ENC_START    = 5'd11,
    S_DEC_START    = 5'd12,
    S_DONE         = 5'd13,
    S_ERROR        = 5'd14;

reg [4:0] state;
reg [1:0] poly_i, poly_j;   // loop counters for matrix operations
reg [7:0] coeff_cnt;         // coefficient loop counter

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        state    <= S_IDLE;
        busy     <= 0; done <= 0; error <= 0;
        ntt_req  <= 0; ntt_start <= 0; ntt_inv <= 0; ntt_mod_sel <= 0;
        mul_req  <= 0; mul_valid_in <= 0; mul_mod_sel <= 0;
        hash_req <= 0; hash_init <= 0; hash_absorb <= 0; hash_squeeze <= 0;
        bram_we  <= 0;
        poly_i   <= 0; poly_j <= 0; coeff_cnt <= 0;
    end else begin
        // Defaults (pulse signals)
        ntt_start   <= 0;
        hash_init   <= 0;
        hash_absorb <= 0;
        hash_squeeze<= 0;
        mul_valid_in<= 0;
        bram_we     <= 0;
        done        <= 0;

        case (state)
        S_IDLE: begin
            if (start) begin
                busy   <= 1;
                poly_i <= 0; poly_j <= 0; coeff_cnt <= 0;
                case (cmd)
                    2'd0: state <= S_KG_HASH_SEED;
                    2'd1: state <= S_ENC_START;
                    2'd2: state <= S_DEC_START;
                    default: state <= S_ERROR;
                endcase
            end
        end

        // ── KeyGen: Step 1 — H(d) to get rho and sigma ──────────────
        S_KG_HASH_SEED: begin
            hash_req <= 1;
            if (hash_gnt) begin
                hash_fn     <= 3'd1;  // SHA3-512
                hash_init   <= 1;
                // Load seed d from BRAM_KEY (pre-loaded by host)
                bram_addr   <= BRAM_KEY;
                // Next cycle: absorb 32 bytes of d
                hash_absorb  <= 1;
                hash_din     <= {32'b0, bram_rdata};  // BRAM port is 32 bits wide
                hash_din_valid <= 4'hF;
                // After absorb+squeeze: rho = first 32B, sigma = next 32B
                // Store back to BRAM (FSM continues on hash_dout_valid)
                if (hash_dout_valid) begin
                    bram_we    <= 1;
                    bram_addr  <= BRAM_KEY;
                    bram_wdata <= hash_dout[31:0];
                    hash_req   <= 0;
                    state      <= S_KG_EXPAND_A;
                end
            end
        end

        // ── KeyGen: Step 2 — ExpandA (SampleNTT for k×k matrix) ────
        S_KG_EXPAND_A: begin
            hash_req <= 1;
            if (hash_gnt) begin
                hash_fn    <= 3'd2;  // SHAKE-128
                hash_init  <= 1;
                // Feed XOF with (rho || j || i) as seed
                // Write NTT output to BRAM_A_HAT + (poly_i*k + poly_j)*256
                hash_squeeze <= 1;
                if (hash_dout_valid) begin
                    // Rejection-sample and write coefficient to BRAM
                    bram_we    <= 1;
                    bram_addr  <= BRAM_A_HAT + poly_i * (k * 256) +
                                  poly_j * 256 + coeff_cnt;
                    bram_wdata <= {9'b0, hash_dout[22:0]};  // placeholder
                    coeff_cnt  <= coeff_cnt + 1;
                    if (coeff_cnt == 8'd255) begin
                        coeff_cnt <= 0;
                        if (poly_j < k - 1) poly_j <= poly_j + 1;
                        else begin
                            poly_j <= 0;
                            if (poly_i < k - 1) poly_i <= poly_i + 1;
                            else begin
                                poly_i  <= 0;
                                hash_req <= 0;
                                state   <= S_KG_SAMPLE_S;
                            end
                        end
                    end
                end
            end
        end

        // ── KeyGen: Step 3/4 — Sample s and e via CBD_eta ───────────
        S_KG_SAMPLE_S: begin
            // PRF(sigma, N) → CBD_eta → s_i, then NTT(s_i)
            // (abbreviated FSM — full version loops over k polynomials)
            hash_req <= 1;
            if (hash_gnt && !hash_busy) begin
                hash_fn    <= 3'd3;  // SHAKE-256 (PRF)
                hash_init  <= 1;
                hash_absorb<= 1;
                // After sampling, trigger NTT
                if (hash_dout_valid) begin
                    hash_req <= 0;
                    state    <= S_KG_SAMPLE_E;
                end
            end
        end

        S_KG_SAMPLE_E: begin
            state <= S_KG_NTT_S;
        end

        // ── KeyGen: NTT(s) ───────────────────────────────────────────
        S_KG_NTT_S: begin
            ntt_req    <= 1;
            ntt_mod_sel<= 2'd0;  // q_kem = 3329
            if (ntt_gnt && !ntt_busy) begin
                ntt_start <= 1;
                ntt_inv   <= 0;
            end
            if (ntt_done) begin
                ntt_req <= 0;
                state   <= S_KG_NTT_E;
            end
        end

        // ── KeyGen: NTT(e) ───────────────────────────────────────────
        S_KG_NTT_E: begin
            ntt_req <= 1;
            if (ntt_gnt && !ntt_busy) begin
                ntt_start <= 1;
                ntt_inv   <= 0;
            end
            if (ntt_done) begin
                ntt_req <= 0;
                state   <= S_KG_MATRIX_MUL;
            end
        end

        // ── KeyGen: t̂ = Â·ŝ (NTT-domain point-wise mul) ────────────
        S_KG_MATRIX_MUL: begin
            mul_req     <= 1;
            mul_mod_sel <= 2'd0;
            if (mul_gnt) begin
                // For each i,j: load Â[i][j] and ŝ[j], multiply, accumulate
                // (simplified: one mul per state tick; real version pipelines)
                bram_addr   <= BRAM_A_HAT + poly_i * (k * 256) +
                               poly_j * 256 + coeff_cnt;
                mul_a       <= bram_rdata[22:0];
                bram_addr   <= BRAM_S1 + poly_j * 256 + coeff_cnt;
                mul_b       <= bram_rdata[22:0];
                mul_valid_in<= 1;
                if (mul_valid_out) begin
                    bram_we    <= 1;
                    bram_addr  <= BRAM_T_HAT + poly_i * 256 + coeff_cnt;
                    bram_wdata <= {9'b0, mul_result};
                    coeff_cnt  <= coeff_cnt + 1;
                    if (coeff_cnt == 8'd255) begin
                        coeff_cnt <= 0;
                        if (poly_j < k-1) poly_j <= poly_j + 1;
                        else begin
                            poly_j <= 0;
                            if (poly_i < k-1) poly_i <= poly_i + 1;
                            else begin
                                mul_req <= 0;
                                state   <= S_KG_ADD_E;
                            end
                        end
                    end
                end
            end
        end

        // ── KeyGen: t̂ ← t̂ + ê ──────────────────────────────────────
        S_KG_ADD_E: begin
            // Point-wise addition in Z_q (no multiplier needed)
            // Load t̂[coeff] and ê[coeff], add mod q, write back
            bram_addr <= BRAM_T_HAT + poly_i * 256 + coeff_cnt;
            // (combinatorial add with conditional subtract)
            coeff_cnt <= coeff_cnt + 1;
            if (coeff_cnt == 8'd255) begin
                if (poly_i < k-1) poly_i <= poly_i + 1;
                else begin
                    poly_i <= 0;
                    state  <= S_KG_PACK_PK;
                end
            end
        end

        S_KG_PACK_PK, S_KG_PACK_SK: begin
            // ByteEncode / pack into BRAM output area then signal done
            state <= S_DONE;
        end

        S_ENC_START, S_DEC_START: begin
            // Placeholder: encapsulation and decapsulation follow same
            // structure (hash → sample r → NTT → matrix-mul → compress → pack)
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
