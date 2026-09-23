# cocotb 2.x makefile for the systolic accelerator.
#
#   make                          # top-level regression, Icarus, N=4 KMAX=16
#   make SIM=verilator N=8        # same on Verilator, 8x8 array
#   make TB=array N=8             # array-only regression
#   make TB=tile N=8              # streamed tile adapter regression
#   make TB=scheduler             # runtime tile schedule regression
#   make TB=chain N=8             # multi-K compute-chain regression
#   make TB=read_dma              # AXI4 read DMA regression
#   make TB=write_dma             # AXI4 write DMA regression
#   make TB=tiled N=4             # full runtime tiled GEMM regression
#   make TB=ml_core N=4           # tiled GEMM plus INT8 ML post-processing
#   make TB=stream_gemm N=4       # contiguous matrices through tile buffering
#   make TB=descriptor            # DMA/ML descriptor register regression
#   make TB=ml_packer             # INT32 to packed INT8 post-processing
#   make WAVES=1                  # dump waveforms (FST)
#
# Each (SIM, TB, N, KMAX) combination gets its own build directory, so a
# parameter change can never silently reuse a stale model.

SIM          ?= icarus
TB           ?= accel
N            ?= 4
ARRAY_N      ?= $(N)
KMAX         ?= 16
MAX_BURST    ?= 4
TOPLEVEL_LANG = verilog

# Relative on purpose: make cannot handle spaces in absolute paths.
RTL_DIR := ../rtl

ifeq ($(TB),array)
  COCOTB_TOPLEVEL     = systolic_array
  COCOTB_TEST_MODULES = test_array
  VERILOG_SOURCES     = $(RTL_DIR)/pe_mac.sv \
                        $(RTL_DIR)/systolic_array.sv
  PARAMS              = N
else ifeq ($(TB),tile)
  COCOTB_TOPLEVEL     = systolic_tile_adapter
  COCOTB_TEST_MODULES = test_tile_adapter
  VERILOG_SOURCES     = $(RTL_DIR)/pe_mac.sv \
                        $(RTL_DIR)/systolic_array.sv \
                        $(RTL_DIR)/systolic_tile_adapter.sv
  PARAMS              = N KMAX
else ifeq ($(TB),scheduler)
  COCOTB_TOPLEVEL     = tile_scheduler
  COCOTB_TEST_MODULES = test_tile_scheduler
  VERILOG_SOURCES     = $(RTL_DIR)/tile_scheduler.sv
  PARAMS              =
else ifeq ($(TB),chain)
  COCOTB_TOPLEVEL     = tiled_compute_chain
  COCOTB_TEST_MODULES = test_compute_chain
  VERILOG_SOURCES     = $(RTL_DIR)/pe_mac.sv \
                        $(RTL_DIR)/systolic_array.sv \
                        $(RTL_DIR)/systolic_tile_adapter.sv \
                        $(RTL_DIR)/tile_accumulator.sv \
                        $(RTL_DIR)/tiled_compute_chain.sv
  PARAMS              = N KMAX
else ifeq ($(TB),read_dma)
  COCOTB_TOPLEVEL     = axi4_read_dma
  COCOTB_TEST_MODULES = test_read_dma
  VERILOG_SOURCES     = $(RTL_DIR)/axi4_read_dma.sv
  PARAMS              = MAX_BURST
else ifeq ($(TB),write_dma)
  COCOTB_TOPLEVEL     = axi4_write_dma
  COCOTB_TEST_MODULES = test_write_dma
  VERILOG_SOURCES     = $(RTL_DIR)/axi4_write_dma.sv
  PARAMS              = MAX_BURST
else ifeq ($(TB),tiled)
  COCOTB_TOPLEVEL     = tiled_gemm_controller
  COCOTB_TEST_MODULES = test_tiled_controller
  VERILOG_SOURCES     = $(RTL_DIR)/pe_mac.sv \
                        $(RTL_DIR)/systolic_array.sv \
                        $(RTL_DIR)/systolic_tile_adapter.sv \
                        $(RTL_DIR)/tile_accumulator.sv \
                        $(RTL_DIR)/tiled_compute_chain.sv \
                        $(RTL_DIR)/tile_scheduler.sv \
                        $(RTL_DIR)/tiled_gemm_controller.sv
  PARAMS              = ARRAY_N KMAX
