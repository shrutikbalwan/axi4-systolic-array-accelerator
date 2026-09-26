# Verification matrix

This matrix separates implemented architecture from evidence that still
requires the external HDL or FPGA toolchain.

| Capability | Implementation | Local evidence | CI / external evidence still required |
|---|---|---|---|
| INT8 quantization and tiled GEMM | `ml/quantized_mlp.py`, `ml/tiled_inference.py` | 12 Python tests | None for reference model |
| Integer ML post-processing | `rtl/ml_postprocess.sv`, `rtl/ml_int8_packer.sv` | Python golden model and packer cocotb target | Verilator/Icarus execution |
| Runtime M/K/N tiling | `rtl/tile_scheduler.sv`, `rtl/tiled_gemm_controller.sv` | NumPy descriptor emulator | HDL simulation |
| K-tile accumulation | `rtl/tile_accumulator.sv`, `rtl/tiled_compute_chain.sv` | Tiled reference tests | HDL simulation |
| Contiguous-to-tile buffering | `rtl/tiled_matrix_tile_buffer.sv` | Stream GEMM cocotb target | HDL simulation and RAM inference report |
| AXI4 burst movement | `rtl/axi4_read_dma.sv`, `rtl/axi4_write_dma.sv` | DMA cocotb plus FVIP-derived formal proofs, including 4KB boundaries | None for implemented protocol rules |
| Connected AXI4 GEMM/ML top | `rtl/tiled_axi4_gemm_top.sv` | Descriptor-level emulator | Connected-top lint, simulation, synthesis |
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
