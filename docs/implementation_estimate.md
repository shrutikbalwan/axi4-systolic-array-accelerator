# Hardware-independent implementation estimate

This report is intentionally separate from measured FPGA results. No FPGA
board or PDK signoff run is available, so timing, power, and board utilization
must not be presented as measured results.

## Verified generic synthesis

The connected tiled AXI4/ML design was elaborated and synthesized with Yosys
using generic cells:

| Configuration | Generic cells | Latch check |
|---|---:|---|
| `ARRAY_N=4`, `MAX_M=64`, `MAX_N=64`, `MAX_K=64` | 22,835 | No latches reported |
| `ARRAY_N=8`, `MAX_M=64`, `MAX_N=64`, `MAX_K=64` | 83,957 | No latches reported |

These figures are reproducible synthesis indicators, not FPGA LUT, FF, BRAM,
DSP, or ASIC area numbers.

## Throughput model

At a hypothetical 100 MHz clock and full array utilization, the raw MAC rate
is:

| Array | MACs/cycle | Theoretical rate |
|---|---:|---:|
| 4x4 | 16 | 1.6 GMAC/s |
| 8x8 | 64 | 6.4 GMAC/s |
| 16x16 | 256 | 25.6 GMAC/s |

Actual throughput depends on DMA bandwidth, edge-tile padding, clock timing,
memory inference, and software scheduling. The ML benchmark reports padding
and tile-count effects separately.

## Reproduction path when hardware becomes available

1. Run the vendor synthesis flow for the selected FPGA part.
2. Record LUTs, registers, BRAM, DSPs, Fmax, and power.
3. Run the supplied ML workload and record end-to-end latency and throughput.
4. Replace this estimate with measured values while retaining the generic
   synthesis table for portability.
