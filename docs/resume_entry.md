# Resume-ready project entry

## AXI4 Tiled INT8 Systolic-Array ML Accelerator

- Designed and extended a parameterized SystemVerilog INT8 systolic-array
  accelerator from AXI4-Lite GEMM into a tiled M/K/N architecture with runtime
  scheduling, K-tile accumulation, edge-tile zero padding, and INT32 result
  handling.
- Integrated AXI4 burst read/write DMA hooks, descriptor-based SoC control,
  portable C MMIO drivers, matrix/tile buffering, ping-pong bank ownership, and
  cycle/MAC performance counters while preserving the original AXI4-Lite core.
- Implemented an integer ML datapath with bias, signed multiplier/shift
  requantization, optional ReLU, INT8 saturation, and packed INT8 DMA writeback;
  matched the RTL contract with a NumPy golden model.
- Built formal-verification foundations for AXI response stability and DMA/
  compute bank ownership, plus CI targets for lint, synthesis, simulation,
  formal checks, descriptor registers, DMA, tiled GEMM, and ML writeback.
- Trained and quantized a reproducible handwritten-digits MLP; measured **97.22%
  accuracy using the integer RTL post-processing contract** on the held-out
  software reference path.

### Interview note

The repository distinguishes software/reference accuracy from HDL and FPGA
measurements. Verilator/Icarus/Yosys/SymbiYosys CI and board-specific timing,
utilization, bandwidth, and power results should be added before claiming
hardware performance.
