# Flagship accelerator upgrade roadmap

The existing repository is the verified compute core. The target extension is
an end-to-end ML accelerator whose interfaces, arithmetic and measurements are
credible at RTL, FPGA and software levels.

## Architecture target

```text
RISC-V/host CPU
       |
       +-- AXI4-Lite control, status and performance counters
       |
       +-- AXI4 burst DMA <-> DDR
                    |
             double-buffered SRAM/BRAM
                    |
              tiled INT8 GEMM array
                    |
             bias / ReLU / requantization
                    |
              output DMA or AXI4-Stream
```

## Milestones

1. **ML contract (implemented)**: bit-accurate INT8 quantization, tiled GEMM,
   bias, ReLU and an MNIST-sized 784-128-10 MLP reference. An optional
   reproducible trained-digits demo reports float versus quantized accuracy.
2. **Software execution layer (implemented)**: backend-neutral tiled scheduler
   plus portable C MMIO driver contract for FPGA/RISC-V integration.
3. **RTL ML datapath (implemented)**: bias/requantization/ReLU block plus the
   `tiled_ml_inference_core` wrapper, with integer multiplier/shift generation
   and comparison support in `ml/quantized_mlp.py`.
4. **Tiled controller**: arbitrary M/K/N dimensions, K-tile accumulation and
   edge tiles with zero padding. The reusable `tile_scheduler` now latches
   runtime tile sizes and exposes first/last-K metadata; the
   `systolic_tile_adapter` and `tile_accumulator` provide the compute boundary,
   composed by `tiled_compute_chain` and driven by `tiled_gemm_controller`.
5. **Memory system (integration boundary implemented)**: BRAM/SRAM-style
   operand buffers, AXI4 burst DMA, a descriptor/status register block, a
   two-bank synchronous buffer, a contiguous-matrix-to-padded-tile bridge, and
   a ping-pong bank ownership controller are present. Vendor-specific RAM
   inference and wiring the manager into a fully overlapped DMA schedule
   remain.
6. **SoC integration (connected reference top implemented)**: portable C/Python
   control APIs, interrupt/status contracts, programmable ML descriptors, and
   `tiled_axi4_gemm_top` are present. It supports raw INT32 or packed INT8
   writeback; remaining board-specific work is target interconnect hookup and
   a reproducible hardware MNIST demo.
7. **Evidence**: formal AXI/controller properties, FPGA utilization/Fmax,
   bandwidth, latency, MAC/cycle and accuracy reports in CI artifacts. A
   generic FPGA timing template and benchmark script are now present; actual
   board measurements remain external hardware work.

The legacy AXI4-Lite core remains the compatibility baseline while each
milestone is added behind a tested interface.
