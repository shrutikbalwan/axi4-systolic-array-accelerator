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
6. **SoC integration (done in simulation)**: `tiled_axi4_gemm_top` sits on a
   VexRiscv/LiteX SoC bus (`soc/`), driven by bare-metal C through the
   portable driver. A trained digits MLP runs bit-exact at 40.6x (4x4) /
   56.6x (8x8) the CPU-only speed, with a per-channel bias vector so a whole
   quantised layer is one descriptor. Remaining: an FPGA board run.
7. **Evidence**: formal AXI/controller properties, FPGA utilization/Fmax,
   bandwidth, latency, MAC/cycle and accuracy reports in CI artifacts. A
   generic FPGA timing template and benchmark script are now present; actual
   board measurements remain external hardware work.

## Done: pipelined tile schedule

`rtl/tiled_gemm_engine.sv` (default, `PIPELINED=1`) replaced the serial
*send K words -> compute -> drain -> accumulate -> capture* tile loop with a
K-vector-per-cycle feed straight from the on-chip buffers, one-cycle N x N
capture and overlapped C output. Ideal-memory 64x64x64 GEMM: 52.2k -> 20.4k
cycles at 4x4 (31 % -> 80 % PE utilisation) and 30.3k -> 9.3k at 8x8
(`docs/results/axi4_gemm_ideal_memory*_N*.csv`). SoC fused MLP: 40.6x -> 73.5x
(4x4) and 56.6x -> 105.8x (8x8) over the CPU.

## Done: direct DMA memory port

With the pipelined engine, a 64x64x64 INT32 GEMM still took ~31k cycles in the
SoC at *both* array sizes: LiteX turned every DMA beat into a single Wishbone
transfer on the CPU's bus. Main RAM is now true dual-port; `axi_dma_mem_port`
gives the accelerator port 1 with one-beat-per-cycle INCR bursts, round-robin
A/B arbitration and SLVERR for out-of-range bursts. 8x8 GEMM: 31.1k -> 8.4k
cycles; fused MLP 105.8x -> 230.3x the CPU (4x4: 73.5x -> 113.3x). The old
path stays available (`--mem-port bus`) and CI runs both.

## Next: driver overhead

In the fused network 8k of 43k cycles (8x8) are the CPU programming 12
descriptors and polling. Descriptor chaining (a small descriptor queue in the
shell) or an IRQ-driven driver that prepares job t+1 while job t runs would
recover most of it. Overlapping the operand load with compute is the other
option: B must be complete before the first tile, but A can stream row-block
by row-block.

## After that: remove the drain bubble

Each tile still spends 2N-1 drain cycles with no new inputs (K=64: 7 of 72
cycles at N=4, 15 of 80 at N=8). Overlapping the next tile's feed with the
drain needs a per-PE "tile boundary" token travelling with the operands so each
PE snapshots and clears on its own diagonal wavefront - a change to the verified
`pe_mac`/`systolic_array` core, so it deserves its own formal properties.

The legacy AXI4-Lite core remains the compatibility baseline while each
milestone is added behind a tested interface.
