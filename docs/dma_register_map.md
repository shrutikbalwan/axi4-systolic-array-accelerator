# Tiled DMA descriptor register map

`dma_descriptor_ctrl` is a separate control-plane block for the AXI4 DMA and
tiled GEMM path. It uses a 4 KiB register window and a simple register-port
interface, so it can be placed behind the existing AXI4-Lite adapter or a
RISC-V MMIO bridge.

| Offset | Register | Access | Meaning |
|---:|---|---|---|
| `0x00` | CTRL | RW/W1P | bit 0 START, bit 1 ABORT hook, bit 2 IRQ_EN |
| `0x04` | STATUS | RO/W1C | bit 0 BUSY, bit 1 DONE, bit 2 ERROR |
| `0x08` | A_BASE | RW | Source address for activation tiles |
| `0x0C` | B_BASE | RW | Source address for weight tiles |
| `0x10` | C_BASE | RW | Destination address for result tiles |
| `0x14` | M | RW | Matrix output rows |
| `0x18` | N | RW | Matrix output columns |
| `0x1C` | K | RW | Matrix reduction dimension |
| `0x20` | TILE_M | RW | Output-row tile size |
| `0x24` | TILE_N | RW | Output-column tile size |
| `0x28` | TILE_K | RW | Reduction tile size |
| `0x2C` | POST_BIAS | RW | Signed INT32 post-processing bias |
| `0x30` | POST_SCALE | RW | Signed INT32 requantization multiplier |
| `0x34` | POST_CFG | RW | bit 0 ReLU, bit 1 packed INT8 output, bits 7:2 arithmetic shift |
| `0x38` | PERF_ACTIVE | RO | Active compute cycles for the latest job |
| `0x3C` | PERF_MAC_LO | RO | Low 32 bits of useful MAC count |
| `0x40` | PERF_MAC_HI | RO | High 32 bits of useful MAC count |
| `0x44` | PERF_TILES | RO | Scheduled tile count for the latest job |
| `0x100 + 4*j` | BIAS[j] | RW | Per-output-column INT32 bias, `j < MAX_N` (connected top only). Resets to 0; SLVERR and ignored while BUSY |

In packed-INT8 mode, element `(i, j)` is post-processed as
`sat8(relu?(((acc + POST_BIAS + BIAS[j]) * POST_SCALE) >>> SHIFT))`. The vector
resets to zero, so software that only programs `POST_BIAS` sees the original
behaviour; `accel_dma_load_bias()` in `sw/dma_descriptor.h` loads a layer's
vector and zeroes the unused tail.

### START admission (connected top)

`tiled_dma_shell` checks the descriptor when START is written. A START is
**rejected**, with ERROR set one cycle later, no DMA traffic and BUSY never
asserted, unless:

- `1 <= M <= MAX_M`, `1 <= N <= MAX_N`, `1 <= K <= MAX_K`;
- `TILE_M` and `TILE_N` are non-zero multiples of 4 and `<= ARRAY_N`;
- `1 <= TILE_K <= MAX_K`;
- `A_BASE`, `B_BASE` and `C_BASE` are 4-byte aligned.

Before this check, an illegal tile size reached the tile buffer, which then
waited forever for compute completion: BUSY stayed high until hardware reset.

### TILE_K with the pipelined engine

With the default `PIPELINED=1` compute engine the full K slice is on chip, so
the array reduces all of K in one pass and `TILE_K` only has to be legal
(`1..MAX_K`). Results are identical either way (INT32 accumulation), and
`PERF_TILES` still reports the descriptor's `ceil(M/TM)*ceil(N/TN)*ceil(K/TK)`
count so software sees the same value on both engines. `TILE_M`/`TILE_N` set
the output block size in both engines.

### DONE / ERROR are events

Each accepted job raises DONE exactly once (and ERROR at most once). Both are
cleared by writing ones to STATUS, and the level IRQ `IRQ_EN & (DONE | ERROR)`
drops as soon as they are cleared. Earlier revisions fed the shell's
"all movers finished" level straight into DONE, so DONE and the IRQ could not
be cleared until the next START.

Descriptor writes are rejected while `BUSY`. DONE and ERROR are sticky and
cleared with one bits in STATUS. The DMA engine reports completion/error into
this block, which can produce a level-sensitive interrupt.
