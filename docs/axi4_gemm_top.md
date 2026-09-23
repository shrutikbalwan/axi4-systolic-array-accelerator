# Connected AXI4 tiled GEMM top

`rtl/tiled_axi4_gemm_top.sv` composes the SoC-facing pieces into one raw
INT32 GEMM path:

```text
AXI4-Lite descriptor writes
          |
     DMA shell
   A/B reads, C write
          |
   matrix/tile buffer
          |
 runtime tiled controller
          |
   INT8 systolic GEMM
          |
      INT32 C writeback
```

The descriptor's post-processing fields configure an optional packed-INT8
writeback mode. With `POST_CFG.OUTPUT_INT8=1`, the top applies bias, integer
requantization, optional ReLU/saturation, packs four results per AXI beat, and
changes the C DMA length to `ceil(M*N/4)`. With the bit clear it returns raw
INT32 GEMM results.

The shell now includes compute busy/error/done in its aggregate status. A
descriptor cannot be rewritten while DMA or tiled compute is active, and DONE
is reported only after all three DMA movers and the compute path complete.

The connected top also records active compute cycles, useful MACs, and scheduled
tile count in the read-only `PERF_*` descriptor registers; the C driver exposes
these through `accel_dma_performance()`.
