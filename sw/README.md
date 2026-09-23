# SoC integration hook

[`accelerator.h`](accelerator.h) is a portable bare-metal driver contract for
the existing AXI4-Lite register map. A board-specific port only needs to
provide 32-bit MMIO read/write functions. The API exposes the accelerator
interrupt-friendly start/done flow and the new cycle/MAC performance counters.

`dma_descriptor.h` extends this contract with base addresses, burst lengths,
tile dimensions and descriptor ownership. The same ML application can keep
the control API while a board-specific port supplies the actual AXI4 memory
fabric and interrupt handler.

[`dma_descriptor.h`](dma_descriptor.h) adds the descriptor API for the tiled
AXI4 path: source/destination addresses, M/K/N dimensions, tile dimensions,
start, interrupt enable, polling, abort, and sticky status management.

`test_compile.c` is a warning-as-error compile smoke test for both headers;
the main check script runs it when GCC is available.
