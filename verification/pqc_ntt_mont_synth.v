// =============================================================================
// pqc_ntt_v4.v — FINAL corrected NTT/INTT
//
// All prior bugs fixed:
//   1. KEM NTT stops at len=2 (7 layers); DSA stops at len=1 (8 layers)
//   2. tw_k init=0 forward / ROM-size inverse; increment BEFORE use
//   3. INTT uses GS butterfly: u'=U+V, v'=tw*(V-U) not tw*V
//   4. INTT scaling: multiply all coefficients by n_inv after loops
//   5. DSA twiddle ROM: 256 entries
//   6. Barrett TIMING FIX (the v3 root cause):
//      The free-running pipelined Barrett read b1_t with stale coeff_v=0
//      one cycle before coeff_v was latched, propagating 0 through all stages.
//      Fixed with THREE EXPLICIT FSM STATES (S_MUL1, S_MUL2, S_MUL3) that
//      each wait one full cycle for their register to settle before being read.
//   7. Inner-group butterfly path goes through S_ADDR (1 extra cycle) so
//      bram_addr for the next U read has fully settled before S_RD_U latches it.
//   8. LAT_V state ensures BRAM V-slot read has resolved before coeff_v latched.
// =============================================================================
`timescale 1ns/1ps
module pqc_ntt_mont (
    input  wire        clk, rstn, start, inv,
    input  wire [1:0]  mod_sel,
    output reg         busy, done,
    output reg  [14:0] bram_addr,
    output reg  [31:0] bram_wdata,
    input  wire [31:0] bram_rdata,
    output reg         bram_we
);

localparam [22:0] Q_KEM    = 23'd3329;
localparam [22:0] Q_DSA    = 23'd8380417;
localparam [22:0] NINV_KEM = 23'd3303;    // 128^{-1} mod 3329
localparam [22:0] NINV_DSA = 23'd8347681; // 256^{-1} mod 8380417

(* rom_style="block" *) reg [22:0] twiddle_kem[0:127]; // zeta_kem^{br7(i)} mod 3329
(* rom_style="block" *) reg [22:0] twiddle_dsa[0:255]; // zeta_dsa^{br8(i)} mod 8380417
// SYNTHESIS VARIANT: inline twiddle init (no external .hex dependency).
`include "twiddle_init.vh"

// ── State encoding ────────────────────────────────────────────────────────────
localparam [4:0]
    S_IDLE    = 5'd0,
    S_TWINC   = 5'd1,  // advance tw_k, issue U address
    S_RD_U    = 5'd2,  // latch U from bram_rdata; issue V address
    S_RD_V    = 5'd3,  // (addr settled; bram_rdata updating)
    S_LAT_V   = 5'd4,  // latch V from bram_rdata
    S_MUL1    = 5'd5,  // t = coeff_v * tw  (or ninv for scale pass)
    S_MUL2    = 5'd6,  // qest = (t*m) >> shift
    S_MUL3    = 5'd7,  // multiply + wide add -> redc_pre
    S_MUL3B   = 5'd22, // conditional subtract -> mul_res (split for timing)
    S_WR_U    = 5'd8,  // write U butterfly result
    S_WR_V    = 5'd9,  // write V butterfly result
    S_NEXT    = 5'd10, // advance group/layer
    S_ADDR    = 5'd11, // inner-group: issue next U addr, wait 1 cycle
    S_SC_RD   = 5'd12,
    S_SC_WAIT = 5'd20, // INTT scale: read BRAM[0]
    S_SC_LAT  = 5'd13, // latch coefficient for scale multiply
    S_SC_MUL1 = 5'd14, // t = coeff * ninv
    S_SC_MUL2 = 5'd15, // qest = (t*Cbarrett)>>k  (multiply 1 only)
    S_SC_MUL2B= 5'd21, // qestq = qest*q          (multiply 2, split out for timing)
    S_SC_MUL3 = 5'd16, // mul_res = scaled coeff
    S_SC_WR   = 5'd17,
    S_SC_RD2  = 5'd18,
    S_DONE    = 5'd19;

