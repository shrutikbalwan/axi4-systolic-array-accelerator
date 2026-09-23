# Register map

AXI4-Lite slave, 32-bit data, 14-bit byte address (16 KiB), four 4 KiB windows.
Values below are for the default build (`N = 4`, `KMAX = 16`); every size is
derived from the parameters in `rtl/accel_ctrl.sv`, and software can discover
them at run time from `INFO`.

| Window | Base     | Contents                                  | Size (default)          |
|--------|----------|-------------------------------------------|-------------------------|
| REGS   | `0x0000` | control / status registers                | 5 registers             |
| A      | `0x1000` | activation buffer, feed order, INT8       | `N*KMAX` bytes = 64 B   |
| B      | `0x2000` | weight buffer, feed order, INT8           | `KMAX*N` bytes = 64 B   |
| C      | `0x3000` | results, INT32, read-only                 | `N*N` words = 64 B      |

## Responses

| Access                                                       | Response       |
|--------------------------------------------------------------|----------------|
| mapped register or in-range buffer/result word               | `OKAY` (00)    |
| write to a read-only register (`INFO`, `CYCLES`, C window)   | `SLVERR` (10)  |
| write to `LEN`, the A window or the B window while `BUSY`    | `SLVERR` (10), no effect |
| anything else (holes in REGS, past the end of a window)      | `DECERR` (11), reads return 0 |

`AWPROT`/`ARPROT` are accepted and ignored. Address bits `[1:0]` are ignored;
byte selection is by `WSTRB`, which is honoured on every writable byte.

## Registers

### `0x000` CTRL

| Bit | Name     | Access | Meaning |
|-----|----------|--------|---------|
| 0   | START    | W1P    | Start a run. Ignored and sets `STATUS.ERR` if `BUSY` or if `LEN` is not in `1..KMAX`. Clears `DONE`. |
| 1   | CLR_ACC  | W1P    | Zero the accumulators (and so the C window). Ignored and sets `ERR` if `BUSY`. |
| 2   | SOFT_RST | W1P    | Abort any run: FSM to idle, pipeline flushed, accumulators zeroed, `DONE`/`ERR` cleared. `LEN`, `IRQ_EN` and the buffers are kept. |
| 3   | IRQ_EN   | RW     | `irq = STATUS.DONE & IRQ_EN`. |

W1P bits always read as 0. Every write to CTRL (with `WSTRB[0]` set) also
writes `IRQ_EN`, so write it together with START.

### `0x004` STATUS

| Bit | Name | Access | Meaning |
|-----|------|--------|---------|
| 0   | BUSY | RO     | A run is in progress. |
| 1   | DONE | W1C    | Set when a run completes; sticky until written with 1 (or a new START). |
| 2   | ERR  | W1C    | Set by START with a bad `LEN`, or START/CLR_ACC while `BUSY`. |

A set event wins over a clear in the same cycle.

### `0x008` LEN (RW, bits 15:0)

Inner dimension `K` of the next run: FEED lasts `LEN` cycles. Legal values
`1..KMAX`. Locked (SLVERR) while `BUSY`.

### `0x00C` INFO (RO)

`[7:0] = N`, `[15:8] = 8` (input width), `[31:16] = KMAX`.

### `0x010` CYCLES (RO)

Clock cycles from START to DONE of the most recent run. Always `K + 2N`
(1 CLEAR + K FEED + 2N-1 DRAIN); the regression checks this.

## Operand layout (feed order)

The array consumes one column of A and one row of B per cycle, so both
buffers are stored as a sequence of **feed vectors**: vector `k` is `N` bytes,
the operands for feed cycle `k`, at byte offset `k*N` of its window.

```
A window byte (k*N + r) = A[r][k]      A is N x K; this is A transposed, row-major
B window byte (k*N + c) = B[k][c]      B is K x N; this is B row-major
C window word (r*N + c) = C[r][c]      C is N x N, signed INT32
```

In numpy: `a_bytes = A.T.astype(np.int8).tobytes()`, `b_bytes = B.astype(np.int8).tobytes()`,
`C = np.frombuffer(c_bytes, "<i4").reshape(N, N)`. Bytes are little-endian within
each word, so feed vector `k` of an `N = 4` build is exactly one word.

## Software sequence

```
write A window (K*N bytes), B window (K*N bytes)
write LEN   = K
write CTRL  = START | IRQ_EN
wait for irq            (or poll STATUS.DONE)
read  C window (N*N words)
write STATUS = DONE     (W1C; drops irq)
```

Results stay valid until the next START, CLR_ACC or SOFT_RST. Buffers keep
their contents, so re-running with the same operands only needs START.

> **Read all N*N result words before the next START.** The CLEAR cycle that
> follows every accepted START zeroes the accumulators, and the C window reads the
> accumulators directly; there is no separate result copy. The
> START-while-BUSY guard (`STATUS.ERR`) does **not** protect against this: once
> a run has finished the core is IDLE, so a new START is legal and silently
> discards the unread results.

## Timing note: result readback

A C-window read selects one of `N*N` accumulators with a 32-bit multiplexer:
16:1 at N = 4, 256:1 at N = 16, 1024:1 at N = 32. At large N this is a
plausible critical path (address decode to `RDATA` register). Static timing
analysis will decide; it has not been run (see the README). If it fails, the
fix is to pipeline the read (the AXI slave already registers RDATA, so one more
stage costs one cycle of read latency).
