# FPGA integration guide

The RTL is board-independent. The recommended first target is a Xilinx or
Intel FPGA SoC with DDR and an AXI interconnect; `tiled_axi4_gemm_top` exposes
the connected AXI4 memory path and `dma_descriptor_ctrl` exposes the
control-plane register port. `tiled_dma_shell` remains available when a
platform wants to provide its own tile-buffer wrapper.

## Platform wrapper responsibilities

1. Provide a clock and synchronous reset release.
2. Connect the descriptor register port to AXI4-Lite or a RISC-V MMIO bus.
3. Connect the A/B read and C write AXI4 channels to DDR through the platform
   interconnect.
4. For the connected path, instantiate `tiled_axi4_gemm_top`; otherwise
   connect the shell's A/B/C streams to the tile buffers and adapter.
5. Route `irq` to the processor interrupt controller.
6. Add board-specific pin constraints and a clock constraint based on the
   selected oscillator/PLL.

The repository includes a generic 100 MHz XDC template in
`constraints/fpga_100mhz.xdc`; it intentionally does not invent board pin
locations. Publish the board name, tool version, utilization, Fmax, and power
with any measured result.

For ASIC-style timing exploration, use
`openlane/config_tiled_axi4_gemm.json` with
`constraints/tiled_axi4_gemm.sdc`; it targets the connected DMA/tiled/ML top
instead of the legacy compatibility core.

## Required evidence for a hardware result

- post-place-and-route Fmax and timing slack;
- LUT/ALM, flip-flop, BRAM and DSP usage;
- DDR bandwidth and DMA transfer time;
- GEMM latency, MAC/cycle and end-to-end ML accuracy;
- the exact board, clock, synthesis settings and commit.
