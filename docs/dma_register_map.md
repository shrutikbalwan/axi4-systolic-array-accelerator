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

Descriptor writes are rejected while `BUSY`. DONE and ERROR are sticky and
cleared with one bits in STATUS. The DMA engine reports completion/error into
this block, which can produce a level-sensitive interrupt.
