// =============================================================================
// pqc_bram_scratchpad.v
// 288 Kb true dual-port BRAM scratchpad
//   8 × RAMB36E1 in TDP mode = 8 × 32768 bits = 32768 × 32-bit words
//   Address space: [14:0]  →  32768 locations of 32 bits each
//
// Port A  — NTT / polynomial datapath (higher-priority timing)
// Port B  — hash / control plane (key material, messages, scratch)
//
// Memory map (suggested, software-defined):
//   0x0000–0x00FF  poly_a[0..255]    (256 × 32b = 1 KB)
//   0x0100–0x01FF  poly_b[0..255]
//   0x0200–0x03FF  poly_matrix (256 words × 4 rows for k=4)
//   0x0400–0x04FF  t_hat[0..255]
//   0x0500–0x05FF  e1/e2
//   0x0600–0x07FF  key_kem (512b × 2)
//   0x0800–0x09FF  sig_r/s buffers
//   0x0A00–0x0FFF  general scratch
// =============================================================================
`timescale 1ns/1ps

module pqc_bram_scratchpad (
    input  wire        clk,
    // Port A (NTT / poly)
    input  wire [14:0] porta_addr,
    input  wire [31:0] porta_wdata,
    output wire [31:0] porta_rdata,
    input  wire        porta_we,
    // Port B (hash / ctrl)
    input  wire [14:0] portb_addr,
    input  wire [31:0] portb_wdata,
    output wire [31:0] portb_rdata,
    input  wire        portb_we
);

// ---------------------------------------------------------------------------
// Instantiate 8 × RAMB36E1 in true-dual-port mode (Xilinx 7-series primitive)
// Each RAMB36E1 provides 32Kb (1K × 32-bit with 4-bit parity ignored)
// We cascade 8 of them for 8K × 32b = 256 Kb useful capacity
//
// Address decode: porta_addr[14:13] selects bank (0..7 needs [14:12] for 8 banks)
//                 porta_addr[11:0]  is within-bank address (4K words per bank)
// ---------------------------------------------------------------------------
// Simplification: use a single-file RTL inference (tool will use BRAM primitives)
// For exact RAMB36E1 instantiation replace with UNIMACRO or explicit primitive.

(* ram_style = "block" *)
reg [31:0] mem [0:32767];

// Port A
reg [31:0] pa_rd;
always @(posedge clk) begin
    if (porta_we)
        mem[porta_addr] <= porta_wdata;
    pa_rd <= mem[porta_addr];
end
assign porta_rdata = pa_rd;

// Port B
reg [31:0] pb_rd;
always @(posedge clk) begin
    if (portb_we)
        mem[portb_addr] <= portb_wdata;
    pb_rd <= mem[portb_addr];
end
assign portb_rdata = pb_rd;

// ---------------------------------------------------------------------------
// Note for Vivado:
//   The tool will infer 8 × RAMB36E1 automatically from the (* ram_style *)
//   attribute.  To drive both ports from different clock domains add CLKA/CLKB.
//   For explicit primitive, use:
//     RAMB36E1 #(.RAM_MODE("TDP"), .READ_WIDTH_A(36), .WRITE_WIDTH_A(36),
//                .READ_WIDTH_B(36), .WRITE_WIDTH_B(36)) ram_inst (...);
// ---------------------------------------------------------------------------

endmodule