reg [4:0]  state;
reg [7:0]  len, grp_start, j, sc_idx;
reg [8:0]  tw_k;       // 9-bit: holds 0..256 for DSA
reg        direction, mod_r;
reg [22:0] q_active, ninv_active;
reg [22:0] coeff_u, coeff_v;
reg [22:0] gs_diff_r;  // registered (V-U) mod q, computed in S_LAT_V (off the multiply path)

wire [22:0] tw_val = mod_r ? twiddle_dsa[tw_k[7:0]] : twiddle_kem[tw_k[6:0]];

// ── Barrett multiply registers (state-machine controlled) ─────────────────────
// Stage 1: t = a * b  (a = coeff_v for butterfly, coeff for scale)
reg [45:0] mul_t;
reg [63:0] mont_m;    // Montgomery REDC intermediate m = (T_low * q') mod R
// Stage 2: qest = (t * m_kem or t * m_dsa) >> shift
reg [23:0] mul_qest;   // widened to 24b: pipeline reg between the two scaling multiplies
reg [46:0] redc_pre;  // butterfly REDC value before conditional subtract (< 2q)
reg [46:0] mul_qestq;
// Stage 3: result
reg [22:0] mul_res;

// ── GS/CT butterfly outputs ───────────────────────────────────────────────────
// CT NTT:  u' = U + tw*V;   v' = U - tw*V      (tw*V = mul_res)
// GS INTT: u' = U + V;      v' = tw*(V-U)      (tw*(V-U) = mul_res)
wire [23:0] ct_bu_w = {1'b0,coeff_u} + {1'b0,mul_res};
wire [23:0] ct_bv_w = {1'b0,coeff_u} - {1'b0,mul_res} + {1'b0,q_active};
wire [22:0] ct_bu_r = (ct_bu_w >= {1'b0,q_active}) ? ct_bu_w[22:0]-q_active : ct_bu_w[22:0];
wire [22:0] ct_bv_r = (ct_bv_w >= {1'b0,q_active}) ? ct_bv_w[22:0]-q_active : ct_bv_w[22:0];
wire [23:0] gs_bu_w = {1'b0,coeff_u} + {1'b0,coeff_v};
wire [22:0] gs_bu_r = (gs_bu_w >= {1'b0,q_active}) ? gs_bu_w[22:0]-q_active : gs_bu_w[22:0];
wire [22:0] bu_r    = direction ? gs_bu_r  : ct_bu_r;
wire [22:0] bv_r    = direction ? mul_res  : ct_bv_r;

// Termination
wire fwd_done = !direction && ((!mod_r && len==8'd2) || (mod_r && len==8'd1));
wire inv_done =  direction && (len==8'd128);

// ── Barrett helper task (inline Verilog — 3 cycles when called each state) ────
// Not a task — implemented directly in FSM states S_MUL1/2/3 and S_SC_MUL1/2/3.
// The FSM drives these states sequentially; the multiply input is set before S_MULn.

// ── Main FSM ─────────────────────────────────────────────────────────────────
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        state <= S_IDLE; busy<=0; done<=0; bram_we<=0;
        bram_addr<=0; bram_wdata<=0;
        len<=0; grp_start<=0; tw_k<=0; j<=0; sc_idx<=0;
        direction<=0; mod_r<=0;
        q_active<=Q_KEM; ninv_active<=NINV_KEM;
        coeff_u<=0; coeff_v<=0; gs_diff_r<=0;
        mul_t<=0; mul_qest<=0; mul_qestq<=0; mul_res<=0; redc_pre<=0;
    end else begin
        done<=0; bram_we<=0;

        case (state)
        // ── Idle ──────────────────────────────────────────────────────────
        S_IDLE: if (start) begin
            busy        <= 1;
            direction   <= inv;
            mod_r       <= mod_sel[0];
            q_active    <= mod_sel[0] ? Q_DSA    : Q_KEM;
            ninv_active <= mod_sel[0] ? NINV_DSA : NINV_KEM;
            j           <= 8'd0;
            grp_start   <= 8'd0;
            if (!inv) begin
                len   <= 8'd128;
                tw_k  <= 9'd0;          // first TWINC → 1
            end else begin
                len   <= mod_sel[0] ? 8'd1   : 8'd2;
                tw_k  <= mod_sel[0] ? 9'd256 : 9'd128; // first TWINC → 255/127
            end
            state <= S_TWINC;
        end

        // ── Advance twiddle, issue U address ──────────────────────────────
        S_TWINC: begin
            if (!direction) tw_k <= tw_k + 9'd1;
            else            tw_k <= tw_k - 9'd1;
            bram_addr <= {7'b0, grp_start + j};
            state     <= S_ADDR;  // wait for BRAM to resolve new addr
        end

        // ── Latch U, issue V address ───────────────────────────────────────
        // bram_rdata here = bram[addr_from_TWINC] = bram[grp_start+j]  ✓
        S_RD_U: begin
            coeff_u   <= bram_rdata[22:0];
            bram_addr <= {7'b0, grp_start + j + len};
            state     <= S_RD_V;
        end

        // ── Wait for V address to settle ───────────────────────────────────
        S_RD_V: state <= S_LAT_V;

        // ── Latch V ────────────────────────────────────────────────────────
        // bram_rdata = bram[grp_start+j+len]  ✓ (addr set in RD_U, resolved by now)
        S_LAT_V: begin
            coeff_v <= bram_rdata[22:0];
            // Compute (V-U) mod q here, off the multiply's critical path. V is on
            // bram_rdata this cycle; U is already in coeff_u. Registered result
            // feeds S_MUL1's multiply directly (no subtract in that cycle).
            gs_diff_r <= (bram_rdata[22:0] >= coeff_u)
                       ? (bram_rdata[22:0] - coeff_u)
                       : (bram_rdata[22:0] - coeff_u + q_active);
            state   <= S_MUL1;
        end

        // ── Barrett stage 1: t = coeff_v * tw_val ─────────────────────────
        // (For INTT: input to multiplier is gs_diff = (V-U) mod q)
        // coeff_v, tw_val, and gs_diff are all stable here.
        S_MUL1: begin
            // Montgomery: twiddle is stored as zeta*R, so product = operand*zeta*R.
            // A single REDC then yields operand*zeta in the (x*R) working domain.
            mul_t <= direction ? (gs_diff_r * tw_val) : (coeff_v * tw_val);
            state <= S_MUL2;
        end

        // ── Montgomery REDC stage A: compute m = (T_low * q') mod R ─────────
        // KEM: R=2^16, q'=3327.  DSA: R=2^32, q'=4236238847.
        S_MUL2: begin : mul2_blk
            reg [31:0] m_kem;    // T[15:0]*q'  (16*16=32b)
            reg [63:0] m_dsa;    // T[31:0]*q'  (32*32=64b)
            if (mod_r) begin
                m_dsa  = mul_t[31:0] * 32'd4236238847;
                mont_m <= {32'b0, m_dsa[31:0]};
            end else begin
                m_kem  = mul_t[15:0] * 16'd3327;
                mont_m <= {48'b0, m_kem[15:0]};
            end
            state <= S_MUL3;
        end

        // ── Montgomery REDC stage B: t = (T + m*q) >> k  (multiply + wide add) ─
        // Conditional subtract moved to S_MUL3B so this stage is not
        // mult + 56b-add + compare + subtract in one cycle (the -0.968 ns path,
        // 10 CARRY4). Value written to redc_pre is < 2q; reduce next cycle.
        S_MUL3: begin : mul3
            reg [79:0] t_full;
            if (mod_r) begin
                t_full   = {34'b0, mul_t} + (mont_m[31:0] * Q_DSA);
                redc_pre <= t_full[78:32];          // >>32, value < 2q_dsa
            end else begin
                t_full   = {34'b0, mul_t} + (mont_m[15:0] * Q_KEM);
                redc_pre <= t_full[46:16];          // >>16, value < 2q_kem
            end
            state   <= S_MUL3B;
        end

        // ── Montgomery REDC stage C: conditional subtract only ──────────────
        S_MUL3B: begin
            if (mod_r)
                mul_res <= (redc_pre >= {2'b0, Q_DSA}) ? (redc_pre[22:0] - Q_DSA) : redc_pre[22:0];
            else
                mul_res <= (redc_pre >= {2'b0, Q_KEM}) ? (redc_pre[22:0] - Q_KEM) : redc_pre[22:0];
            state   <= S_WR_U;
        end

        // ── Write butterfly results ────────────────────────────────────────
        // mul_res stable (set in MUL3 NB, resolved at start of WR_U)
        S_WR_U: begin
            bram_addr  <= {7'b0, grp_start + j};
            bram_wdata <= {9'b0, bu_r};
            bram_we    <= 1;
            state      <= S_WR_V;
        end

        S_WR_V: begin
            bram_addr  <= {7'b0, grp_start + j + len};
            bram_wdata <= {9'b0, bv_r};
            bram_we    <= 1;
            state      <= S_NEXT;
        end

        // ── Advance butterfly index ────────────────────────────────────────
        S_NEXT: begin
            if (j + 8'd1 < len) begin
                // More butterflies in this group — same twiddle
                j         <= j + 8'd1;
                bram_addr <= {7'b0, grp_start + j + 8'd1};
                state     <= S_ADDR;
            end else begin
                j <= 8'd0;
                if (grp_start + {1'b0,len,1'b0} <= 8'd254) begin
                    // Next group in same layer
                    grp_start <= grp_start + {1'b0,len,1'b0};
                    state     <= S_TWINC;
                end else begin
                    // Layer done
                    grp_start <= 8'd0;
                    if (fwd_done || inv_done) begin
                        state <= direction ? S_SC_RD : S_DONE;
                    end else begin
                        len   <= direction ? len<<1 : len>>1;
                        state <= S_TWINC;
                    end
                end
            end
        end

        // ── Inner-group address settle ─────────────────────────────────────
        // bram_addr was set in S_NEXT; wait one cycle for it to propagate.
        S_ADDR: state <= S_RD_U;

        // ── INTT n_inv scaling pass ────────────────────────────────────────
        // Read each of the 256 coefficients, multiply by ninv, write back.
        S_SC_RD: begin
            sc_idx    <= 8'd0;
            bram_addr <= 15'd0;
            state     <= S_SC_WAIT;
        end

        // Let bram_rdata resolve to bram[0] before SC_LAT latches it
        S_SC_WAIT: state <= S_SC_LAT;

        S_SC_LAT: begin
            coeff_v   <= bram_rdata[22:0];
            state     <= S_SC_MUL1;
        end

        S_SC_MUL1: begin
            mul_t  <= coeff_v * ninv_active;
            state  <= S_SC_MUL2;
        end

        // Barrett reduction split across two cycles so no single stage chains
        // two multiplies (the 15.9 ns / 2-cascaded-DSP critical path). Arithmetic
        // is identical: mul_qestq = (mul_t*Cbarrett)[hi] * q_active, just pipelined.
        S_SC_MUL2: begin : scmul2_blk        // multiply 1: quotient estimate only
            reg [69:0] dsa_prod;
            reg [37:0] kem_prod;
            if (mod_r) begin
                dsa_prod  = mul_t * 70'd8396807;
                mul_qest  <= dsa_prod[69:46];
            end else begin
                kem_prod  = mul_t[23:0] * 38'd5039;
                mul_qest  <= {10'b0, kem_prod[37:24]};
            end
            state <= S_SC_MUL2B;
        end

        S_SC_MUL2B: begin                    // multiply 2: qest * q (registered qest)
            mul_qestq <= mul_qest * q_active;
            state     <= S_SC_MUL3;
        end

        S_SC_MUL3: begin : scmul3
            reg [45:0] r;
            r = mul_t - {1'b0, mul_qestq};
            mul_res <= (r >= {23'b0, q_active}) ? r[22:0] - q_active : r[22:0];
            state   <= S_SC_WR;
        end

        // Write scaled result; THEN issue next read address in a separate cycle
        S_SC_WR: begin
            bram_we    <= 1;
            bram_addr  <= {7'b0, sc_idx};
            bram_wdata <= {9'b0, mul_res};
            sc_idx     <= sc_idx + 8'd1;
            if (sc_idx == 8'd255) state <= S_DONE;
            else                  state <= S_SC_RD2;
        end

        // Issue read address for next coefficient to scale
        S_SC_RD2: begin
            bram_addr <= {7'b0, sc_idx};   // sc_idx already incremented in SC_WR
            state     <= S_SC_WAIT;        // wait for BRAM to resolve new address
        end

        S_DONE: begin busy<=0; done<=1; state<=S_IDLE; end
        default: state <= S_IDLE;
        endcase
    end
end
endmodule
