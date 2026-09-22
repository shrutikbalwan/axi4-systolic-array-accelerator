"""cocotb 2.x regression for systolic_array alone (port of tb/tb_array.sv).

Drives the unskewed input contract directly and checks every element against
numpy, plus the settling cycle against the analytical K + 2N - 1.
"""

import os

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

N = int(os.environ.get("N", "4"))
IN_W, ACC_W = 8, 32


def to_flat(values, width):
    word = 0
    for i, v in enumerate(values):
        word |= (int(v) & ((1 << width) - 1)) << (i * width)
    return word


def read_c(dut):
    raw = dut.acc_flat.value.to_unsigned()
    c = np.zeros((N, N), dtype=np.int64)
    for r in range(N):
        for col in range(N):
            v = (raw >> ((r * N + col) * ACC_W)) & 0xFFFFFFFF
            c[r, col] = v - (1 << 32) if v & 0x80000000 else v
    return c


async def settle():
    """Sample after the edge's non-blocking updates."""
    await Timer(1, unit="ns")


async def run_gemm(dut, a, b):
    """Returns (C, first feed-relative cycle at which C was fully correct)."""
    k = a.shape[1]
    want = a @ b
    dut.en.value = 0
    dut.clr_acc.value = 1
    dut.flush.value = 1
    await RisingEdge(dut.clk)
    await settle()
    dut.clr_acc.value = 0
    dut.flush.value = 0
    dut.en.value = 1

    first_ok = None
    cyc = 0
    for step in range(k + 4 * N + 8):
        if step < k:
            dut.a_flat.value = to_flat(a[:, step], IN_W)
            dut.b_flat.value = to_flat(b[step, :], IN_W)
        else:
            dut.a_flat.value = 0
            dut.b_flat.value = 0
        await RisingEdge(dut.clk)
        await settle()
        cyc += 1
        if first_ok is None and np.array_equal(read_c(dut), want):
            first_ok = cyc
    dut.en.value = 0
    return read_c(dut), first_ok


@cocotb.test()
async def test_array_matches_numpy(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.en.value = 0
    dut.clr_acc.value = 0
    dut.flush.value = 0
    dut.a_flat.value = 0
    dut.b_flat.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await settle()

    rng = np.random.default_rng(12)
    cases = []
    for k in (1, N, 2 * N):
        for av, bv in ((-128, -128), (127, 127), (-128, 127), (127, -128)):
            cases.append((np.full((N, k), av, np.int64), np.full((k, N), bv, np.int64)))
    for _ in range(100):
        k = int(rng.integers(1, 2 * N + 1))
        cases.append((rng.integers(-128, 128, (N, k)), rng.integers(-128, 128, (k, N))))

    for i, (a, b) in enumerate(cases):
        c, first_ok = await run_gemm(dut, a, b)
        np.testing.assert_array_equal(c, a @ b, err_msg=f"case {i}")
        predicted = a.shape[1] + 2 * N - 1
        # Random data could match early by coincidence; never late.
        assert first_ok is not None and first_ok <= predicted, \
            f"case {i}: correct at cycle {first_ok}, predicted {predicted}"
        if i < 12:  # corner cases: no coincidences possible, must be exact
            assert first_ok == predicted, f"corner {i}: {first_ok} != {predicted}"

    dut._log.info("N=%d: %d GEMMs match numpy; settle = K + 2N - 1", N, len(cases))
