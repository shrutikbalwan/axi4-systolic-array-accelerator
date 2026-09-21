# Makefile for Cocotb simulation of axi4-systolic-array-accelerator
# Supports both Icarus Verilog (iverilog) and Verilator backends

# User can set SIM to "iverilog" or "verilator"
SIM ?= verilator

# Design under test top module name
TOPLEVEL := systolic_accelerator_top

# Python test file(s)
VERILOG_SOURCES := $(PWD)/rtl/axi_lite_slave.sv \
                   $(PWD)/rtl/systolic_array_4x4.sv \
                   $(PWD)/rtl/pe_mac.sv

# Cocotb include paths and libraries
COCOTB_INC := $(shell python3 -c "import cocotb; print(cocotb.__path__[0])")

# Verilator-specific flags
VERILATOR_FLAGS := --cc -O3 -Mdir sim_build

# Icarus Verilog specific flags
IVERILOG_FLAGS := -Wall

# Default target
.PHONY: all clean run

all: sim

# Verilator backend
ifeq ($(SIM), verilator)
    build_dir = sim_build
    
    # Compile Verilog sources with Verilator
    $(build_dir)/V$(TOPLEVEL): $(VERILOG_SOURCES) $(wildcard sim/*.py)
        mkdir -p $(build_dir)
        verilator $(VERILATOR_FLAGS) \
            --top-module $(TOPLEVEL) \
            -s $(TOPLEVEL) \
            $(VERILOG_SOURCES) \
            --Mdir $(build_dir) \
            --exe test_systolic.py
    
    # Run simulation
    run: $(build_dir)/V$(TOPLEVEL)
        cd $(build_dir) && make -j4 V$(TOPLEVEL)_tb
        cd $(build_dir) && ./V$(TOPLEVEL)_tb
    
    clean:
        rm -rf sim_build

# Icarus Verilog backend
else ifeq ($(SIM), iverilog)
    build_dir = sim_build_iverilog
    
    # Compile Verilog sources with Icarus
    $(build_dir)/$(TOPLEVEL): $(VERILOG_SOURCES)
        mkdir -p $(build_dir)
        iverilog $(IVERILOG_FLAGS) \
            -o $(build_dir)/$(TOPLEVEL) \
            $(VERILOG_SOURCES)
    
    # Run simulation with VVP
    run: $(build_dir)/$(TOPLEVEL)
        vvp $(build_dir)/$(TOPLEVEL)
    
    clean:
        rm -rf sim_build_iverilog

# Default: use verilator
run: iverilog
clean:
    rm -rf sim_build sim_build_iverilog