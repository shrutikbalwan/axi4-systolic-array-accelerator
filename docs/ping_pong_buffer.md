# Ping-pong ownership protocol

`rtl/ping_pong_bank_manager.sv` provides the control contract for overlapping
DMA and compute:

1. DMA raises `fill_req` and receives `fill_gnt` plus `fill_bank`.
2. DMA fills that bank through `dual_bank_buffer` and raises `fill_done`.
3. Compute claims a ready bank with `consume_valid && consume_ready`.
4. Compute drains that bank and raises `consume_done`, returning it to `FREE`.

With two banks, compute can hold one bank in `READ` while DMA fills the other
in `FILL`. Premature completion events set a sticky error. The formal property
file captures the key ownership invariants.
