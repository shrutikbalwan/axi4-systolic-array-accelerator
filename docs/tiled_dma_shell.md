# Tiled DMA shell

`rtl/tiled_dma_shell.sv` is the SoC-facing composition point for the tiled
accelerator path. It instantiates the descriptor block, two AXI4 read movers
(A and B), and one AXI4 write mover (C). Programming M/K/N automatically
derives packed INT8 input word counts and INT32 output word count.

The A/B/C stream ports are intentionally explicit. The compute-side
`tiled_ml_inference_core` consumes tile-shaped streams and produces
post-processed INT8 results, while this shell exposes contiguous DMA streams.
`tiled_axi4_gemm_top.sv` now composes this shell with the matrix/tile buffer
and runtime tiled GEMM controller, including edge zero-padding and output-tile
placement. The original `systolic_accel_top` remains the compatibility
baseline; the connected top is a separate DMA-backed architecture.
