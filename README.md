# axi4-systolic-array-accelerator

A parameterised INT8 systolic-array GEMM accelerator with an AXI4-Lite control
and data interface, written in synthesisable SystemVerilog and verified with
cocotb 2.x and Verilator.

It computes `C = A x B` for `A` (N x K) and `B` (K x N), signed INT8 in, signed
INT32 out, `1 <= K <= KMAX`, on an N x N output-stationary array. `N` and `KMAX`
are parameters (`N` any multiple of 4); the defaults are `N = 4`, `KMAX = 16`.

```
              +----------------------------------------------------------------+
  aresetn --->| reset_sync  (async assert, sync release)                        |
              |                                                                |
  s_axi_* <-->| axi_lite_slave  --reg port-->  accel_ctrl                       |
              |  (bus adapter only)            - CTRL/STATUS/LEN/INFO/CYCLES   |
              |                                - A buffer (KMAX feed vectors)  |
              |                                - B buffer (KMAX feed vectors)  |
              |                                - FSM: IDLE>CLEAR>FEED>DRAIN     |
              |                                     |  a_flat   b_flat  ^ acc  |
              |                                     v          v        |      |
              |                   +---------------------------------------+   |
              |                   | systolic_array (N x N pe_mac)         |   |
              |      A, skewed -> | PE00 -> PE01 -> ... -> PE0(N-1)       |   |
              |      row r by r   |  |        |                           |   |
              |                   |  v        v       B, skewed col c by c|   |
              |                   | PE10 -> PE11 -> ...                   |   |
              |                   +---------------------------------------+   |
  irq <-------| DONE & IRQ_EN                                                  |
              +----------------------------------------------------------------+
```

## Status

| Item | State |
|---|---|
| RTL: lint (`verilator -Wall`, warnings fatal), N = 4, 8, 12, 16, 32 | clean; 3 inline, reasoned waivers |
| Array regression (SystemVerilog, Verilator), N = 2 ... 16 | passes; settling cycle = K + 2N - 1 exactly (see note on N = 2 below) |
| cocotb regression, Icarus **and** Verilator, N = 4, 8, 16 | passes (see below) |
| Mutation testing (20 seeded bugs, N = 4 and 8) | 20 / 20 killed |
| Yosys generic synthesis | elaborates, no latches |
| AXI4-Lite protocol | tested, **not formally proven** |
| OpenLane / LibreLane (sky130) | config and SDC written, **NOT RUN** (no PDK here) |
| FPGA | **NOT RUN** |

## Quick start

Needs Verilator (5.x), Icarus Verilog (12+), Yosys and Python with
`cocotb>=2.1`, `numpy`, `cocotbext-axi`. The simplest route is the
[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build), whose bundled
Python already has cocotb:

```sh
source oss-cad-suite/environment
tabbypip install numpy cocotbext-axi

scripts/run_checks.sh                 # everything CI runs
cd sim && make                        # top-level regression, Icarus, N=4
cd sim && make SIM=verilator N=8      # Verilator, 8x8 array
cd sim && make TB=array               # array-only regression
cd sim && make WAVES=1                # dump an FST waveform
```

