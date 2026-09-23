# Ping-pong tile buffering

`rtl/dual_bank_buffer.sv` is the memory boundary between the DMA engines and
the compute scheduler. It has two independently selectable banks:

```text
DMA writes bank 0  ───────┐
                          ├── dual_bank_buffer ──> systolic/tile consumer
compute reads bank 1 ─────┘
```

The controller can swap bank selectors after a complete input tile has been
loaded and the previous output tile has been consumed. The read port is
synchronous with one-cycle latency, which is suitable for FPGA BRAM
inference. The module has no reset loop over memory, avoiding expensive reset
logic and preserving RAM inference.