else ifeq ($(TB),ml_core)
  COCOTB_TOPLEVEL     = tiled_ml_inference_core
  COCOTB_TEST_MODULES = test_ml_core
  VERILOG_SOURCES     = $(RTL_DIR)/pe_mac.sv \
                        $(RTL_DIR)/systolic_array.sv \
                        $(RTL_DIR)/systolic_tile_adapter.sv \
                        $(RTL_DIR)/tile_accumulator.sv \
                        $(RTL_DIR)/tiled_compute_chain.sv \
                        $(RTL_DIR)/tile_scheduler.sv \
                        $(RTL_DIR)/tiled_gemm_controller.sv \
                        $(RTL_DIR)/ml_postprocess.sv \
                        $(RTL_DIR)/tiled_ml_inference_core.sv
  PARAMS              = ARRAY_N KMAX
else ifeq ($(TB),stream_gemm)
  COCOTB_TOPLEVEL     = tiled_stream_gemm_top
  COCOTB_TEST_MODULES = test_stream_gemm
  VERILOG_SOURCES     = $(RTL_DIR)/pe_mac.sv \
                        $(RTL_DIR)/systolic_array.sv \
                        $(RTL_DIR)/systolic_tile_adapter.sv \
                        $(RTL_DIR)/tile_accumulator.sv \
                        $(RTL_DIR)/tiled_compute_chain.sv \
                        $(RTL_DIR)/tile_scheduler.sv \
                        $(RTL_DIR)/tiled_gemm_controller.sv \
                        $(RTL_DIR)/tiled_matrix_tile_buffer.sv \
                        $(RTL_DIR)/tiled_stream_gemm_top.sv
  PARAMS              = ARRAY_N
else ifeq ($(TB),descriptor)
  COCOTB_TOPLEVEL     = dma_descriptor_ctrl
  COCOTB_TEST_MODULES = test_dma_descriptor
  VERILOG_SOURCES     = $(RTL_DIR)/dma_descriptor_ctrl.sv
  PARAMS              =
else ifeq ($(TB),ml_packer)
  COCOTB_TOPLEVEL     = ml_int8_packer
  COCOTB_TEST_MODULES = test_ml_int8_packer
  VERILOG_SOURCES     = $(RTL_DIR)/ml_int8_packer.sv
  PARAMS              =
else ifeq ($(TB),accel)
  COCOTB_TOPLEVEL     = systolic_accel_top
  COCOTB_TEST_MODULES = test_accel
  VERILOG_SOURCES     = $(RTL_DIR)/reset_sync.sv \
                        $(RTL_DIR)/pe_mac.sv \
                        $(RTL_DIR)/systolic_array.sv \
                        $(RTL_DIR)/ml_postprocess.sv \
                        $(RTL_DIR)/ml_int8_packer.sv \
                        $(RTL_DIR)/tile_scheduler.sv \
                        $(RTL_DIR)/dual_bank_buffer.sv \
                        $(RTL_DIR)/tile_accumulator.sv \
                        $(RTL_DIR)/axi4_read_dma.sv \
                        $(RTL_DIR)/axi4_write_dma.sv \
                        $(RTL_DIR)/dma_descriptor_ctrl.sv \
                        $(RTL_DIR)/systolic_tile_adapter.sv \
                        $(RTL_DIR)/tiled_compute_chain.sv \
                        $(RTL_DIR)/tiled_gemm_controller.sv \
                        $(RTL_DIR)/tiled_dma_shell.sv \
                        $(RTL_DIR)/tiled_axi4_gemm_top.sv \
                        $(RTL_DIR)/axi_lite_slave.sv \
                        $(RTL_DIR)/accel_ctrl.sv \
                        $(RTL_DIR)/systolic_accel_top.sv
  PARAMS              = N KMAX
else
  $(error TB must be "accel", "array", "tile", "scheduler", "chain", "read_dma", "write_dma", "tiled", "ml_core", "stream_gemm", "descriptor" or "ml_packer")
endif

SIM_BUILD := sim_build/$(SIM)_$(TB)_N$(N)_K$(KMAX)

# The tests read N / ARRAY_N / KMAX from the environment.
export N ARRAY_N KMAX

ifeq ($(SIM),icarus)
  COMPILE_ARGS += $(foreach p,$(PARAMS),-P$(COCOTB_TOPLEVEL).$(p)=$($(p)))
else ifeq ($(SIM),verilator)
  # Parameters go in COMPILE_ARGS: EXTRA_ARGS is also passed to the model binary.
  COMPILE_ARGS += $(foreach p,$(PARAMS),-G$(p)=$($(p)))
  # Runtime tile descriptors intentionally narrow into local counters; keep
  # the same documented composition waivers as scripts/run_checks.sh.
  COMPILE_ARGS += -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-BLKSEQ
  ifeq ($(WAVES),1)
    COMPILE_ARGS += --trace-fst
  endif
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: clean_all
clean_all:
	rm -rf sim_build results.xml *.fst *.vcd __pycache__
