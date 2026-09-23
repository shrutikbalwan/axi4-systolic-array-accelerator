# Tiled ML inference core

`rtl/tiled_ml_inference_core.sv` is the compute-side end-to-end ML boundary.
It composes:

```text
packed INT8 A/B tile streams
              |
      tiled_gemm_controller
              |
       INT32 accumulated C
              |
        ml_postprocess
   bias + integer scale/shift
       optional ReLU + clamp
              |
       backpressured INT8 C
```

The scheduler still exposes tile descriptors, so a DMA/buffer adapter can
prepare each tile before asserting `tile_ready`. `tile_m_len` and
`tile_n_len` identify valid edge elements; the compute array itself operates
on the fixed `ARRAY_N x ARRAY_N` padded tile.

The post-processing parameters are currently scalar for a compact integration
boundary. A production model wrapper can provide one set per output channel
or insert a parameter-stream lookup ahead of this block.

`out_valid`, `out_ready`, and `out_last` form the result stream contract.
`out_last` corresponds to the last word of the current output tile, not the
last word of the complete matrix; tile coordinates identify its location.
