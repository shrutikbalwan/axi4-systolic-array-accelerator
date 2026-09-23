"""cocotb 2.x regression for systolic_accel_top (the AXI4-Lite accelerator).

Phase 3 (bus/protocol): register access, WSTRB lanes, DECERR/SLVERR, W-before-AW,
back-to-back writes, RREADY held low, BREADY only after BVALID.
Phase 4 (end-to-end): GEMM against numpy, 100 randomized + corner matrices,
back-to-back runs, latency, sticky DONE / IRQ / ERR / soft reset.
"""

import random

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge
from cocotbext.axi import AxiLiteBus, AxiLiteMaster

from accel_host import (
    A_BASE, ACTIVE_CYCLES, B_BASE, C_BASE, CTRL, CTRL_CLR_ACC, CTRL_IRQ_EN, CTRL_SOFT_RST,
    CTRL_START, CYCLES, DECERR, INFO, LEN, OKAY, SLVERR, STATUS, STATUS_BUSY,
    STATUS_DONE, STATUS_ERR, MAC_COUNT_HI, MAC_COUNT_LO, WINDOW, Accel, params, reference,
)

N, KMAX = params()
CLK_NS = 10


async def reset(dut):
    dut.aresetn.value = 0
    for sig in ("awvalid", "wvalid", "bready", "arvalid", "rready"):
        getattr(dut, f"s_axi_{sig}").value = 0
    for sig in ("awaddr", "awprot", "wdata", "wstrb", "araddr", "arprot"):
        getattr(dut, f"s_axi_{sig}").value = 0
    for _ in range(5):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1
    for _ in range(5):  # reset_sync releases two edges later
        await RisingEdge(dut.aclk)


async def setup(dut):
    """Clock + reset + a cocotbext-axi master."""
    cocotb.start_soon(Clock(dut.aclk, CLK_NS, unit="ns").start())
    await reset(dut)
    master = AxiLiteMaster(AxiLiteBus.from_prefix(dut, "s_axi"), dut.aclk,
                           dut.aresetn, reset_active_level=False)
    return Accel(dut, master, N, KMAX)


async def setup_raw(dut):
    """Clock + reset only: the test drives the AXI signals itself."""
    cocotb.start_soon(Clock(dut.aclk, CLK_NS, unit="ns").start())
    await reset(dut)


def rand_int8(shape, rng):
    return rng.integers(-128, 128, size=shape, dtype=np.int64)  # high is exclusive


# ============================================================================
# Phase 3 - bus and register behaviour
# ============================================================================

@cocotb.test()
async def test_reset_values_and_info(dut):
    acc = await setup(dut)
    assert await acc.rd_ok(CTRL) == 0
    assert await acc.rd_ok(STATUS) == 0
    assert await acc.rd_ok(LEN) == 0
    assert await acc.rd_ok(CYCLES) == 0
    assert await acc.rd_ok(ACTIVE_CYCLES) == 0
    assert await acc.rd_ok(MAC_COUNT_LO) == 0
    assert await acc.rd_ok(MAC_COUNT_HI) == 0
    info = await acc.rd_ok(INFO)
    assert info & 0xFF == N, f"INFO.N = {info & 0xFF}, build N = {N}"
    assert (info >> 8) & 0xFF == 8
    assert info >> 16 == KMAX


