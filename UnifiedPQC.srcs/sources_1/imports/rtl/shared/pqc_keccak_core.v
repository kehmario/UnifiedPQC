// =============================================================================
// pqc_keccak_core.v
// Keccak-f[1600] permutation, single round per clock (24 clocks per perm).
// Supports SHA3-256, SHA3-512, SHAKE-128, SHAKE-256 via fn_sel.
//
// fn_sel[2:0]:
//   3'b000 = SHA3-256   rate=1088 bits  capacity=512
//   3'b001 = SHA3-512   rate=576  bits  capacity=1024
//   3'b010 = SHAKE-128  rate=1344 bits  capacity=256
//   3'b011 = SHAKE-256  rate=1088 bits  capacity=512
//
// Data interface: 64-bit wide (one lane per transfer).
// Absorb: assert absorb, provide din[63:0] + din_valid[3:0] (byte enables).
// Squeeze: assert squeeze, read dout[63:0] when dout_valid.
// =============================================================================
`timescale 1ns/1ps

module pqc_keccak_core (
    input  wire        clk,
    input  wire        rstn,
    input  wire [2:0]  fn_sel,
    input  wire        init,       // reset state to zeros
    input  wire        absorb,     // feed din lanes
    input  wire        squeeze,    // request output lanes
    input  wire [63:0] din,
    input  wire [3:0]  din_valid,  // byte-enable per 16 bits (simplified)
    output reg  [63:0] dout,
    output reg         dout_valid,
    output wire        busy
);

// ---------------------------------------------------------------------------
// Keccak state: 5×5 lanes of 64 bits
// ---------------------------------------------------------------------------
reg [63:0] state [0:24];

// ---------------------------------------------------------------------------
// Round constants (FIPS 202 Table 2)
// ---------------------------------------------------------------------------
reg [63:0] RC [0:23];
initial begin
    RC[ 0] = 64'h0000000000000001; RC[ 1] = 64'h0000000000008082;
    RC[ 2] = 64'h800000000000808A; RC[ 3] = 64'h8000000080008000;
    RC[ 4] = 64'h000000000000808B; RC[ 5] = 64'h0000000080000001;
    RC[ 6] = 64'h8000000080008081; RC[ 7] = 64'h8000000000008009;
    RC[ 8] = 64'h000000000000008A; RC[ 9] = 64'h0000000000000088;
    RC[10] = 64'h0000000080008009; RC[11] = 64'h000000008000000A;
    RC[12] = 64'h000000008000808B; RC[13] = 64'h800000000000008B;
    RC[14] = 64'h8000000000008089; RC[15] = 64'h8000000000008003;
    RC[16] = 64'h8000000000008002; RC[17] = 64'h8000000000000080;
    RC[18] = 64'h000000000000800A; RC[19] = 64'h800000008000000A;
    RC[20] = 64'h8000000080008081; RC[21] = 64'h8000000000008080;
    RC[22] = 64'h0000000080000001; RC[23] = 64'h8000000080008008;
end

// Rho offsets (FIPS 202 Table 2, lane ordering x+5y)
function [5:0] rho_offset(input [4:0] lane_idx);
    reg [5:0] RHO [0:24];
    integer i;
    begin
        RHO[0]=0; RHO[1]=1; RHO[2]=62; RHO[3]=28; RHO[4]=27;
        RHO[5]=36; RHO[6]=44; RHO[7]=6; RHO[8]=55; RHO[9]=20;
        RHO[10]=3; RHO[11]=10; RHO[12]=43; RHO[13]=25; RHO[14]=39;
        RHO[15]=41; RHO[16]=45; RHO[17]=15; RHO[18]=21; RHO[19]=8;
        RHO[20]=18; RHO[21]=2; RHO[22]=61; RHO[23]=56; RHO[24]=14;
        rho_offset = RHO[lane_idx];
    end
endfunction

// Pi permutation: lane[x+5y] → lane[y + 5*((2x+3y) mod 5)]
// (Pre-computed mapping stored as a lookup in generate blocks)

// ---------------------------------------------------------------------------
// FSM
// ---------------------------------------------------------------------------
localparam S_IDLE    = 2'd0;
localparam S_ABSORB  = 2'd1;
localparam S_PERM    = 2'd2;
localparam S_SQUEEZE = 2'd3;

reg [1:0]  state_fsm;
reg [4:0]  round;      // 0..23
reg [4:0]  lane_ptr;   // absorb/squeeze lane pointer
reg [9:0]  rate_lanes; // rate in 64-bit lanes

// Rate lookup
wire [9:0] rate_bits = (fn_sel == 3'd1) ? 10'd576 : 
                        (fn_sel == 3'd2) ? 10'd1344 : 10'd1088;
always @(*) rate_lanes = rate_bits >> 6;  // / 64

assign busy = (state_fsm != S_IDLE);

// ---------------------------------------------------------------------------
// Keccak-f round function (unrolled theta, rho, pi, chi, iota)
// ---------------------------------------------------------------------------
reg [63:0] A [0:24];   // working copy
reg [63:0] B [0:24];
reg [63:0] C [0:4], D [0:4];

integer idx;

task do_theta;
    integer x, y;
    begin
        for (x = 0; x < 5; x = x+1)
            C[x] = A[x] ^ A[x+5] ^ A[x+10] ^ A[x+15] ^ A[x+20];
        for (x = 0; x < 5; x = x+1)
            D[x] = C[(x+4)%5] ^ {C[(x+1)%5][62:0], C[(x+1)%5][63]};
        for (idx = 0; idx < 25; idx = idx+1)
            A[idx] = A[idx] ^ D[idx % 5];
    end
endtask

task do_rho_pi;
    integer x, y, newx, newy;
    begin
        for (x = 0; x < 5; x = x+1)
            for (y = 0; y < 5; y = y+1) begin
                newx = y % 5;
                newy = (2*x + 3*y) % 5;
                B[newx + 5*newy] = {A[x+5*y] << rho_offset(x+5*y)} |
                                   {A[x+5*y] >> (64 - rho_offset(x+5*y))};
            end
    end
endtask

task do_chi;
    integer x, y;
    begin
        for (x = 0; x < 5; x = x+1)
            for (y = 0; y < 5; y = y+1)
                A[x+5*y] = B[x+5*y] ^ ((~B[(x+1)%5+5*y]) & B[(x+2)%5+5*y]);
    end
endtask

always @(posedge clk or negedge rstn) begin : fsm_block
    integer i;
    if (!rstn) begin
        state_fsm <= S_IDLE;
        round     <= 0;
        lane_ptr  <= 0;
        dout_valid <= 0;
        for (i = 0; i < 25; i = i+1) state[i] <= 64'b0;
    end else begin
        dout_valid <= 0;

        case (state_fsm)
        S_IDLE: begin
            if (init) begin
                for (i = 0; i < 25; i = i+1) state[i] <= 64'b0;
                lane_ptr <= 0;
            end
            if (absorb) state_fsm <= S_ABSORB;
            if (squeeze) begin lane_ptr <= 0; state_fsm <= S_SQUEEZE; end
        end

        S_ABSORB: begin
            // XOR din into current lane
            if (lane_ptr < rate_lanes) begin
                state[lane_ptr] <= state[lane_ptr] ^ din;
                lane_ptr        <= lane_ptr + 1;
            end
            if (!absorb || lane_ptr + 1 >= rate_lanes) begin
                // Padding (FIPS 202 pad10*1)
                state[lane_ptr] <= state[lane_ptr] ^ (fn_sel[1] ? 64'h1F : 64'h06);
                state[rate_lanes - 1] <= state[rate_lanes-1] ^ 64'h8000000000000000;
                // Start permutation
                for (i = 0; i < 25; i = i+1) A[i] <= state[i];
                round     <= 0;
                lane_ptr  <= 0;
                state_fsm <= S_PERM;
            end
        end

        S_PERM: begin
            // One Keccak-f round per clock (synthesises ~1200 LUTs)
            do_theta;
            do_rho_pi;
            do_chi;
            A[0] <= A[0] ^ RC[round];
            round <= round + 1;
            if (round == 5'd23) begin
                for (i = 0; i < 25; i = i+1) state[i] <= A[i];
                state_fsm <= S_SQUEEZE;
                lane_ptr  <= 0;
            end
        end

        S_SQUEEZE: begin
            dout       <= state[lane_ptr];
            dout_valid <= 1;
            lane_ptr   <= lane_ptr + 1;
            if (!squeeze || lane_ptr + 1 >= rate_lanes) begin
                state_fsm <= S_IDLE;
            end
        end
        endcase
    end
end

endmodule
