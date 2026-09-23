# Dataflow and schedule

This is the timing argument the RTL implements. It was derived before the RTL
was written, and the regressions check that the RTL agrees with it (both the
results and the exact cycle on which they become correct).

## The rule

Output-stationary: `C[r][c]` accumulates in PE(r,c). A enters from the west,
one row of the array per row of A; B enters from the north, one column of the
array per column of B. Each PE registers its operands and passes them on (A
east, B south), so **every hop costs exactly one cycle**.

* Row `r` of A is delayed `r` cycles at the west edge.
* Column `c` of B is delayed `c` cycles at the north edge.

If `A[r][k]` enters the west edge at cycle `tA`, it is resident in PE(r,c) at
`tA + 1 + c`. If `B[k][c]` enters the north edge at `tB`, it is resident in
PE(r,c) at `tB + 1 + r`. They meet only if `tA - tB = r - c`.

The driver presents column `k` of A and row `k` of B together on feed cycle
`k`. After the edge delays, `tA = k + r` and `tB = k + c`, so
`tA - tB = r - c` for **every** `r`, `c`, `k`. PE(r,c) therefore holds the pair
`(A[r][k], B[k][c])` during cycle `k + r + c + 1` and adds its product on the
edge that ends that cycle.

The delays have to be per row and per column, and each delay line has to be
fed by its own input. Chaining row `r`'s line off row `r-1`'s (the original
bug) makes every row replay row 0.

## Latency

The last product lands in PE(N-1,N-1) for `k = K-1`, on the edge ending cycle
`(K-1) + 2(N-1) + 1 = K + 2N - 2`. Feed cycles are `0 .. K-1`, so after the
last feed cycle the array must keep running (with zero inputs) for

```
DRAIN = 2N - 1 = 2N - 2 + PE_LATENCY      (PE_LATENCY = 1: the operand register)
```

cycles. The FSM spends one CLEAR cycle first, so a run takes `K + 2N` cycles
from START to DONE, which is what `CYCLES` reports.

| Where it shows up                    | Value                    |
|--------------------------------------|--------------------------|
| `accel_ctrl.sv` `DRAIN_CYCLES`       | `2*N - 2 + PE_LATENCY`   |
| `CYCLES` register after a run        | `K + 2N`                 |
| first cycle results are all correct  | `K + 2N - 1` (feed cycle 0 = 0) |

`tb/tb_array.sv` and `sim/test_array.py` measure the third row directly;
`sim/test_accel.py::test_latency_matches_schedule` checks the second.

## Edge skew (N = 4, K = 4)

What enters the array boundary each cycle. `·` = zero.

| cycle | W row 0 | W row 1 | W row 2 | W row 3 | N col 0 | N col 1 | N col 2 | N col 3 |
|------:|---------|---------|---------|---------|---------|---------|---------|---------|
| 0 | A00 | · | · | · | B00 | · | · | · |
| 1 | A01 | A10 | · | · | B10 | B01 | · | · |
| 2 | A02 | A11 | A20 | · | B20 | B11 | B02 | · |
| 3 | A03 | A12 | A21 | A30 | B30 | B21 | B12 | B03 |
| 4 | · | A13 | A22 | A31 | · | B31 | B22 | B13 |
| 5 | · | · | A23 | A32 | · | · | B32 | B23 |
| 6 | · | · | · | A33 | · | · | · | B33 |

## PE activity (N = 4, K = 4)

Each grid is the array during one cycle; the number is the `k` of the pair
being accumulated. The active set sweeps as an anti-diagonal wavefront.

```
cycle 1      cycle 2      cycle 3      cycle 4      cycle 5
0 . . .      1 0 . .      2 1 0 .      3 2 1 0      . 3 2 1
. . . .      0 . . .      1 0 . .      2 1 0 .      3 2 1 0
. . . .      . . . .      0 . . .      1 0 . .      2 1 0 .
. . . .      . . . .      . . . .      0 . . .      1 0 . .

cycle 6      cycle 7      cycle 8      cycle 9      cycle 10 (last MAC)
. . 3 2      . . . 3      . . . .      . . . .      . . . .
. 3 2 1      . . 3 2      . . . 3      . . . .      . . . .
3 2 1 0      . 3 2 1      . . 3 2      . . . 3      . . . .
2 1 0 .      3 2 1 0      . 3 2 1      . . 3 2      . . . 3
```

Last MAC at cycle 10 = `K + 2N - 2`; results readable from cycle 11 = `K + 2N - 1`.

## Controller timeline

```
          START
            |
 IDLE ----> CLEAR ----> FEED (K cycles) ----> DRAIN (2N-1 cycles) ----> IDLE, DONE=1
            clr_acc     en=1, vector k        en=1, zeros
            flush       from A/B buffers
```

The accumulators hold their values while `en = 0`, so the C window reads them
directly. Nothing is copied into a separate result register file, which saves
`N*N*32` flops.
