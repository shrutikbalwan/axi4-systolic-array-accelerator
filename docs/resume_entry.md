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
- Integrated the accelerator into a **VexRiscv RISC-V SoC (LiteX)** with three
  AXI4 DMA bus masters and wrote bare-metal C firmware; a trained INT8 digits
  MLP runs **bit-exact with the Python golden model (98.06 %, 353/360)** at
  **113x (4x4) / 230x (8x8) the CPU-only speed**, cycle-accurate in Verilator CI.
- Drove four measured optimisation steps (11x -> 230x end to end): moved the
  per-channel epilogue into RTL after profiling showed it was 66 % of runtime;
  designed a pipelined tile engine that raised PE utilisation from 31 % to 80 %;
  then found the SoC interconnect throttling DMA and built a burst-capable AXI4
  port into dual-port RAM (8x8 GEMM 31.1k -> 8.4k cycles). Each change keeps the
  old path selectable and cross-checked in CI.
- Wrote the first end-to-end testbench for the connected DMA top and found two
  real bugs (un-clearable DONE/IRQ; illegal descriptor wedging the core until
  reset); fixed them with START admission checks and event-based completion,
  guarded by new mutants (46/46 seeded mutants killed, incl. formal-proof mutants).

### Interview note

Speed-ups are cycle-accurate simulation results (Verilator, VexRiscv "standard"
at -O2 as the baseline), not board measurements. The honest next bottleneck is
also measured: ~19 % of the fused 8x8 run is the CPU programming descriptors
and polling, so descriptor chaining / IRQ-driven overlap is next.
Accuracy figures: scikit-learn 1.8.0, NumPy 1.26, seed 2026.
