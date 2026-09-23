# Benchmark methodology

`ml/benchmark.py` reports two different classes of evidence:

- `software_seconds` and `software_macs_per_second` are measured on the host
  Python reference backend only.
- `padded_mac_slots`, `array_mac_utilization`, `ideal_compute_cycles`, and
  `ideal_useful_macs_per_cycle` are deterministic architecture estimates for
  the configured array and tile sizes. They account for edge-tile padding and
  the array drain interval, but do not include AXI arbitration, DMA latency,
  clock frequency, or implementation timing.

It also reports A/B input words and both raw INT32 and packed INT8 C writeback
word counts. FPGA claims must replace the ideal estimates with board clock,
post-place-and-route timing, DMA bandwidth, and measured end-to-end latency.
