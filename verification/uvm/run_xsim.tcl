# =============================================================================
# run_xsim.tcl -- UVM regression for pqc_ntt_mont in Vivado XSim (UVM 1.2,
# bundled with Vivado 2019.2+).  Run from THIS folder (verification/uvm):
#
#     vivado -mode batch -source run_xsim.tcl                       ;# all tests
#     vivado -mode batch -source run_xsim.tcl -tclargs ntt_kat_test ;# one test
#
# or from an open Vivado Tcl Console:  cd <this folder>; source run_xsim.tcl
# Logs land in ./xsim_logs/<test>.log
# =============================================================================
set tests {ntt_smoke_test ntt_kat_test ntt_corner_test ntt_roundtrip_test
           ntt_random_test ntt_robust_test ntt_regress_test}
if {[info exists argv] && [llength $argv] > 0} { set tests $argv }

file mkdir xsim_logs

puts "=== xvlog (UVM 1.2) ==="
exec xvlog --sv -L uvm --include .. --include . \
    ../pqc_ntt_mont_synth.v ntt_if.sv ntt_pkg.sv tb_top.sv >@stdout

puts "=== xelab ==="
exec xelab tb_top -L uvm -timescale 1ns/1ps -s ntt_uvm_sim -debug off >@stdout

set summary {}
foreach t $tests {
    puts "\n=== $t ==="
    catch {exec xsim ntt_uvm_sim -R -testplusarg UVM_TESTNAME=$t \
               -testplusarg UVM_NO_RELNOTES -log xsim_logs/$t.log} out
    set res "NO RESULT"
    if {[regexp {UVM TEST (PASSED|FAILED)} $out -> r]} { set res $r }
    foreach line [split $out "\n"] {
        if {[regexp {RESULT|SB/SUMMARY|^  |COV} $line]} { puts $line }
    }
    lappend summary [format "%-22s %s" $t $res]
}
puts "\n=== SUMMARY ==="
foreach s $summary { puts $s }
