`timescale 1ns/1ps
module tb_batch;
reg clk=0,rstn=0; always #5 clk=~clk;
reg ntt_start, ntt_inv; reg [1:0] ntt_mod_sel;
wire ntt_busy, ntt_done;
wire [14:0] a; wire [31:0] wd; reg [31:0] rd; wire we;
pqc_ntt_mont dut(.clk(clk),.rstn(rstn),.start(ntt_start),.inv(ntt_inv),
  .mod_sel(ntt_mod_sel),.busy(ntt_busy),.done(ntt_done),
  .bram_addr(a),.bram_wdata(wd),.bram_rdata(rd),.bram_we(we));
reg [31:0] bram[0:255]; integer i,p,errs,tot,fd,r,NP,MS;
reg [22:0] vin[0:255], vexp[0:255];
reg [8*160:1] memf;
always @(posedge clk) begin if(we) bram[a[7:0]]<=wd; rd<=bram[a[7:0]]; end
initial begin
  if(!$value$plusargs("MS=%d",MS)) MS=0;
  void'($value$plusargs("MEM=%s",memf));
  fd=$fopen(memf,"r"); r=$fscanf(fd,"%d\n",NP);
  rstn=0; repeat(3)@(negedge clk); rstn=1;
  ntt_mod_sel=MS[1:0];
  tot=0;
  for(p=0;p<NP;p=p+1) begin
    for(i=0;i<256;i=i+1) r=$fscanf(fd,"%h\n",vin[i]);
    for(i=0;i<256;i=i+1) r=$fscanf(fd,"%h\n",vexp[i]);
    for(i=0;i<256;i=i+1) bram[i]={9'b0,vin[i]};
    @(negedge clk); ntt_inv=0; ntt_start=1; @(negedge clk); ntt_start=0;
    wait(ntt_done); @(negedge clk);
    errs=0; for(i=0;i<256;i=i+1) if(bram[i][22:0]!==vexp[i]) errs=errs+1;
    if(errs==0) tot=tot+1; else $display("  KAT %0d: %0d mismatches",p,errs);
    repeat(2)@(negedge clk);
  end
  $display("ACVP NTT batch (%s): %0d/%0d KATs byte-exact", MS?"ML-DSA":"ML-KEM", tot, NP);
  $finish;
end
initial begin #200_000_000; $display("TIMEOUT"); $finish; end
endmodule
