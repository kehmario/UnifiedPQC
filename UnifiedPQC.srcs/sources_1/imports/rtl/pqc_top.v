// =============================================================================
// pqc_top.v
// Unified FIPS-203 (ML-KEM) + FIPS-204 (ML-DSA) top-level
// Target : Xilinx Arty A7-100T (xc7a100tcsg324-1)
// Clocks : 125 MHz system clock (clk), optional 62.5 MHz hash clock
// AXI4-Lite slave for host access; IRQ line for completion
// =============================================================================
`timescale 1ns/1ps

module pqc_top #(
    parameter C_S_AXI_ADDR_WIDTH = 8,
    parameter C_S_AXI_DATA_WIDTH = 32
)(
    // AXI4-Lite
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,
    // Interrupt
    output wire        irq
);

// ---------------------------------------------------------------------------
// Register map (byte-addressed, 32-bit words)
//   0x00  CTRL    [1:0] op_sel (0=idle,1=KEM,2=DSA), [3:2] cmd (0=KeyGen,1=Encaps/Sign,2=Decaps/Verify)
//                [4] start  (write 1 to start, self-clearing)
//   0x04  STATUS  [0] busy, [1] done, [2] error
//   0x08  IRQ_EN  [0] done_irq_en
//   0x0C  PARAM   [3:0] security_k (2=512,3=768,4=1024 / 2=44,3=65,4=87)
//   0x10..0x4F  DATA FIFO (write seed/msg, read ciphertext/sig)
// ---------------------------------------------------------------------------

    wire        clk  = s_axi_aclk;
    wire        rstn = s_axi_aresetn;

    // -----------------------------------------------------------------------
    // AXI4-Lite register file
    // -----------------------------------------------------------------------
    reg [31:0] reg_ctrl;
    wire [31:0] reg_status;
    reg [31:0] reg_irq_en;
    reg [31:0] reg_param;

    wire        start_pulse;
    wire [1:0]  op_sel   = reg_ctrl[1:0];   // 1=KEM, 2=DSA
    wire [1:0]  cmd      = reg_ctrl[3:2];   // 0=KG,1=Enc/Sign,2=Dec/Verify
    wire [3:0]  param_k  = reg_param[3:0];

    wire        busy, done, err;
    assign reg_status = {29'b0, err, done, busy};

    // Minimal AXI-Lite write/read (no burst, single beat)
    reg aw_latch; reg [7:0] aw_addr;
    reg  w_latch; reg [31:0] w_data;
    reg  b_valid;
    reg [31:0] ar_data; reg ar_valid;

    assign s_axi_awready = ~aw_latch;
    assign s_axi_wready  = ~w_latch;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_bvalid  = b_valid;
    assign s_axi_arready = ~ar_valid;
    assign s_axi_rdata   = ar_data;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rvalid  = ar_valid;

    reg start_r;
    assign start_pulse = start_r;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            aw_latch <= 0; aw_addr <= 0;
            w_latch  <= 0; w_data  <= 0;
            b_valid  <= 0; ar_valid <= 0;
            reg_ctrl <= 0; reg_irq_en <= 0; reg_param <= 32'd2;
            start_r  <= 0;
        end else begin
            start_r <= 0;
            // AW
            if (s_axi_awvalid && !aw_latch) begin
                aw_latch <= 1; aw_addr <= s_axi_awaddr;
            end
            // W
            if (s_axi_wvalid && !w_latch) begin
                w_latch <= 1; w_data <= s_axi_wdata;
            end
            // Write decode
            if (aw_latch && w_latch && !b_valid) begin
                case (aw_addr[5:2])
                    2'h0: begin
                        reg_ctrl <= w_data & 32'hFF;
                        start_r  <= w_data[4];
                    end
                    2'h2: reg_irq_en <= w_data;
                    2'h3: reg_param  <= w_data;
                    default: ;
                endcase
                aw_latch <= 0; w_latch <= 0; b_valid <= 1;
            end
            if (b_valid && s_axi_bready) b_valid <= 0;
            // AR
            if (s_axi_arvalid && !ar_valid) begin
                ar_valid <= 1;
                case (s_axi_araddr[5:2])
                    2'h0: ar_data <= reg_ctrl;
                    2'h1: ar_data <= reg_status;
                    2'h2: ar_data <= reg_irq_en;
                    2'h3: ar_data <= reg_param;
                    default: ar_data <= 32'hDEAD_BEEF;
                endcase
            end
            if (ar_valid && s_axi_rready) ar_valid <= 0;
        end
    end

    assign irq = done & reg_irq_en[0];

    // -----------------------------------------------------------------------
    // BRAM Scratchpad — 8 × 36 Kb = 288 Kb
    // Port A: polynomial / NTT datapath
    // Port B: hash / control
    // -----------------------------------------------------------------------
    wire [14:0] bram_porta_addr, bram_portb_addr;
    wire [31:0] bram_porta_wdata, bram_portb_wdata;
    wire [31:0] bram_porta_rdata, bram_portb_rdata;
    wire        bram_porta_we, bram_portb_we;

    pqc_bram_scratchpad u_bram (
        .clk        (clk),
        .porta_addr (bram_porta_addr),
        .porta_wdata(bram_porta_wdata),
        .porta_rdata(bram_porta_rdata),
        .porta_we   (bram_porta_we),
        .portb_addr (bram_portb_addr),
        .portb_wdata(bram_portb_wdata),
        .portb_rdata(bram_portb_rdata),
        .portb_we   (bram_portb_we)
    );

    // -----------------------------------------------------------------------
    // Shared arithmetic cluster
    // -----------------------------------------------------------------------
    // NTT arbiter bus (KEM or DSA gets the NTT each cycle)
    wire        ntt_req_kem, ntt_req_dsa;
    wire        ntt_gnt_kem, ntt_gnt_dsa;
    wire        ntt_start, ntt_inv;
    wire [1:0]  ntt_mod_sel;   // 0=q_kem, 1=q_dsa
    wire        ntt_busy, ntt_done;
    wire [14:0] ntt_bram_addr;
    wire [31:0] ntt_bram_wdata;
    wire [31:0] ntt_bram_rdata;
    wire        ntt_bram_we;

    // Barrett multiplier bus
    wire        mul_req_kem, mul_req_dsa;
    wire        mul_gnt_kem, mul_gnt_dsa;
    wire [22:0] mul_a, mul_b;
    wire [22:0] mul_result;
    wire        mul_valid_in, mul_valid_out;
    wire [1:0]  mul_mod_sel;

    // Hash/XOF bus
    wire        hash_req_kem, hash_req_dsa;
    wire        hash_gnt_kem, hash_gnt_dsa;
    wire [2:0]  hash_fn;        // 0=SHA3-256,1=SHA3-512,2=SHAKE128,3=SHAKE256
    wire        hash_init, hash_absorb, hash_squeeze;
    wire [63:0] hash_din;
    wire [3:0]  hash_din_valid;
    wire [63:0] hash_dout;
    wire        hash_dout_valid;
    wire        hash_busy;

    pqc_arbiter u_arb (
        .clk          (clk),
        .rstn         (rstn),
        .ntt_req_kem  (ntt_req_kem),
        .ntt_req_dsa  (ntt_req_dsa),
        .ntt_gnt_kem  (ntt_gnt_kem),
        .ntt_gnt_dsa  (ntt_gnt_dsa),
        .mul_req_kem  (mul_req_kem),
        .mul_req_dsa  (mul_req_dsa),
        .mul_gnt_kem  (mul_gnt_kem),
        .mul_gnt_dsa  (mul_gnt_dsa),
        .hash_req_kem (hash_req_kem),
        .hash_req_dsa (hash_req_dsa),
        .hash_gnt_kem (hash_gnt_kem),
        .hash_gnt_dsa (hash_gnt_dsa)
    );

    pqc_ntt u_ntt (
        .clk       (clk),
        .rstn      (rstn),
        .start     (ntt_start),
        .inv       (ntt_inv),
        .mod_sel   (ntt_mod_sel),
        .busy      (ntt_busy),
        .done      (ntt_done),
        .bram_addr (ntt_bram_addr),
        .bram_wdata(ntt_bram_wdata),
        .bram_rdata(ntt_bram_rdata),
        .bram_we   (ntt_bram_we)
    );

    assign bram_porta_addr  = ntt_bram_addr;
    assign bram_porta_wdata = ntt_bram_wdata;
    assign ntt_bram_rdata   = bram_porta_rdata;
    assign bram_porta_we    = ntt_bram_we;

    pqc_barrett_mul u_mul (
        .clk      (clk),
        .rstn     (rstn),
        .mod_sel  (mul_mod_sel),
        .a        (mul_a),
        .b        (mul_b),
        .valid_in (mul_valid_in),
        .result   (mul_result),
        .valid_out(mul_valid_out)
    );

    pqc_keccak_core u_keccak (
        .clk        (clk),
        .rstn       (rstn),
        .fn_sel     (hash_fn),
        .init       (hash_init),
        .absorb     (hash_absorb),
        .squeeze    (hash_squeeze),
        .din        (hash_din),
        .din_valid  (hash_din_valid),
        .dout       (hash_dout),
        .dout_valid (hash_dout_valid),
        .busy       (hash_busy)
    );

    // -----------------------------------------------------------------------
    // ML-KEM control plane
    // -----------------------------------------------------------------------
    wire kem_busy, kem_done, kem_err;

    pqc_kem_ctrl u_kem (
        .clk          (clk),
        .rstn         (rstn),
        .start        (start_pulse && (op_sel == 2'd1)),
        .cmd          (cmd),
        .k            (param_k[1:0]),
        .busy         (kem_busy),
        .done         (kem_done),
        .error        (kem_err),
        // NTT bus
        .ntt_req      (ntt_req_kem),
        .ntt_gnt      (ntt_gnt_kem),
        .ntt_start    (ntt_start),
        .ntt_inv      (ntt_inv),
        .ntt_mod_sel  (ntt_mod_sel),
        .ntt_busy     (ntt_busy),
        .ntt_done     (ntt_done),
        // Barrett bus
        .mul_req      (mul_req_kem),
        .mul_gnt      (mul_gnt_kem),
        .mul_mod_sel  (mul_mod_sel),
        .mul_a        (mul_a),
        .mul_b        (mul_b),
        .mul_valid_in (mul_valid_in),
        .mul_result   (mul_result),
        .mul_valid_out(mul_valid_out),
        // Hash bus
        .hash_req     (hash_req_kem),
        .hash_gnt     (hash_gnt_kem),
        .hash_fn      (hash_fn),
        .hash_init    (hash_init),
        .hash_absorb  (hash_absorb),
        .hash_squeeze (hash_squeeze),
        .hash_din     (hash_din),
        .hash_din_valid(hash_din_valid),
        .hash_dout    (hash_dout),
        .hash_dout_valid(hash_dout_valid),
        .hash_busy    (hash_busy),
        // BRAM portB
        .bram_addr    (bram_portb_addr),
        .bram_wdata   (bram_portb_wdata),
        .bram_rdata   (bram_portb_rdata),
        .bram_we      (bram_portb_we)
    );

    // -----------------------------------------------------------------------
    // ML-DSA control plane (muxed onto same buses via arbiter grants)
    // -----------------------------------------------------------------------
    wire dsa_busy, dsa_done, dsa_err;

    pqc_dsa_ctrl u_dsa (
        .clk          (clk),
        .rstn         (rstn),
        .start        (start_pulse && (op_sel == 2'd2)),
        .cmd          (cmd),
        .k            (param_k[1:0]),
        .busy         (dsa_busy),
        .done         (dsa_done),
        .error        (dsa_err),
        .ntt_req      (ntt_req_dsa),
        .ntt_gnt      (ntt_gnt_dsa),
        .mul_req      (mul_req_dsa),
        .mul_gnt      (mul_gnt_dsa),
        .hash_req     (hash_req_dsa),
        .hash_gnt     (hash_gnt_dsa)
        // (remaining buses tie-through the arbiter mux — see pqc_arbiter)
    );

    assign busy = kem_busy | dsa_busy;
    assign done = kem_done | dsa_done;
    assign err  = kem_err  | dsa_err;

endmodule
