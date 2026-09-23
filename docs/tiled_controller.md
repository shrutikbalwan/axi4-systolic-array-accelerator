# Runtime tiled GEMM controller

`rtl/tiled_gemm_controller.sv` composes the runtime tile scheduler with the
multi-K compute chain. A DMA/buffer wrapper observes `tile_valid` and the
M/N/K base/length fields, prepares the A/B streams, then raises `tile_ready`.
The controller launches the tile, waits for `tile_done`, and advances K first.

C output is produced only after the final K tile of each output tile, so the
downstream writer sees complete INT32 C tiles rather than partial sums.
