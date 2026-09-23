# K-tile accumulation

`rtl/tile_accumulator.sv` combines partial `C` tiles from multiple reduction
tiles:

```text
C_tile(K0) --first_k=1--┐
C_tile(K1) --first_k=0--├─ tile_accumulator --last_k=1--> post-process/write
C_tile(K2) --first_k=0--┘
```

Each input tile contains exactly `N*N` signed INT32 words. On the first K tile,
the words overwrite the local accumulator; subsequent K tiles add to it. The
final K tile is streamed out with ready/valid backpressure. This matches the
software `tiled_gemm` contract and lets the array remain unchanged while the
controller supports arbitrary K dimensions.
