// =============================================================================
// pqc_barrett_mul.v
// Dual-modulus Barrett modular multiplier
//   mod_sel=0: q = 3329      (12-bit, ML-KEM)
//   mod_sel=1: q = 8380417   (23-bit, ML-DSA)
//
// Pipeline depth: 4 cycles from valid_in to valid_out
// Throughput: 1 result / clock once pipeline is primed
// Resource: 2 × DSP48E1 (one for mul, one for correction multiply)
// =============================================================================
`timescale 1ns/1ps

module pqc_barrett_mul (
    input  wire        clk,
    input  wire        rstn,
    input  wire [1:0]  mod_sel,    // 0=KEM, 1=DSA
    input  wire [22:0] a,          // operand A
    input  wire [22:0] b,          // operand B
    input  wire        valid_in,
    output reg  [22:0] result,
    output reg         valid_out
);

// ---------------------------------------------------------------------------
// Barrett constants:  k = ceil(log2(q)), m = floor(4^k / q)
//
// q_kem  = 3329      → k=12, m_kem = floor(4^12 / 3329) = 5039360  (23-bit)
// q_dsa  = 8380417   → k=23, m_dsa = floor(4^23 / 8380417) = ≈ 8396807
//
// Reduction formula (24-bit product):
//   t    = a*b                            (23+23 = 46-bit)
//   q_est = (t * m) >> 2k                 (46+23 = 69-bit, shift right 2k)
//   r     = t - q_est * q
//   if r >= q: r -= q
// ---------------------------------------------------------------------------

localparam [22:0] Q_KEM      = 23'd3329;
localparam [22:0] Q_DSA      = 23'd8380417;
localparam [22:0] M_KEM      = 23'd5039360;
localparam [22:0] M_DSA      = 23'd8396807;
localparam [4:0]  SHIFT_KEM  = 5'd24;   // 2*12
localparam [4:0]  SHIFT_DSA  = 5'd46;   // 2*23

// ---------------------------------------------------------------------------
// Pipeline stage registers
// ---------------------------------------------------------------------------
// Stage 1: a×b
reg [45:0] s1_ab;
reg [22:0] s1_q, s1_m;
reg [4:0]  s1_shift;
reg        s1_v;

// Stage 2: (a×b) * m  →  68-bit
reg [68:0] s2_abm;
reg [22:0] s2_q;
reg [4:0]  s2_shift;
reg [45:0] s2_ab;
reg        s2_v;

// Stage 3: shift, q_est * q
reg [22:0] s3_qest;
reg [44:0] s3_qestq;
reg [45:0] s3_ab;
reg [22:0] s3_q;
reg        s3_v;

// Stage 4: subtract, conditional reduce
reg [22:0] s4_r;
reg        s4_v;

reg [45:0] r_wide;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        s1_v <= 0; s2_v <= 0; s3_v <= 0; s4_v <= 0;
        valid_out <= 0;
    end else begin
        // ── Stage 1: product a×b ────────────────────────────────────────
        s1_ab    <= a * b;
        s1_q     <= mod_sel[0] ? Q_DSA : Q_KEM;
        s1_m     <= mod_sel[0] ? M_DSA : M_KEM;
        s1_shift <= mod_sel[0] ? SHIFT_DSA : SHIFT_KEM;
        s1_v     <= valid_in;

        // ── Stage 2: product × m ────────────────────────────────────────
        s2_abm   <= s1_ab * s1_m;
        s2_q     <= s1_q;
        s2_shift <= s1_shift;
        s2_ab    <= s1_ab;
        s2_v     <= s1_v;

        // ── Stage 3: shift to get q_est, multiply q_est×q ───────────────
        s3_qest  <= s2_abm >> s2_shift;
        s3_qestq <= (s2_abm >> s2_shift) * s2_q;
        s3_ab    <= s2_ab;
        s3_q     <= s2_q;
        s3_v     <= s2_v;

        // ── Stage 4: r = ab - qest*q, conditional reduce ────────────────
        begin
            
            r_wide = s3_ab - {1'b0, s3_qestq};
            // One final conditional subtract in case r≥q
            if (r_wide >= {23'b0, s3_q})
                s4_r <= r_wide[22:0] - s3_q;
            else
                s4_r <= r_wide[22:0];
        end
        s4_v <= s3_v;

        // ── Output ──────────────────────────────────────────────────────
        result    <= s4_r;
        valid_out <= s4_v;
    end
end

endmodule