@cocotb.test()
async def test_register_rw_and_wstrb(dut):
    acc = await setup(dut)

    # LEN: full write, then byte-lane writes
    await acc.wr_ok(LEN, 0x0304)
    assert await acc.rd_ok(LEN) == 0x0304
    await acc.m.write(LEN, b"\x05")            # lane 0 only
    assert await acc.rd_ok(LEN) == 0x0305
    await acc.m.write(LEN + 1, b"\x07")        # lane 1 only
    assert await acc.rd_ok(LEN) == 0x0705
    await acc.m.write(LEN + 2, b"\xff\xff")    # lanes 2-3: no bits there
    assert await acc.rd_ok(LEN) == 0x0705

    # Operand buffers: every lane independently
    for base in (A_BASE, B_BASE):
        await acc.wr_ok(base + 4, 0x11223344)
        await acc.m.write(base + 4 + 1, b"\xaa")
        assert await acc.rd_ok(base + 4) == 0x1122AA44
        await acc.m.write(base + 4 + 3, b"\xbb")
        assert await acc.rd_ok(base + 4) == 0xBB22AA44
        await acc.m.write(base + 4 + 0, b"\xcc\xdd")
        assert await acc.rd_ok(base + 4) == 0xBB22DDCC

    # CTRL: IRQ_EN is the only stored bit; START etc. read back as 0
    await acc.wr_ok(CTRL, CTRL_IRQ_EN)
    assert await acc.rd_ok(CTRL) == CTRL_IRQ_EN
    await acc.wr_ok(CTRL, 0)
    assert await acc.rd_ok(CTRL) == 0


@cocotb.test()
async def test_decerr_and_slverr(dut):
    acc = await setup(dut)
    buf_bytes = KMAX * N
    unmapped = [0x0014, 0x0100, 0x0FFC]
    if buf_bytes < WINDOW:
        unmapped += [A_BASE + buf_bytes, B_BASE + buf_bytes, B_BASE + WINDOW - 4]
    if 4 * N * N < WINDOW:
        unmapped += [C_BASE + 4 * N * N, C_BASE + WINDOW - 4]

    for addr in unmapped:
        value, resp = await acc.rd(addr)
        assert resp == DECERR, f"read 0x{addr:04x}: resp {resp}, want DECERR"
        assert value == 0
        resp = await acc.wr(addr, 0xDEADBEEF)
        assert resp == DECERR, f"write 0x{addr:04x}: resp {resp}, want DECERR"

    # Read-only registers reject writes and are unchanged
    info = await acc.rd_ok(INFO)
    for addr in (INFO, CYCLES, ACTIVE_CYCLES, MAC_COUNT_LO, MAC_COUNT_HI,
                 C_BASE, C_BASE + 4 * (N * N - 1)):
        resp = await acc.wr(addr, 0x12345678)
        assert resp == SLVERR, f"write to RO 0x{addr:04x}: resp {resp}, want SLVERR"
    assert await acc.rd_ok(INFO) == info
    assert await acc.rd_ok(CYCLES) == 0
    assert await acc.rd_ok(C_BASE) == 0


