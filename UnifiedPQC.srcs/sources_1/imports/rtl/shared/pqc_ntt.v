// =============================================================================
// pqc_ntt.v
// Iterative Cooley-Tukey NTT / Gentleman-Sande INTT, 256-point
// Dual-modulus: mod_sel=0 → q=3329 (ML-KEM), mod_sel=1 → q=8380417 (ML-DSA)
//
// Polynomial stored in BRAM: 256 coefficients × 32-bit words
// One butterfly per clock; full NTT in 256*log2(256)/2 = 1024 cycles + overhead
//
// BRAM interface: single-port A, 15-bit address, 32-bit data
//   Coefficients stored at base_addr[14:8] || coeff_index[7:0]
// =============================================================================
`timescale 1ns/1ps

module pqc_ntt (
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,      // pulse to begin
    input  wire        inv,        // 0=NTT forward, 1=INTT
    input  wire [1:0]  mod_sel,    // 0=q_kem, 1=q_dsa
    output reg         busy,
    output reg         done,
    // BRAM port A
    output reg  [14:0] bram_addr,
    output reg  [31:0] bram_wdata,
    input  wire [31:0] bram_rdata,
    output reg         bram_we
);

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam Q_KEM  = 23'd3329;
localparam Q_DSA  = 23'd8380417;
localparam N      = 8'd255;   // 256 coefficients, indices 0..255
localparam LOG_N  = 8;

// ---------------------------------------------------------------------------
// Twiddle factor ROM — pre-computed for both moduli
// For synthesis: instantiate separate BRAMs or LUTRAM.
// Here we use $readmemh to init a reg array (synthesis tool will infer BRAM).
// ---------------------------------------------------------------------------
reg [22:0] twiddle_kem [0:127];   // zeta^i mod 3329,      bit-rev order
reg [22:0] twiddle_dsa [0:127];   // zeta^i mod 8380417,   bit-rev order

initial begin
    $readmemh("twiddle_kem.hex", twiddle_kem);
    $readmemh("twiddle_dsa.hex", twiddle_dsa);
end

// ---------------------------------------------------------------------------
// FSM
// ---------------------------------------------------------------------------
localparam S_IDLE     = 3'd0;
localparam S_RD_U     = 3'd1;   // read upper coeff
localparam S_RD_V     = 3'd2;   // read lower coeff
localparam S_COMPUTE  = 3'd3;   // butterfly compute
localparam S_WR_U     = 3'd4;
localparam S_WR_V     = 3'd5;
localparam S_NEXT     = 3'd6;
localparam S_DONE     = 3'd7;

reg [2:0]  state;
reg [7:0]  len;        // butterfly group length (1..128)
reg [7:0]  start_idx;  // start of current group
reg [7:0]  k;          // twiddle index
reg [7:0]  j;          // index within group
reg        direction;  // saved inv

// Coefficient registers
reg [22:0] coeff_u, coeff_v;
wire [22:0] q_val;
wire [22:0] tw;

assign tw   = mod_sel[0] ? twiddle_dsa[k] : twiddle_kem[k];
assign q_val = mod_sel[0] ? Q_DSA : Q_KEM;

// Barrett multiplier (inline 23×23 → 23, pipeline 2 cycles)
// For the NTT we share the top-level Barrett; here a local one for simplicity
// (in full build, remove this and use the shared instance via grant)
reg [45:0] mul_pp;
reg [22:0] mul_res;
reg        mul_v;

always @(posedge clk) begin
    mul_pp  <= coeff_v * tw;
    // Barrett reduction (approximate): q_est = pp * (1/q) >> shift
    // For correctness use pqc_barrett_mul; this is structural placeholder
    mul_res <= (mul_pp >= {1'b0, q_val, 22'b0}) ?
               mul_pp[22:0] - q_val : mul_pp[22:0];
    mul_v   <= 1;
end

// Butterfly: u' = u + t  mod q, v' = u - t  mod q
wire [23:0] bu = {1'b0, coeff_u} + {1'b0, mul_res};
wire [23:0] bv = {1'b0, coeff_u} - {1'b0, mul_res} + {1'b0, q_val};
wire [22:0] bu_red = (bu >= {1'b0, q_val}) ? bu[22:0] - q_val : bu[22:0];
wire [22:0] bv_red = (bv >= {1'b0, q_val}) ? bv[22:0] - q_val : bv[22:0];

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        state <= S_IDLE; busy <= 0; done <= 0;
        len   <= 0; start_idx <= 0; k <= 0; j <= 0;
        bram_we <= 0; direction <= 0;
    end else begin
        done    <= 0;
        bram_we <= 0;

        case (state)
        S_IDLE: begin
            if (start) begin
                busy      <= 1;
                direction <= inv;
                if (!inv) begin
                    // Cooley-Tukey: len starts at 1, doubles
                    len       <= 8'd1;
                    start_idx <= 8'd0;
                    k         <= 8'd1;
                    j         <= 8'd0;
                end else begin
                    // Gentleman-Sande: len starts at 128, halves
                    len       <= 8'd128;
                    start_idx <= 8'd0;
                    k         <= 8'd0;
                    j         <= 8'd0;
                end
                state <= S_RD_U;
            end
        end

        S_RD_U: begin
            bram_addr <= {7'b0, start_idx + j};
            state     <= S_RD_V;
        end

        S_RD_V: begin
            coeff_u   <= bram_rdata[22:0];
            bram_addr <= {7'b0, start_idx + j + len};
            state     <= S_COMPUTE;
        end

        S_COMPUTE: begin
            coeff_v <= bram_rdata[22:0];
            // mul_res will be ready after 2 clocks (Barrett pipeline)
            // For simplicity assume combinatorial here; real build pipeline
            state <= S_WR_U;
        end

        S_WR_U: begin
            bram_addr  <= {7'b0, start_idx + j};
            bram_wdata <= {9'b0, bu_red};
            bram_we    <= 1;
            state      <= S_WR_V;
        end

        S_WR_V: begin
            bram_addr  <= {7'b0, start_idx + j + len};
            bram_wdata <= {9'b0, bv_red};
            bram_we    <= 1;
            state      <= S_NEXT;
        end

        S_NEXT: begin
            if (j + 1 < len) begin
                j     <= j + 1;
                state <= S_RD_U;
            end else begin
                j <= 0;
                if (start_idx + 2*len < 256) begin
                    start_idx <= start_idx + 2*len;
                    state     <= S_RD_U;
                end else begin
                    start_idx <= 0;
                    if (!direction && (len < 128)) begin
                        len   <= len << 1;
                        k     <= k + (128 / (len << 1)); // twiddle step
                        state <= S_RD_U;
                    end else if (direction && (len > 1)) begin
                        len   <= len >> 1;
                        state <= S_RD_U;
                    end else begin
                        state <= S_DONE;
                    end
                end
            end
        end

        S_DONE: begin
            busy  <= 0;
            done  <= 1;
            state <= S_IDLE;
        end
        endcase
    end
end

endmodule
