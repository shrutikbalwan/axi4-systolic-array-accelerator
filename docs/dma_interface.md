# AXI4 DMA integration contract

`rtl/axi4_read_dma.sv` and `rtl/axi4_write_dma.sv` are the first memory-system
blocks. They accept a contiguous base address and word count, issue AXI4
incrementing bursts, and expose ready/valid streams to tile buffers.

## Contract

- 32-bit data beats and 4-byte aligned addresses.
- `ARLEN` is burst length minus one; bursts are at most `MAX_BURST` beats.
- Read data is held by AXI until the downstream stream raises `stream_ready`.
- `stream_last` marks the final word of the entire request, not each burst.
- `done` is a one-cycle pulse after the final beat or an empty request.
- `error` latches an AXI error response or an unexpected `RLAST`.

The intended path is:

```text
AXI4 read DMA -> BRAM/SRAM tile buffer -> tile_scheduler -> systolic array
                                             -> output buffer -> write DMA
```

`tiled_ml_inference_core` now implements the compute-side controller and ML
post-processing boundary behind the tile-buffer interface. A production
memory wrapper still needs to gather the contiguous DMA streams into the
current tile, handle edge zero-padding, and return output tiles to the write
DMA. Descriptor registers and double-buffer ownership are therefore the next
memory-system integration step. The AXI4-Lite registers remain the
control-plane interface.
