# Verification matrix

This matrix separates implemented architecture from evidence that still
requires the external HDL or FPGA toolchain.

| Capability | Implementation | Local evidence | CI / external evidence still required |
|---|---|---|---|
| INT8 quantization and tiled GEMM | `ml/quantized_mlp.py`, `ml/tiled_inference.py` | 14 Python tests | None for reference model |
| Integer ML post-processing | `rtl/ml_postprocess.sv`, `rtl/ml_int8_packer.sv` | Python golden model and packer cocotb target | Verilator/Icarus execution |
| Runtime M/K/N tiling | `rtl/tile_scheduler.sv`, `rtl/tiled_gemm_controller.sv` | NumPy descriptor emulator | HDL simulation |
| K-tile accumulation | `rtl/tile_accumulator.sv`, `rtl/tiled_compute_chain.sv` | Tiled reference tests | HDL simulation |
| Contiguous-to-tile buffering | `rtl/tiled_matrix_tile_buffer.sv` | Stream GEMM cocotb target | HDL simulation and RAM inference report |
| AXI4 burst movement | `rtl/axi4_read_dma.sv`, `rtl/axi4_write_dma.sv` | DMA cocotb plus FVIP-derived formal proofs, including 4KB boundaries | None for implemented protocol rules |
| Connected AXI4 GEMM/ML top | `rtl/tiled_axi4_gemm_top.sv` | `sim/test_axi4_gemm_top.py` (9 tests, N=4/8): INT32/INT8 writeback, awkward M/N/K, random AXI back-pressure, per-channel bias, descriptor admission, IRQ clear; mutants M31–M36 | Synthesis/P&R of the connected top |
| Pipelined compute engine | `rtl/tiled_gemm_engine.sv` (`PIPELINED=1`, default) | `test_stream_gemm` (edge + full-array shapes) and all 9 `test_axi4_gemm_top` tests at N=4/8, cross-checked against the reference path (`PIPELINED=0`); mutants M37–M41; SoC MLP bit-exact | Synthesis/P&R |
| Direct DMA memory port | `rtl/axi_dma_mem_port.sv` | `test_axi_dma_mem_port` (6 tests, Icarus + Verilator): concurrent A/B bursts, fairness, WSTRB, back-pressure, 1 beat/cycle, exact-boundary SLVERR; mutants M42–M46; SoC MLP bit-exact on both memory modes | Board-level DDR port |
| Per-channel bias epilogue | `rtl/tiled_axi4_gemm_top.sv`, `ml/accelerator_emulator.py` | cocotb bias tests; emulator reproduces `QuantizedLinear.run_integer_contract` exactly | None |
| RISC-V SoC integration | `soc/accel_soc.py`, `soc/firmware/main.c` | VexRiscv/LiteX Verilator run at N=4 and N=8: GEMM self-test, illegal-descriptor recovery, 360-image MLP bit-exact (CRC) vs Python ([results](results/)) | FPGA board run |
| SoC descriptor interface | `rtl/dma_descriptor_ctrl.sv`, `sw/dma_descriptor.h` | C compile and descriptor cocotb target | HDL simulation on CI |
| Performance accounting | `rtl/accel_ctrl.sv`, `ml/benchmark.py` | Reference MAC/tile report | FPGA cycle/bandwidth measurements |
| Formal AXI properties | `formal/axi_lite_slave.sby`, `formal/axi4_read_dma.sby`, `formal/axi4_write_dma.sby` | AXI-Lite and AXI4 DMA proofs pass locally | CI re-run |
| Formal ping-pong properties | `formal/ping_pong_bank_manager.sby` | Harness checked into repo | SymbiYosys proof |
| FPGA/ASIC readiness | OpenLane configs, SDC/XDC, FPGA guide | JSON validation | P&R, timing, utilization, power |

The original `systolic_accel_top` remains the compatibility baseline. New
connected-path claims should be reported only with the corresponding CI or
hardware evidence.

On Windows, run `scripts/run_reference_checks.ps1` for the local software,
driver, configuration, and tool-availability checks. Run
`scripts/run_checks.sh` from an OSS CAD Suite environment for the complete
HDL/CI matrix.
