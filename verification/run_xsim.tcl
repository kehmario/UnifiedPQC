# ===========================================================================
#  run_xsim.tcl -- run the ACVP NTT byte-exact check in Vivado XSim, from Tcl.
#  Alternative to run_xsim.bat for people who prefer the Vivado Tcl flow.
#
#  Run from a command prompt in THIS folder (holding the .v/.vh/.mem files):
#       vivado -mode batch -source run_xsim.tcl
#  or, from an open Vivado Tcl Console:   cd <this folder>; source run_xsim.tcl
#
#  The .mem files (kem_batch.mem, dsa_batch.mem) must exist here first
#  (produce them with:  python reproduce.py).
# ===========================================================================
proc run_one {ms mem label} {
    puts "\n=== $label (MS=$ms) ==="
    # fresh snapshot name per run so plusargs re-apply cleanly
    if {[catch {exec xsim tb_batch_sim -R \
            -testplusarg "MS=$ms" -testplusarg "MEM=$mem"} out]} {
        puts $out
    } else {
        puts $out
    }
}

puts "=== Compiling (xvlog) ==="
exec xvlog --sv pqc_ntt_mont_synth.v tb_batch.v
puts "=== Elaborating (xelab) ==="
exec xelab tb_batch -s tb_batch_sim --timescale 1ns/1ps

run_one 0 kem_batch.mem "ML-KEM (q=3329)"
run_one 1 dsa_batch.mem "ML-DSA (q=8380417)"

puts "\n=== DONE ==="
puts "Expect 8/8 byte-exact on each; must match the Icarus Verilog result."
