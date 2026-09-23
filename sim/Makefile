# cocotb 2.x makefile for the systolic accelerator.
#
#   make                          # top-level regression, Icarus, N=4 KMAX=16
#   make SIM=verilator N=8        # same on Verilator, 8x8 array
#   make TB=array N=8             # array-only regression
#   make WAVES=1                  # dump waveforms (FST)
#
# Each (SIM, TB, N, KMAX) combination gets its own build directory, so a
# parameter change can never silently reuse a stale model.

SIM          ?= icarus
TB           ?= accel
N            ?= 4
KMAX         ?= 16
TOPLEVEL_LANG = verilog

# Relative on purpose: make cannot handle spaces in absolute paths.
RTL_DIR := ../rtl

ifeq ($(TB),array)
  COCOTB_TOPLEVEL     = systolic_array
  COCOTB_TEST_MODULES = test_array
  VERILOG_SOURCES     = $(RTL_DIR)/pe_mac.sv \
                        $(RTL_DIR)/systolic_array.sv
  PARAMS              = N
else ifeq ($(TB),accel)
  COCOTB_TOPLEVEL     = systolic_accel_top
  COCOTB_TEST_MODULES = test_accel
  VERILOG_SOURCES     = $(RTL_DIR)/reset_sync.sv \
                        $(RTL_DIR)/pe_mac.sv \
                        $(RTL_DIR)/systolic_array.sv \
                        $(RTL_DIR)/axi_lite_slave.sv \
                        $(RTL_DIR)/accel_ctrl.sv \
                        $(RTL_DIR)/systolic_accel_top.sv
  PARAMS              = N KMAX
else
  $(error TB must be "accel" or "array")
endif

SIM_BUILD := sim_build/$(SIM)_$(TB)_N$(N)_K$(KMAX)

# The tests read N / KMAX from the environment.
export N KMAX

ifeq ($(SIM),icarus)
  COMPILE_ARGS += $(foreach p,$(PARAMS),-P$(COCOTB_TOPLEVEL).$(p)=$($(p)))
else ifeq ($(SIM),verilator)
  # Parameters go in COMPILE_ARGS: EXTRA_ARGS is also passed to the model binary.
  COMPILE_ARGS += $(foreach p,$(PARAMS),-G$(p)=$($(p)))
  ifeq ($(WAVES),1)
    COMPILE_ARGS += --trace-fst
  endif
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: clean_all
clean_all:
	rm -rf sim_build results.xml *.fst *.vcd __pycache__
