# AXI4 Systolic Array Accelerator

[![CI](https://github.com/shrutikbalwan/axi4-systolic-array-accelerator/actions/workflows/ci.yml/badge.svg)](https://github.com/shrutikbalwan/axi4-systolic-array-accelerator/actions/workflows/ci.yml)

A parameterised INT8 matrix-multiplication accelerator written in synthesizable SystemVerilog.
It combines an output-stationary N x N systolic array with an AXI4-Lite control/data interface,
Cocotb verification, ECP5 implementation checks, and an OpenLane/LibreLane starting point.

> **Project status:** RTL, verification, and an open-source ECP5 implementation flow are active in
> GitHub Actions. No FPGA-board validation or ASIC physical-design result is claimed.

## What it computes

The accelerator computes C = A x B:

- A: N x K signed INT8 matrix
- B: K x N signed INT8 matrix
- C: N x N signed INT32 matrix
- 1 <= K <= KMAX
- Default parameters: N = 4 and KMAX = 16
- The full AXI top requires N to be a multiple of 4; the standalone array testbench also covers N = 2

Rows of A and columns of B are skewed as they enter the array. Each processing element multiplies
one pair of INT8 values and accumulates into INT32. For a valid run, the result settles after
K + 2N - 1 array cycles.

## Architecture

~~~text
                         AXI4-Lite / AXI4 DMA
                                  |
                 +----------------v----------------+
                 | Choose integration path         |
                 +-------------+-------------------+
                               |
          Legacy single GEMM   |   Tiled ML / streaming GEMM
                               |
       +-----------------------+--------------------------+
       |                                                  |
+------v-------+                                  +-------v--------+
| axi_lite_    |                                  | DMA + descriptor|
| slave        |                                  | control         |
+------+-------+                                  +-------+--------+
       |                                                  |
+------v-------+                                  +-------v--------+
| accel_ctrl   |                                  | matrix/tile     |
| A/B buffers  |                                  | buffer + tiler  |
+------+-------+                                  +-------+--------+
       |                                                  |
       +------------------+               +---------------+
                          |               |
                   +------v-------+ +-----v----------------+
                   | N x N        | | tiled INT8 GEMM      |
                   | systolic     | | + K-tile accumulation|
                   | array/PEs    | | + INT32 accumulators |
                   +------+-------+ +-----------+----------+
                          |                       |
                    INT32 C                bias + requantize
                          |                       |
                   AXI4-Lite readback       ReLU + saturation
                                                  |
                                           packed INT8 output
~~~

The repository also contains a tiled/streaming path for larger matrix and ML-oriented integration:
tile scheduling, K-tile accumulation, AXI4 read/write DMA, INT8 packing, bias, requantisation,
ReLU, and saturation.

## FPGA implementation results

**post-route on ECP5 LFE5U-85F, open-source flow**

| Array N | LUTs | FFs | DSPs | BRAMs | Post-route Fmax | Fit |
|---:|---:|---:|---:|---:|---:|:---|
| 4 | 3664 | 1122 | 16 | 0 | 70.14 MHz | FITS |
| 8 | 9898 | 3778 | 64 | 0 | 57.48 MHz | FITS |
| 16 | 38360 | 14465 | 256 | 0 | — | **DOES NOT FIT** |

These are place-and-route results from Yosys and nextpnr-ecp5 for the LFE5U-85F in the CABGA381
package, not vendor-tool, board-level, or ASIC measurements. LUTs are nextpnr `TRELLIS_COMB`
usage, FFs are `TRELLIS_FF`, DSPs are `MULT18X18D`, and BRAMs are `DP16KD`. N=16 exceeds the
part's 156 DSP blocks, so nextpnr cannot route it and no Fmax is reported. Reproduce the table with:

~~~bash
./scripts/fpga_report.sh
~~~

The measured implementation data and the separate generic-cell/throughput indicators are documented
in [docs/implementation_estimate.md](docs/implementation_estimate.md).

## Quick start

### 1. Get the source

Use a path without spaces. Verilator-generated makefiles do not work reliably from paths containing
spaces.

~~~bash
git clone https://github.com/shrutikbalwan/axi4-systolic-array-accelerator.git
cd axi4-systolic-array-accelerator
~~~

### 2. Install the HDL and Python tools

The recommended environment is the [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build),
which supplies compatible versions of Verilator, Icarus Verilog, Yosys, and Cocotb.

~~~bash
source /path/to/oss-cad-suite/environment
tabbypip install numpy cocotbext-axi
~~~

You need Verilator 5.x, Icarus Verilog 12 or newer, Yosys, Python with NumPy/Cocotb 2.x/
cocotbext-axi, and GCC for the portable C-driver check.

The reference patch was verified with Verilator 5.020, Icarus Verilog 12.0,
Yosys 0.33, and Cocotb 2.1.0.

On Windows, start with:

~~~powershell
.\scripts\run_reference_checks.ps1
~~~

### 3. Run the checks

Run the broad check entry point used by CI:

~~~bash
./scripts/run_checks.sh
~~~

Useful focused commands:

~~~bash
cd sim
make                         # default Icarus regression, N=4
make SIM=verilator N=8       # Verilator regression, N=8
make TB=array                # standalone array test
make TB=tile N=8             # streamed tile adapter
make TB=scheduler            # runtime tile scheduler
make TB=chain N=8            # multi-K compute chain
make TB=read_dma             # AXI4 read DMA
make TB=write_dma            # AXI4 write DMA
make TB=tiled N=4            # tiled GEMM integration
make TB=ml_core N=4          # INT8 ML post-processing
make TB=stream_gemm N=4      # contiguous matrix stream
make TB=descriptor           # DMA/ML descriptor registers
make TB=ml_packer            # packed INT8 post-processing
make WAVES=1                 # dump an FST waveform
~~~

## ML path: what it does

The ML portion demonstrates how the systolic GEMM engine can be used as a building block for a
small quantized neural-network inference pipeline. It is not a complete trained-model runtime.
It provides a bit-accurate software contract and RTL integration blocks for connecting ML layers
to the accelerator.

### ML dataflow

1. **Quantized inputs:** floating-point weights and activations are represented as signed INT8.
2. **Tiled INT8 GEMM:** matrices are split into tiles so workloads larger than one N x N array can
   be processed over multiple K tiles.
3. **INT32 accumulation:** products accumulate at higher precision before conversion.
4. **Post-processing:** bias is added, then an integer multiplier/shift performs requantization.
5. **Activation and output:** optional ReLU is applied and the result is saturated back to INT8.

The reference implementation in [ml/](ml/) is independent of PyTorch. It acts as a golden model for
quantization, tiled matrix multiplication, bias, ReLU, requantization, and saturation. The example
MLP shape is 784 -> 128 -> 10, representative of a small digit-classifier pipeline.

Run the ML reference tests with:

~~~bash
python -m unittest discover -s ml -p 'test_*.py'
~~~

### ML RTL blocks

- [rtl/tiled_ml_inference_core.sv](rtl/tiled_ml_inference_core.sv) provides the compute-side ML
  boundary with bias, integer scaling, ReLU, saturation, and a backpressured INT8 output stream.
- [rtl/tiled_matrix_tile_buffer.sv](rtl/tiled_matrix_tile_buffer.sv) manages tile movement, edge
  padding, runtime tiling, K accumulation, and row-major result writeback.
- [rtl/tiled_stream_gemm_top.sv](rtl/tiled_stream_gemm_top.sv) connects streaming matrix inputs to
  the tiled GEMM path.
- [rtl/tiled_axi4_gemm_top.sv](rtl/tiled_axi4_gemm_top.sv) provides the connected AXI4/DMA-oriented
  integration boundary with raw-INT32 or packed-INT8 output.

The original AXI4-Lite compatibility top remains a focused single-GEMM interface. The tiled ML
path is intended for larger matrices and neural-network layers. Full FPGA inference results,
trained-model deployment, and measured hardware throughput are not claimed yet; those are future
integration steps documented in [docs/upgrade_roadmap.md](docs/upgrade_roadmap.md).

## Using the AXI4-Lite accelerator

The legacy interface is documented in [docs/register_map.md](docs/register_map.md). The basic sequence is:

1. Write A to the A window at 0x1000. A uses the transposed feed layout.
2. Write B to the B window at 0x2000. B is row-major.
3. Write K to LEN at 0x008.
4. Write START, and optionally IRQ_EN, to CTRL at 0x000.
5. Wait for STATUS.DONE or the level-sensitive irq output.
6. Read N x N signed INT32 results from the C window at 0x3000, row-major.
7. Clear DONE by writing it back to STATUS at 0x004 (write-one-to-clear).

The Python host example in [sim/accel_host.py](sim/accel_host.py) follows this sequence. Invalid
addresses and illegal writes are reported through AXI responses and status bits.

## Verification and CI

GitHub Actions runs on every push and pull request. The workflow checks:

- Python ML reference tests
- Portable C-driver compilation with warnings treated as errors
- Cocotb regressions with Icarus
- Verilator regressions
- RTL lint for the connected top
- Generic Yosys synthesis and latch checks
- ECP5-85K place-and-route resource and timing reports
- Formal AXI-Lite and ping-pong ownership properties

The suite compares results with independent references and checks AXI response ordering, W-before-AW
writes, delayed RREADY, byte strobes, error responses, back-to-back runs, and reset behavior.
Mutation testing detects all 22 deliberately seeded mutants at N = 4 and N = 8.
That 22/22 score describes only the listed mutation set; it is not a claim that the
tests cover every possible RTL defect.

See [docs/verification_matrix.md](docs/verification_matrix.md) for the evidence table and
[docs/dataflow.md](docs/dataflow.md) for dataflow and cycle timing.

## Repository guide

| Path | Purpose |
|---|---|
| rtl/ | Systolic array, PE, AXI-Lite control, tiled GEMM, DMA, buffering, and ML datapath RTL |
| sim/ | Cocotb tests, Makefile, and Python host driver |
| tb/ | Standalone SystemVerilog array testbench |
| ml/ | Bit-accurate INT8/ML reference models and tests |
| scripts/ | Complete checks, reference checks, and mutation testing |
| docs/ | Register map, dataflow, verification evidence, benchmarks, and design notes |
| formal/ | SymbiYosys formal properties |
| openlane/ | OpenLane/LibreLane configuration and constraints |
| constraints/ | Timing constraints |
| fpga/ | FPGA handoff material and platform notes |
| sw/ | Portable C interface and compile checks |

## Important design notes

- A is stored in feed order so each cycle can read a contiguous vector.
- Results remain in the PE accumulators; there is no separate result register file.
- irq is level-sensitive: DONE & IRQ_EN. Clear DONE with the STATUS write-one-to-clear bit.
- The legacy AXI4-Lite top handles one K-limited GEMM; the tiled/streaming path is for larger M/K/N workloads.
- Operand buffers are currently flip-flops. SRAM/BRAM mapping is planned for larger N.
- OpenLane/LibreLane targets SkyWater 130 nm, but no PDK run is claimed; the FPGA figures above are
  open-source ECP5 place-and-route results, not board measurements.

## Further reading

- [AXI4-Lite register map](docs/register_map.md)
- [Array dataflow and timing](docs/dataflow.md)
- [ML inference core](docs/ml_inference_core.md)
- [Matrix/tile buffer](docs/matrix_tile_buffer.md)
- [Benchmark methodology](docs/benchmark_methodology.md)
- [Physical-design targets](docs/physical_design_targets.md)
- [Upgrade roadmap](docs/upgrade_roadmap.md)

## License

This project is released under the [Apache License 2.0](LICENSE).