@cocotb.test()
async def test_back_to_back_writes(dut):
    """Many writes issued concurrently: every one must land exactly once."""
    acc = await setup(dut)
    rng = random.Random(1)
    words = min(KMAX * N // 4, 32)
    values = {A_BASE + 4 * i: rng.getrandbits(32) for i in range(words)}
    values.update({B_BASE + 4 * i: rng.getrandbits(32) for i in range(words)})

    tasks = [cocotb.start_soon(acc.wr(a, v)) for a, v in values.items()]
    for t in tasks:
        assert await t == OKAY
    for addr, v in values.items():
        assert await acc.rd_ok(addr) == v, f"0x{addr:04x}"


# ---- raw-signal protocol tests (no cocotbext-axi: exact control of READYs) --

async def edge(dut):
    await RisingEdge(dut.aclk)


async def raw_handshake(dut, valid, ready, max_cycles=20):
    """Hold VALID until the edge on which READY is also high, then drop it."""
    valid.value = 1
    for _ in range(max_cycles):
        await edge(dut)
        if ready.value == 1:  # sampled at this edge = handshake at this edge
            valid.value = 0
            return
    raise AssertionError(f"{ready._name} never asserted")


@cocotb.test()
async def test_bready_only_after_bvalid(dut):
    """A master that waits for BVALID before raising BREADY must not deadlock
    (the original design gated BVALID on BREADY)."""
    await setup_raw(dut)
    dut.s_axi_bready.value = 0
    dut.s_axi_awaddr.value = LEN
    dut.s_axi_wdata.value = 9
    dut.s_axi_wstrb.value = 0xF
    await raw_handshake(dut, dut.s_axi_awvalid, dut.s_axi_awready)
    await raw_handshake(dut, dut.s_axi_wvalid, dut.s_axi_wready)

    for _ in range(20):
        await edge(dut)
        if dut.s_axi_bvalid.value == 1:
            break
    else:
        raise AssertionError("BVALID never asserted while BREADY was low: deadlock")

    # BVALID must now hold, stable, until BREADY
    for _ in range(5):
        await edge(dut)
        assert dut.s_axi_bvalid.value == 1
        assert dut.s_axi_bresp.value == OKAY
    dut.s_axi_bready.value = 1
    await edge(dut)                      # handshake edge
    dut.s_axi_bready.value = 0
    await edge(dut)
    assert dut.s_axi_bvalid.value == 0

    # And the write really happened (read it back raw)
    dut.s_axi_araddr.value = LEN
    dut.s_axi_rready.value = 1
    await raw_handshake(dut, dut.s_axi_arvalid, dut.s_axi_arready)
    await ReadOnly()
    assert dut.s_axi_rvalid.value == 1
    assert dut.s_axi_rdata.value.to_unsigned() == 9


@cocotb.test()
async def test_w_before_aw(dut):
    """W may arrive before AW (AXI allows either order)."""
    await setup_raw(dut)
    dut.s_axi_bready.value = 1
    dut.s_axi_wdata.value = 0x0B
    dut.s_axi_wstrb.value = 0xF
    await raw_handshake(dut, dut.s_axi_wvalid, dut.s_axi_wready)
    for _ in range(4):
        await edge(dut)
        assert dut.s_axi_bvalid.value == 0, "BVALID before the AW beat"
    dut.s_axi_awaddr.value = LEN
    await raw_handshake(dut, dut.s_axi_awvalid, dut.s_axi_awready)
    for _ in range(10):
        await edge(dut)
        if dut.s_axi_bvalid.value == 1:
            break
    else:
        raise AssertionError("no write response")
    dut.s_axi_araddr.value = LEN
    dut.s_axi_rready.value = 1
    await raw_handshake(dut, dut.s_axi_arvalid, dut.s_axi_arready)
    await ReadOnly()
    assert dut.s_axi_rdata.value.to_unsigned() == 0x0B


@cocotb.test()
async def test_rready_low_and_araddr_changes(dut):
    """RVALID/RDATA hold while RREADY is low; a second AR (with a different
    ARADDR) is back-pressured and must not disturb the pending RDATA."""
    await setup_raw(dut)
    dut.s_axi_bready.value = 1
    # Put a known value in LEN first
    dut.s_axi_awaddr.value = LEN
    dut.s_axi_wdata.value = 0x0123
    dut.s_axi_wstrb.value = 0xF
    dut.s_axi_awvalid.value = 1
    dut.s_axi_wvalid.value = 1
    for _ in range(10):
        await edge(dut)
        if dut.s_axi_awready.value == 1:
            dut.s_axi_awvalid.value = 0
        if dut.s_axi_wready.value == 1:
            dut.s_axi_wvalid.value = 0
        if dut.s_axi_bvalid.value == 1:
            break
    await edge(dut)

    dut.s_axi_rready.value = 0
    dut.s_axi_araddr.value = LEN
    await raw_handshake(dut, dut.s_axi_arvalid, dut.s_axi_arready)
    # Present a second read to a different register immediately
    dut.s_axi_araddr.value = INFO
    dut.s_axi_arvalid.value = 1
    for _ in range(6):
        await edge(dut)
        assert dut.s_axi_rvalid.value == 1
        assert dut.s_axi_rdata.value.to_unsigned() == 0x0123, "RDATA followed live ARADDR"
        assert dut.s_axi_arready.value == 0, "accepted a 2nd AR with a response pending"

    dut.s_axi_rready.value = 1
    await edge(dut)                      # R handshake for the LEN read
    assert dut.s_axi_rvalid.value == 1 and dut.s_axi_arready.value == 0
    await raw_handshake(dut, dut.s_axi_arvalid, dut.s_axi_arready)  # 2nd AR accepted
    for _ in range(5):
        await edge(dut)
        if dut.s_axi_rvalid.value == 1:
            break
    else:
        raise AssertionError("second read never returned")
    assert dut.s_axi_rdata.value.to_unsigned() == (KMAX << 16) | (8 << 8) | N


# ============================================================================
# Phase 4 - end-to-end GEMM
# ============================================================================

def corner_cases(rng):
    k = KMAX
    yield "all -128", np.full((N, k), -128), np.full((k, N), -128)
    yield "all +127", np.full((N, k), 127), np.full((k, N), 127)
    yield "-128 x +127", np.full((N, k), -128), np.full((k, N), 127)
    yield "+127 x -128", np.full((N, k), 127), np.full((k, N), -128)
    yield "zeros", np.zeros((N, k), int), np.zeros((k, N), int)
    if N <= KMAX:
        eye = np.eye(N, dtype=int)
        m = rand_int8((N, N), rng)
        yield "I x M", eye, m
        yield "M x I", m, eye
    yield "K=1", rand_int8((N, 1), rng), rand_int8((1, N), rng)


@cocotb.test()
async def test_gemm_regression(dut):
    acc = await setup(dut)
    rng = np.random.default_rng(2026)
    runs = 0

    for name, a, b in corner_cases(rng):
        c = await acc.gemm(a, b)
        np.testing.assert_array_equal(c, reference(a, b), err_msg=name)
        runs += 1

    for trial in range(100):
        k = int(rng.integers(1, KMAX + 1))
        a = rand_int8((N, k), rng)
        b = rand_int8((k, N), rng)
        c = await acc.gemm(a, b)
        np.testing.assert_array_equal(c, reference(a, b), err_msg=f"trial {trial} K={k}")
        runs += 1

    assert await acc.rd_ok(STATUS) & STATUS_ERR == 0
    dut._log.info("N=%d KMAX=%d: %d GEMMs match numpy", N, KMAX, runs)


@cocotb.test()
async def test_back_to_back_runs_do_not_accumulate(dut):
    acc = await setup(dut)
    rng = np.random.default_rng(7)
    a1, b1 = rand_int8((N, KMAX), rng), rand_int8((KMAX, N), rng)
    a2, b2 = rand_int8((N, 3), rng), rand_int8((3, N), rng)
    np.testing.assert_array_equal(await acc.gemm(a1, b1), reference(a1, b1))
    # Second run: shorter K, without clearing anything by hand
    np.testing.assert_array_equal(await acc.gemm(a2, b2), reference(a2, b2))
    # Same operands again: must be identical, not doubled
    await acc.start()
    await acc.wait_irq(200)
    np.testing.assert_array_equal(await acc.read_c(), reference(a2, b2))


@cocotb.test()
async def test_latency_matches_schedule(dut):
    """CYCLES = 1 (CLEAR) + K (FEED) + 2N-1 (DRAIN) = K + 2N."""
    acc = await setup(dut)
    rng = np.random.default_rng(3)
    for k in sorted({1, 2, KMAX // 2 or 1, KMAX}):
        a, b = rand_int8((N, k), rng), rand_int8((k, N), rng)
        await acc.gemm(a, b)
        cycles = await acc.rd_ok(CYCLES)
        assert cycles == k + 2 * N, f"K={k}: CYCLES={cycles}, want {k + 2 * N}"
        perf = await acc.performance()
        assert perf["active_cycles"] == k + 2 * N - 1
        assert perf["mac_count"] == N * N * k


@cocotb.test()
async def test_done_sticky_w1c_and_irq(dut):
    acc = await setup(dut)
    rng = np.random.default_rng(4)
    a, b = rand_int8((N, 2), rng), rand_int8((2, N), rng)
    await acc.load(a, b)

    # IRQ disabled: DONE rises, irq stays low
    await acc.start(irq_en=False)
    for _ in range(3 * (2 + 2 * N) + 20):
        await RisingEdge(dut.aclk)
        assert dut.irq.value == 0
    status = await acc.rd_ok(STATUS)
    assert status & STATUS_DONE and not status & STATUS_BUSY

    # DONE is sticky: still set much later, and writing 0 does not clear it
    for _ in range(50):
        await RisingEdge(dut.aclk)
    await acc.wr_ok(STATUS, 0)
    assert await acc.rd_ok(STATUS) & STATUS_DONE

    # Enabling IRQ with DONE pending raises irq (level-sensitive)
    await acc.wr_ok(CTRL, CTRL_IRQ_EN)
    await RisingEdge(dut.aclk)
    assert dut.irq.value == 1

    # W1C clears DONE and drops irq
    await acc.wr_ok(STATUS, STATUS_DONE)
    assert await acc.rd_ok(STATUS) & STATUS_DONE == 0
    assert dut.irq.value == 0


@cocotb.test()
async def test_errors_and_locking(dut):
    acc = await setup(dut)
    rng = np.random.default_rng(5)

    # START with LEN = 0 and LEN > KMAX: ERR, no run
    for bad in (0, KMAX + 1):
        await acc.wr_ok(LEN, bad)
        await acc.start()
        status = await acc.rd_ok(STATUS)
        assert status & STATUS_ERR, f"LEN={bad} accepted"
        assert not status & (STATUS_BUSY | STATUS_DONE)
        await acc.wr_ok(STATUS, STATUS_ERR)
        assert await acc.rd_ok(STATUS) & STATUS_ERR == 0

    # A long run, then poke it while BUSY
    a, b = rand_int8((N, KMAX), rng), rand_int8((KMAX, N), rng)
    await acc.load(a, b)
    await acc.start()
    assert await acc.rd_ok(STATUS) & STATUS_BUSY, "run too short to test BUSY locking"
    assert await acc.wr(A_BASE, 0) == SLVERR
    assert await acc.wr(B_BASE, 0) == SLVERR
    assert await acc.wr(LEN, 1) == SLVERR
    await acc.wr_ok(CTRL, CTRL_START | CTRL_IRQ_EN)   # START while BUSY
    await acc.wait_irq(4 * (KMAX + 2 * N) + 100)
    status = await acc.rd_ok(STATUS)
    assert status & STATUS_ERR, "START while BUSY not flagged"
    assert await acc.rd_ok(LEN) == KMAX
    # The rejected writes changed nothing, so the result is still right
    np.testing.assert_array_equal(await acc.read_c(), reference(a, b))


@cocotb.test()
async def test_soft_reset_and_clr_acc(dut):
    acc = await setup(dut)
    rng = np.random.default_rng(6)
    a, b = rand_int8((N, KMAX), rng), rand_int8((KMAX, N), rng)
    await acc.load(a, b)
    await acc.start()
    await acc.wr_ok(CTRL, CTRL_SOFT_RST)               # abort mid-run
    status = await acc.rd_ok(STATUS)
    assert status & (STATUS_BUSY | STATUS_DONE | STATUS_ERR) == 0
    c = await acc.read_c()
    assert not c.any(), "soft reset did not clear the accumulators"

    # Buffers and LEN survive a soft reset; a fresh run is correct
    assert await acc.rd_ok(LEN) == KMAX
    await acc.start()
    await acc.wait_irq(4 * (KMAX + 2 * N) + 100)
    np.testing.assert_array_equal(await acc.read_c(), reference(a, b))

    # Soft reset after completion clears a pending DONE (and so irq) and ERR
    assert await acc.rd_ok(STATUS) & STATUS_DONE
    assert dut.irq.value == 1
    await acc.wr_ok(LEN, 0)
    await acc.start()                                  # bad LEN -> ERR
    assert await acc.rd_ok(STATUS) & STATUS_ERR
    await acc.wr_ok(CTRL, CTRL_SOFT_RST)
    assert await acc.rd_ok(STATUS) & (STATUS_DONE | STATUS_ERR) == 0
    assert dut.irq.value == 0

    # CLR_ACC while idle zeroes the results
    await acc.wr_ok(LEN, KMAX)
    await acc.start()
    await acc.wait_irq(4 * (KMAX + 2 * N) + 100)
    assert (await acc.read_c()).any()
    await acc.wr_ok(CTRL, CTRL_CLR_ACC)
    assert not (await acc.read_c()).any()
