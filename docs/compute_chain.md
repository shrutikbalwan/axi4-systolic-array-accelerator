# Multi-K compute chain

`rtl/tiled_compute_chain.sv` composes the stream-to-array adapter and the
K-tile accumulator. A runtime controller drives one `start_tile` per K tile:

```text
start_tile + first_k + last_k
        ↓
A/B streams → systolic_tile_adapter → tile_accumulator → C stream
```

The first K tile overwrites the accumulator, intermediate tiles accumulate,
and the final tile produces the C stream. This is the hardware counterpart of
the software `tiled_gemm` implementation.
