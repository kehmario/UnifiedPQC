#!/bin/bash
# Build + run ntt_regress_test against every mutant; each must FAIL.
# usage: ./run_mutants.sh [VERILATOR_ROOT]
set -u
VR=${1:-$HOME/vl_src}; UVM=$VR/test_regress/t/uvm
cd "$(dirname "$0")"; python3 make_mutants.py >/dev/null; mkdir -p logs
for m in ${MUTANTS:-rtl/*.v}; do
  n=$(basename $m .v)
  $VR/bin/verilator --binary --timing --assert -j 2 --vpi --top-module tb_top -Wno-fatal -Wno-lint -Wno-style \
     --CFLAGS -O1 --CFLAGS -Wno-everything --Mdir obj_$n \
     +incdir+$UVM +incdir+.. +incdir+../.. $UVM/uvm_pkg_all_v2017_1_0_dpi.svh $UVM/v2017_1_0/dpi/uvm_dpi.cc \
     $m ../ntt_if.sv ../ntt_pkg.sv ../tb_top.sv > logs/$n.build.log 2>&1 || { echo "$n BUILD-FAIL"; continue; }
  (cd .. && timeout 900 ./mutants/obj_$n/Vtb_top +UVM_TESTNAME=ntt_regress_test +UVM_NO_RELNOTES > mutants/logs/$n.log 2>&1)
  res=$(grep -ho 'UVM TEST [A-Z]*' logs/$n.log || echo 'NO RESULT/HANG')
  ids=$(grep -hoE '(UVM_ERROR|UVM_FATAL) [^ ]+ @ [0-9]+: [^ ]+ \[[A-Z/]+\]|Assertion failed[^:]*: [^ ]*|SVA: [a-z ]+' logs/$n.log \
        | grep -oE '\[[A-Z/]+\]|SVA: [a-z ]+' | sort | uniq -c | sort -rn | awk '{c=$1;$1="";printf "%s%sx%d", sep, $0, c; sep=","}')
  printf "%-22s %-18s %s\n" "$n" "$res" "$ids"
  rm -rf obj_$n
done
