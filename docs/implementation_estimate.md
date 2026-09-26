# Implementation measurements and estimates

This report keeps measured FPGA implementation data separate from portable
generic-cell indicators and the throughput model. No FPGA-board measurement,
vendor-tool result, power result, or PDK signoff run is available.

## Measured FPGA implementation

**post-route on ECP5 LFE5U-85F, open-source flow**

| Array N | LUTs | FFs | DSPs | BRAMs | Post-route Fmax | Fit |
|---:|---:|---:|---:|---:|---:|:---|
| 4 | 3664 | 1122 | 16 | 0 | 70.14 MHz | FITS |
| 8 | 9898 | 3778 | 64 | 0 | 57.48 MHz | FITS |
| 16 | 38360 | 14465 | 256 | 0 | — | **DOES NOT FIT** |

These values come from Yosys `synth_ecp5` followed by nextpnr-ecp5 place and
route for the LFE5U-85F/CABGA381. LUTs are `TRELLIS_COMB`, FFs are
`TRELLIS_FF`, DSPs are `MULT18X18D`, and BRAMs are `DP16KD`. The reported Fmax
is nextpnr's final post-route timing result; the 100 MHz constraint is the
placement target, not the claimed result. N=16 requests 256 of the part's 156
DSP blocks and therefore does not fit, so it has no routed Fmax.

Run `./scripts/fpga_report.sh` to reproduce all three configurations. Full
Yosys and nextpnr logs plus the generated Markdown table are written below
`build/fpga_report/` and retained as CI artifacts.

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

## Reproduction path for board and ASIC measurements

1. Run the vendor synthesis flow for the selected FPGA part.
2. Record LUTs, registers, BRAM, DSPs, Fmax, and power.
3. Run the supplied ML workload and record end-to-end latency and throughput.
4. Add those measurements while retaining both the open-source FPGA results
   and generic synthesis table with their distinct labels.
