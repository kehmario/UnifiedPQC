# =============================================================================
# Verilator flow (Verilator >= 5.04x built from source; uses the UVM 2017-1.0
# flattened package that ships in Verilator's test_regress tree).
#
#   make VERILATOR_ROOT=/path/to/verilator-src            # build once
#   make run TEST=ntt_regress_test                         # run one test
#   make regress                                           # run all tests
#
# Vivado XSim users: use run_xsim.tcl / run_xsim.bat instead (no Verilator needed).
# =============================================================================
VERILATOR_ROOT ?= $(HOME)/vl_src
VERILATOR      ?= $(VERILATOR_ROOT)/bin/verilator
UVM_DIR        ?= $(VERILATOR_ROOT)/test_regress/t/uvm
UVM_PKG        ?= $(UVM_DIR)/uvm_pkg_all_v2017_1_0_dpi.svh
UVM_DPI        ?= $(UVM_DIR)/v2017_1_0/dpi/uvm_dpi.cc
JOBS           ?= 2
TEST           ?= ntt_regress_test
SEED           ?= 1
PLUSARGS       ?=

DUT  = ../pqc_ntt_mont_synth.v
SRCS = ntt_if.sv ntt_pkg.sv tb_top.sv
BIN  = obj_dir/Vtb_top

TESTS = ntt_smoke_test ntt_kat_test ntt_corner_test ntt_roundtrip_test \
        ntt_random_test ntt_robust_test ntt_regress_test

VFLAGS = --binary --timing --assert -j $(JOBS) --vpi \
         --top-module tb_top -Wno-fatal -Wno-lint -Wno-style \
         --CFLAGS -O1 --CFLAGS -Wno-everything \
         +incdir+$(UVM_DIR) +incdir+. +incdir+.. \
         $(UVM_PKG) $(UVM_DPI)

all: $(BIN)

$(BIN): $(SRCS) $(DUT) $(wildcard *.svh)
	$(VERILATOR) $(VFLAGS) $(DUT) $(SRCS) > build.log 2>&1 || (tail -40 build.log; false)

run: $(BIN)
	mkdir -p logs
	./$(BIN) +UVM_TESTNAME=$(TEST) +verilator+seed+$(SEED) +UVM_NO_RELNOTES $(PLUSARGS) \
	    | tee logs/$(TEST).log | grep -E "RESULT|SB/SUMMARY|^  |COV|UVM_(ERROR|FATAL) [^:]|Assertion"

regress: $(BIN)
	@mkdir -p logs; for t in $(TESTS); do \
	  ./$(BIN) +UVM_TESTNAME=$$t +verilator+seed+$(SEED) +UVM_NO_RELNOTES $(PLUSARGS) > logs/$$t.log 2>&1; \
	  printf "%-22s %s\n" $$t "$$(grep -ho 'UVM TEST [A-Z]*' logs/$$t.log || echo 'NO RESULT (crash?)')"; \
	done

clean:
	rm -rf obj_dir logs build.log

.PHONY: all run regress clean
