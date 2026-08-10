// =============================================================================
// pqc_arbiter.v
// Round-robin arbiter — grants NTT, Barrett multiplier, and Keccak hash engine
// to ML-KEM or ML-DSA control plane.
//
// Policy: when both cores request the same resource simultaneously,
//   - Alternate on each grant (round-robin)
//   - Priority-boost if one core has been waiting > TIMEOUT cycles
// =============================================================================
`timescale 1ns/1ps

module pqc_arbiter #(
    parameter TIMEOUT = 256   // cycles before priority boost
)(
    input  wire clk,
    input  wire rstn,

    // NTT requests / grants
    input  wire ntt_req_kem,
    input  wire ntt_req_dsa,
    output reg  ntt_gnt_kem,
    output reg  ntt_gnt_dsa,

    // Barrett mul requests / grants
    input  wire mul_req_kem,
    input  wire mul_req_dsa,
    output reg  mul_gnt_kem,
    output reg  mul_gnt_dsa,

    // Hash requests / grants
    input  wire hash_req_kem,
    input  wire hash_req_dsa,
    output reg  hash_gnt_kem,
    output reg  hash_gnt_dsa
);

// ---------------------------------------------------------------------------
// Generic arbiter task (inline for each resource)
// last_winner: 0=KEM had it last, 1=DSA had it last
// wait_cnt_x: how many cycles X has been waiting
// ---------------------------------------------------------------------------
reg        ntt_last, mul_last, hash_last;
reg [8:0]  ntt_wait_kem, ntt_wait_dsa;
reg [8:0]  mul_wait_kem, mul_wait_dsa;
reg [8:0]  hash_wait_kem, hash_wait_dsa;

// Current grant holders (to avoid revoking mid-operation)
// Grant is held until request is de-asserted
reg ntt_held_kem, ntt_held_dsa;
reg mul_held_kem, mul_held_dsa;
reg hash_held_kem, hash_held_dsa;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ntt_gnt_kem  <= 0; ntt_gnt_dsa  <= 0;
        mul_gnt_kem  <= 0; mul_gnt_dsa  <= 0;
        hash_gnt_kem <= 0; hash_gnt_dsa <= 0;
        ntt_last     <= 0; mul_last     <= 0; hash_last <= 0;
        ntt_wait_kem <= 0; ntt_wait_dsa <= 0;
        mul_wait_kem <= 0; mul_wait_dsa <= 0;
        hash_wait_kem<= 0; hash_wait_dsa<= 0;
        ntt_held_kem <= 0; ntt_held_dsa <= 0;
        mul_held_kem <= 0; mul_held_dsa <= 0;
        hash_held_kem<= 0; hash_held_dsa<= 0;
    end else begin

        // ── NTT ─────────────────────────────────────────────────────────
        // Release if request dropped
        if (!ntt_req_kem) begin ntt_gnt_kem <= 0; ntt_held_kem <= 0; end
        if (!ntt_req_dsa) begin ntt_gnt_dsa <= 0; ntt_held_dsa <= 0; end

        if (ntt_req_kem && !ntt_held_kem) ntt_wait_kem <= ntt_wait_kem + 1;
        else ntt_wait_kem <= 0;
        if (ntt_req_dsa && !ntt_held_dsa) ntt_wait_dsa <= ntt_wait_dsa + 1;
        else ntt_wait_dsa <= 0;

        if (ntt_req_kem && !ntt_held_kem && !ntt_held_dsa) begin
            if (!ntt_req_dsa || ntt_last == 1 || ntt_wait_kem >= TIMEOUT) begin
                ntt_gnt_kem  <= 1;
                ntt_gnt_dsa  <= 0;
                ntt_held_kem <= 1;
                ntt_last     <= 0;
            end
        end
        if (ntt_req_dsa && !ntt_held_dsa && !ntt_held_kem) begin
            if (!ntt_req_kem || ntt_last == 0 || ntt_wait_dsa >= TIMEOUT) begin
                ntt_gnt_dsa  <= 1;
                ntt_gnt_kem  <= 0;
                ntt_held_dsa <= 1;
                ntt_last     <= 1;
            end
        end

        // ── Barrett mul ─────────────────────────────────────────────────
        if (!mul_req_kem) begin mul_gnt_kem <= 0; mul_held_kem <= 0; end
        if (!mul_req_dsa) begin mul_gnt_dsa <= 0; mul_held_dsa <= 0; end

        if (mul_req_kem && !mul_held_kem) mul_wait_kem <= mul_wait_kem + 1;
        else mul_wait_kem <= 0;
        if (mul_req_dsa && !mul_held_dsa) mul_wait_dsa <= mul_wait_dsa + 1;
        else mul_wait_dsa <= 0;

        if (mul_req_kem && !mul_held_kem && !mul_held_dsa) begin
            if (!mul_req_dsa || mul_last == 1 || mul_wait_kem >= TIMEOUT) begin
                mul_gnt_kem  <= 1; mul_gnt_dsa  <= 0;
                mul_held_kem <= 1; mul_last      <= 0;
            end
        end
        if (mul_req_dsa && !mul_held_dsa && !mul_held_kem) begin
            if (!mul_req_kem || mul_last == 0 || mul_wait_dsa >= TIMEOUT) begin
                mul_gnt_dsa  <= 1; mul_gnt_kem  <= 0;
                mul_held_dsa <= 1; mul_last      <= 1;
            end
        end

        // ── Hash / Keccak ────────────────────────────────────────────────
        if (!hash_req_kem) begin hash_gnt_kem <= 0; hash_held_kem <= 0; end
        if (!hash_req_dsa) begin hash_gnt_dsa <= 0; hash_held_dsa <= 0; end

        if (hash_req_kem && !hash_held_kem) hash_wait_kem <= hash_wait_kem + 1;
        else hash_wait_kem <= 0;
        if (hash_req_dsa && !hash_held_dsa) hash_wait_dsa <= hash_wait_dsa + 1;
        else hash_wait_dsa <= 0;

        if (hash_req_kem && !hash_held_kem && !hash_held_dsa) begin
            if (!hash_req_dsa || hash_last == 1 || hash_wait_kem >= TIMEOUT) begin
                hash_gnt_kem  <= 1; hash_gnt_dsa  <= 0;
                hash_held_kem <= 1; hash_last      <= 0;
            end
        end
        if (hash_req_dsa && !hash_held_dsa && !hash_held_kem) begin
            if (!hash_req_kem || hash_last == 0 || hash_wait_dsa >= TIMEOUT) begin
                hash_gnt_dsa  <= 1; hash_gnt_kem  <= 0;
                hash_held_dsa <= 1; hash_last      <= 1;
            end
        end

    end
end

endmodule
