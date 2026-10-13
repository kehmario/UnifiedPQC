@echo off
REM ===========================================================================
REM  run_xsim.bat -- run the ACVP NTT byte-exact check in Vivado's XSim.
REM  No Icarus Verilog needed; XSim ships inside Vivado.
REM
REM  HOW TO RUN:
REM    1. Produce the KAT files first:  python reproduce.py
REM       (that writes kem_batch.mem and dsa_batch.mem; or use the ones shipped
REM        in this folder). The .mem files must sit in THIS folder.
REM    2. Open the "Vivado <version> Tcl Shell" (Start menu) OR a normal
REM       command prompt where Vivado's bin is on PATH, so xvlog/xelab/xsim
REM       resolve. Quick test:   where xvlog
REM    3. cd into this folder (the one holding pqc_ntt_mont_synth.v,
REM       twiddle_init.vh, tb_batch.v and the .mem files), then:
REM          run_xsim.bat
REM
REM  Expected result (same as Icarus):
REM     ACVP NTT batch (ML-KEM): 8/8 KATs byte-exact
REM     ACVP NTT batch (ML-DSA): 8/8 KATs byte-exact
REM ===========================================================================
setlocal

where xvlog >nul 2>nul
if errorlevel 1 (
  echo ERROR: xvlog not found on PATH.
  echo Open the "Vivado ^<version^> Tcl Shell" or add Vivado\bin to PATH, then retry.
  exit /b 1
)

echo === Compiling (xvlog, SystemVerilog) ===
call xvlog --sv pqc_ntt_mont_synth.v tb_batch.v
if errorlevel 1 goto :err

echo === Elaborating (xelab) ===
call xelab tb_batch -s tb_batch_sim --timescale 1ns/1ps
if errorlevel 1 goto :err

echo.
echo === ML-KEM (q=3329, MS=0) ===
call xsim tb_batch_sim -R -testplusarg "MS=0" -testplusarg "MEM=kem_batch.mem"

echo.
echo === ML-DSA (q=8380417, MS=1) ===
call xsim tb_batch_sim -R -testplusarg "MS=1" -testplusarg "MEM=dsa_batch.mem"

echo.
echo === DONE ===
echo Look for "8/8 KATs byte-exact" on each run above. These must match the
echo Icarus Verilog result (same RTL, same NIST-derived vectors). A difference
echo between the two simulators would itself be a finding worth investigating.
goto :eof

:err
echo.
echo BUILD FAILED -- see the xvlog/xelab messages above.
exit /b 1