Clone into a path without spaces (see [Known issues](#known-issues)).

## Using it

Register map, operand layout and responses: [`docs/register_map.md`](docs/register_map.md).

```
write A window (0x1000): A transposed, one byte per element (feed order)
write B window (0x2000): B row-major
write LEN    (0x008) = K
write CTRL   (0x000) = START | IRQ_EN
wait for irq            (or poll STATUS.DONE)
read  C window (0x3000): N*N signed 32-bit words, row-major
write STATUS (0x004) = DONE   (W1C)
```

`sim/accel_host.py` is this sequence as a small Python driver.

## How the array is scheduled

The derivation, the edge-skew table and the per-cycle PE activity map are in
[`docs/dataflow.md`](docs/dataflow.md). In short: row `r` of A is delayed `r`
cycles and column `c` of B `c` cycles, each by its own delay line, and each PE
hop is one register, so PE(r,c) sees `A[r][k]` and `B[k][c]` together at cycle
`k + r + c + 1`. The last MAC is at cycle `K + 2N - 2`, so the controller
drains for `2N - 1` cycles after the last feed cycle, and a run takes `K + 2N`
cycles from START to DONE (reported in the `CYCLES` register).

## Repository layout

```
rtl/          pe_mac, systolic_array, axi_lite_slave, accel_ctrl, reset_sync, systolic_accel_top
tb/           tb_array.sv - SystemVerilog array regression (Verilator)
sim/          cocotb tests (test_array.py, test_accel.py), host driver, Makefile
scripts/      run_checks.sh (what CI runs), mutants.py + run_mutants.sh
docs/         dataflow.md, register_map.md
constraints/  design.sdc
openlane/     config.json (LibreLane / OpenLane 2)
```

## Verification

Everything below was produced by `scripts/run_checks.sh` / `scripts/run_mutants.sh`
with OSS CAD Suite 2026-09-22 (Verilator 5.053, Icarus 14.0-devel, Yosys 0.69,
cocotb 2.1). Every result is checked against an external reference (numpy
`@` in Python, a behavioural model in SystemVerilog).

| Check | Result |
|---|---|
| `tb/tb_array.sv`, N/K = 2/2, 4/1, 4/4, 4/6, 4/9, 8/3, 8/8, 16/16 | 206/206 runs each (4 overflow corners, 200 random, 2 back-to-back); results correct first at cycle K + 2N - 1 in every configuration |
| `sim/test_array.py` (array alone), Icarus + Verilator, N = 4, 8, 16 | 112 GEMMs each, exact settle cycle on the corner cases |
| `sim/test_accel.py` (full AXI design), Icarus + Verilator, N = 4, 8, 16 | 13/13 tests; 108 end-to-end GEMMs per run (100 random K, plus -128/+127 corners, identity, zeros, K=1) |
| Yosys `synth -flatten` (generic cells), KMAX = 16, N = 4 / N = 8 | 21,136 / 77,628 cells; 2,053 / 5,734 flops (1,024 / 2,048 of them operand buffers); no latches |

The protocol tests drive the AXI signals directly: a master that raises BREADY
only after seeing BVALID (the original design deadlocked here), W before AW,
RREADY held low with a second AR (different ARADDR) queued behind it,
concurrent back-to-back writes, WSTRB on every lane, DECERR and SLVERR.

**Why the array is tested at N = 2 but the full design rejects it.** The
constraint "N * 8 must be a multiple of 32" belongs to the register map, not to
the array: `accel_ctrl` packs each feed vector into whole 32-bit AXI words.
`systolic_array` has no such constraint and is legal, and tested, at N = 2.
The full design (`systolic_accel_top`) refuses to elaborate at N = 2 on purpose.

**Flip-flop accounting.** 2,053 flops, in the **flattened** netlist, at
N = 4, KMAX = 16. Flattened and hierarchical counts differ, so the flow matters
when comparing: the hierarchical netlist reports 2,056.

| State | Flops |
|---|---|
| A and B operand buffers (2 x KMAX x N bytes) | 1,024 |
| 16 PEs: operand registers 16 x 16, accumulators 16 x 32 | 768 |
| Edge skew lines (A and B, depths 1 + 2 + 3) | 96 |
| AXI slave (AW/W holding registers, B/R response registers) | 87 |
| Controller (state, LEN, feed index/pointer, drain count, CYCLES, IRQ_EN, DONE, ERR) | 76 |
| Reset synchroniser | 2 |

There are no result registers; the C window reads the accumulators directly.
The 3 flops flattening removes are the two AW address LSBs (never used) and one
RRESP bit (reads return only OKAY or DECERR, so RRESP[0] always equals
RRESP[1]).

**Mutation testing.** `scripts/mutants.py` seeds 20 known bugs (the original
design's bugs among them) and `scripts/run_mutants.sh` checks the regression
catches each one, at N = 4 and N = 8.

The first run caught **19 of 20**. The survivor, M20 "soft reset leaves DONE
set", exposed a gap in the test suite, not a defect in the RTL: the soft-reset
test only aborted a run *in progress*, when DONE is already 0, so it could not
tell whether soft reset clears DONE. A case that soft-resets *after* a run has
completed (DONE and irq high) was added, and the score is now **20 / 20**.

The score is useful because it failed first. A suite that has never caught
anything has not been tested; this one missed a real hole, the hole was
closed, and the mutant that exposed it now stays in the list.

M18 (feed pointer steps one word regardless of N) is only detectable at N = 8:
at N = 4 a feed vector *is* one word, so there the mutant is equivalent. That
is why mutants run at two sizes.

## Design decisions worth knowing

* **Feed-order buffers.** A is stored transposed so each feed vector is `N`
  contiguous bytes; the controller streams them with an incrementing word
  pointer instead of a gather.
* **Results come straight from the accumulators.** They hold while the array is
  idle, so there is no separate N*N x 32 result register file.
* **Level-sensitive `irq`** (`DONE & IRQ_EN`), cleared by the W1C of DONE. A
  pulse can be missed by a level-triggered interrupt controller; a level cannot.
* **Errors are reported, not swallowed**: DECERR for unmapped addresses, SLVERR
  for writes to read-only registers or to the operands/LEN during a run,
  `STATUS.ERR` for an illegal START.
* **Illegal parameters stop elaboration** (`$fatal` in a generate block) in
  Icarus and Yosys. Verilator demotes `$fatal` to a warning under `-Wno-fatal`,
  so the lint gate never passes that flag.

## Known limits and next steps

* Operand storage is flip-flops; at N >= 16 it should become SRAM.
* One K-tile per run (K <= KMAX); no tiling controller for larger GEMMs.
* No AXI4 (full) DMA master: the host writes operands word by word over
  AXI4-Lite. Adding a burst DMA is the obvious next step (and what the repo
  name promises).
* No post-processing (bias, requantisation, ReLU).
* The result readback path is an N*N-to-1 multiplexer, 32 bits wide: 16:1 at
  N = 4, 256:1 at N = 16, 1024:1 at N = 32. It is a plausible critical path at
  large N. Static timing analysis will decide; nothing here has measured it.
* Physical flow not run: `openlane/config.json` targets LibreLane / OpenLane 2
  with sky130A / sky130_fd_sc_hd, but has not been validated against the tool.

## Known issues

* Verilator will not build under a filesystem path containing a space (its
  generated makefiles refuse to). Clone into a path without spaces. GitHub
  Actions runner paths (`/home/runner/work/...`) are unaffected.

## License

[Apache License 2.0](LICENSE).

There are no per-file license headers: a half-applied header convention is
worse than none. The LICENSE file covers the repository.
