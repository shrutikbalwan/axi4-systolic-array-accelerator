# AXI4 Systolic Array Accelerator

[![CI](https://github.com/shrutikbalwan/axi4-systolic-array-accelerator/actions/workflows/ci.yml/badge.svg)](https://github.com/shrutikbalwan/axi4-systolic-array-accelerator/actions/workflows/ci.yml)

A parameterised INT8 matrix-multiplication accelerator written in synthesizable SystemVerilog.
It combines an output-stationary N x N systolic array with an AXI4-Lite control/data interface,
Cocotb verification, generic Yosys synthesis checks, and an OpenLane/LibreLane starting point.

> **Project status:** The RTL and verification flows are active and passing in GitHub Actions.
> FPGA implementation and physical design have configuration files, but have not yet been run here.

## What it computes

The accelerator computes:

C = A x B

- A: N x K signed INT8 matrix
- B: K x N signed INT8 matrix
- C: N x N signed INT32 matrix
- 1 <= K <= KMAX
- Default parameters: N = 4 and KMAX = 16
- The full AXI top requires N to be a multiple of 4; the standalone array testbench also covers N = 2

The design skews rows of A and columns of B as they enter the array. Each processing element
multiplies one pair of INT8 values and accumulates into INT32. For a valid run, the result settles
after K + 2N - 1 array cycles.

## Architecture

~~~text
                    AXI4-Lite
                        |
              +---------v----------+
              | axi_lite_slave     |
              +---------+----------+
                        |
              +---------v----------+
              | accel_ctrl         |
              | - control/status   |
              | - A and B buffers  |
              | - run controller   |
              +----+----------+----+
                   |          |
             skewed A    skewed B
                   |          |
              +----v----------v----+
              | N x N systolic     |
              | array of pe_mac    |
              +---------+----------+
                        |
                  C accumulators
                        |
                   AXI4-Lite readback
~~~

The repository also contains a separate tiled/streaming path for larger matrix and ML-oriented
integration: tile scheduling, K-tile accumulation, AXI4 read/write DMA, INT8 packing, bias,
requantisation, ReLU, and saturation.

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

You need:

- Verilator 5.x
- Icarus Verilog 12 or newer
- Yosys
- Python with NumPy, Cocotb 2.x, and cocotbext-axi
- GCC for the portable C-driver compile check

On Windows, start with the repository's reference-check script:

~~~powershell
.\scripts\run_reference_checks.ps1
~~~

### 3. Run the checks

Run the same broad check entry point used by CI:

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
make WAVES=1                 # additionally dump an FST waveform
~~~

Run the software ML reference independently with:

~~~bash
python -m unittest discover -s ml -p 'test_*.py'
~~~

## Using the AXI4-Lite accelerator

The legacy top-level interface is documented in [docs/register_map.md](docs/register_map.md).
The basic transaction sequence is:

1. Write A to the A window at 0x1000. A uses the accelerator's transposed feed layout.
2. Write B to the B window at 0x2000. B is row-major.
3. Write K to LEN at 0x008.
4. Write START, and optionally IRQ_EN, to CTRL at 0x000.
5. Wait for STATUS.DONE or the level-sensitive irq output.
6. Read N x N signed INT32 results from the C window at 0x3000, row-major.
7. Clear DONE by writing it back to STATUS at 0x004 (write-one-to-clear).

The small Python host example in [sim/accel_host.py](sim/accel_host.py) follows this sequence.
Invalid addresses and illegal writes are reported through AXI responses and status bits rather than
being silently ignored.

## Verification and CI

GitHub Actions runs on every push and pull request. The workflow checks:

- Python ML reference tests
- Portable C-driver compilation with warnings treated as errors
- Cocotb regressions with Icarus
- Verilator regressions
- RTL lint for the connected top
- Generic Yosys synthesis and latch checks
- Formal AXI-Lite and ping-pong ownership properties

The test suite compares results with independent references and checks timing-sensitive behavior,
including AXI response ordering, W-before-AW writes, delayed RREADY, byte strobes, error responses,
back-to-back runs, and reset behavior. Mutation testing covers 20 seeded RTL/test bugs at N = 4 and
N = 8; the current score is 20/20 detected.

For the detailed evidence table, see [docs/verification_matrix.md](docs/verification_matrix.md).
For the dataflow derivation and cycle timing, see [docs/dataflow.md](docs/dataflow.md).

## Repository guide

| Path | Purpose |
|---|---|
| rtl/ | Systolic array, PE, AXI-Lite control, tiled GEMM, DMA, buffering, and ML datapath RTL |
| sim/ | Cocotb tests, Makefile, and the Python host driver |
| tb/ | Standalone SystemVerilog array testbench |
| ml/ | Bit-accurate INT8/ML reference models and tests |
| scripts/ | Complete checks, reference checks, and mutation testing |
| docs/ | Register map, dataflow, verification evidence, benchmark method, and design notes |
| formal/ | SymbiYosys formal properties |
| openlane/ | OpenLane/LibreLane configuration and constraints |
| constraints/ | Timing constraints |
| fpga/ | FPGA handoff material and platform notes |
| sw/ | Portable C interface and compile checks |

## Important design notes

- A is stored in feed order so each cycle can read a contiguous vector.
- Results remain in the PE accumulators; there is no separate result register file.
- irq is level-sensitive: DONE & IRQ_EN. Clear DONE with the STATUS write-one-to-clear bit.
- The legacy AXI4-Lite top handles one K-limited GEMM. The tiled/streaming path is intended for
  larger M/K/N workloads.
- Operand buffers are currently flip-flops. SRAM/BRAM mapping is a planned optimization for larger N.
- OpenLane/LibreLane configuration targets SkyWater 130 nm, but no PDK run or FPGA implementation
  result is claimed by this repository yet.

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
