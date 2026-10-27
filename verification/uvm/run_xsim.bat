@echo off
REM ===========================================================================
REM run_xsim.bat -- UVM regression for pqc_ntt_mont in Vivado XSim (Windows).
REM Run from a "Vivado <ver> Tcl Shell" / cmd with Vivado's bin on PATH,
REM inside verification\uvm.     run_xsim.bat [test_name]
REM ===========================================================================
setlocal
set TEST=%1
if "%TEST%"=="" set TEST=ntt_regress_test

call xvlog --sv -L uvm --include .. --include . ..\pqc_ntt_mont_synth.v ntt_if.sv ntt_pkg.sv tb_top.sv || goto :err
call xelab tb_top -L uvm -timescale 1ns/1ps -s ntt_uvm_sim -debug off || goto :err
call xsim ntt_uvm_sim -R -testplusarg UVM_TESTNAME=%TEST% -testplusarg UVM_NO_RELNOTES -log %TEST%.log
findstr /C:"UVM TEST" %TEST%.log
goto :eof
:err
echo Build failed.
exit /b 1
