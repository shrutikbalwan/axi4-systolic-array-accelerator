# Matrix/tile buffer integration

`rtl/tiled_matrix_tile_buffer.sv` is the missing bridge between a contiguous
DMA stream and the tiled compute contract.

- A and B enter as row-major INT8 matrices, packed four bytes per 32-bit word.
- The bridge stores them in parameterized arrays that can be mapped to BRAM or
  replaced by banked SRAM.
- Tile descriptors from `tiled_gemm_controller` select each tile.
- Edge rows/columns are zero-padded to `ARRAY_N x ARRAY_N`.
- INT32 output tiles are captured and only valid M x N elements are written to
  the result buffer.
- The completed matrix leaves as a contiguous row-major INT32 stream.
- Tile M/N configuration is validated as a multiple of four INT8 lanes and is
  bounded by the instantiated array; the reference configuration is 4x4.
- Intermediate K tiles retire through an explicit `tile_done` handshake. Only
  the final K tile emits C data, so the buffer cannot wait forever for output
  from an accumulator that is intentionally suppressing partial results.

`tiled_stream_gemm_top.sv` composes this bridge with the runtime scheduler and
compute chain. It is intentionally separate from `systolic_accel_top.sv`, so
the original verified AXI4-Lite design remains a compatibility baseline.

The current implementation is a correctness/reference architecture. Before
claiming FPGA efficiency, synthesize with the intended `MAX_*` values and
inspect whether the vendor infers block RAM rather than registers. The
standalone ping-pong bank manager provides the ownership protocol for a future
overlapped DMA implementation; this reference bridge deliberately serializes
load, compute, and writeback so its latency is deterministic.
