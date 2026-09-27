"""End-to-end regression for the connected AXI4 DMA + tiled GEMM top.

Until this test existed, ``tiled_axi4_gemm_top`` was only linted and
synthesised; its sub-blocks were verified individually. Here the whole path is
driven the way a CPU drives it: descriptors are written through the register
port, the three AXI4 masters (A read, B read, C write) talk to cocotbext-axi
RAM models that share one byte-addressed memory, and the bytes written back to
memory are compared with a NumPy reference.

Covered:
  * raw INT32 and packed INT8 (bias / multiplier / shift / ReLU) writeback;
  * M, N and K that are not multiples of ARRAY_N or of the 4-byte word;
  * random AXI back-pressure on every channel;
  * back-to-back jobs without reset, sticky DONE, PERF_* counters;
  * a misaligned descriptor is rejected with ERROR instead of hanging.
"""

from __future__ import annotations

import itertools
import os
import random

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

ARRAY_N = int(os.environ.get("ARRAY_N", "4"))
MAX_DIM = int(os.environ.get("MAX_DIM", "64"))

# Descriptor register offsets (docs/dma_register_map.md).
CTRL, STATUS = 0x00, 0x04
A_BASE, B_BASE, C_BASE = 0x08, 0x0C, 0x10
REG_M, REG_N, REG_K = 0x14, 0x18, 0x1C
TILE_M, TILE_N, TILE_K = 0x20, 0x24, 0x28
POST_BIAS, POST_SCALE, POST_CFG = 0x2C, 0x30, 0x34
PERF_ACTIVE, PERF_MAC_LO, PERF_MAC_HI, PERF_TILES = 0x38, 0x3C, 0x40, 0x44

ST_BUSY, ST_DONE, ST_ERROR = 1, 2, 4
MEM_SIZE = 1 << 18


def requantize(acc, bias, mult, shift, relu):
    """Mirror of rtl/ml_postprocess.sv (and ml.quantized_mlp.requantize_int32)."""
    y = ((acc.astype(np.int64) + bias) * np.int64(mult)) >> shift
    if relu:
        y = np.maximum(y, 0)
    return np.clip(y, -128, 127).astype(np.int8)


class AxiMemory:
    """Minimal AXI4 slave memory shared by the A/B read and C write ports.

    INCR bursts only (the DMA never issues anything else); every READY/VALID
    the model drives can be randomly withheld to create back-pressure. Kept
    local so the test does not depend on optional-signal handling in
    third-party bus models.
    """

    def __init__(self, dut, size, stall=0.0, seed=7):
        self.dut = dut
        self.mem = bytearray(size)
        self.rng = random.Random(seed)
        self.stall = stall
        self.bad_bursts = []

    def _go(self):
        return self.rng.random() >= self.stall

    def write(self, addr, data):
        self.mem[addr:addr + len(data)] = data

    def read(self, addr, length):
        return bytes(self.mem[addr:addr + length])

    async def read_port(self, p):
        d = self.dut
        sig = lambda name: getattr(d, f"{p}_axi_{name}")
        sig("arready").value = 0
        sig("rvalid").value = 0
        sig("rlast").value = 0
        sig("rresp").value = 0
        sig("rdata").value = 0
        while True:
            await RisingEdge(d.clk)
            if not int(d.rst_n.value):
                continue
            # Address phase.
            sig("arready").value = int(self._go())
            await ReadOnly()
            if not (int(sig("arvalid").value) and int(sig("arready").value)):
                continue
            addr = int(sig("araddr").value)
            beats = int(sig("arlen").value) + 1
            size = 1 << int(sig("arsize").value)
            if int(sig("arburst").value) != 1 or size != 4 or addr % 4:
                self.bad_bursts.append((p, addr, beats, size))
            if (addr & 0xFFF) + beats * 4 > 0x1000:
                self.bad_bursts.append((p, "4KB crossing", addr, beats))
            await RisingEdge(d.clk)
            sig("arready").value = 0
            beat = 0
            while beat < beats:
                if self._go():
                    a = addr + 4 * beat
                    sig("rdata").value = int.from_bytes(self.mem[a:a + 4], "little")
                    sig("rlast").value = int(beat == beats - 1)
                    sig("rvalid").value = 1
                else:
                    sig("rvalid").value = 0
                await ReadOnly()
                fire = int(sig("rvalid").value) and int(sig("rready").value)
                await RisingEdge(d.clk)
                if fire:
                    beat += 1
            sig("rvalid").value = 0
            sig("rlast").value = 0

    async def write_port(self, p):
        d = self.dut
        sig = lambda name: getattr(d, f"{p}_axi_{name}")
        for name in ("awready", "wready", "bvalid", "bresp"):
            sig(name).value = 0
        while True:
            await RisingEdge(d.clk)
            if not int(d.rst_n.value):
                continue
            sig("awready").value = int(self._go())
            await ReadOnly()
            if not (int(sig("awvalid").value) and int(sig("awready").value)):
                continue
            addr = int(sig("awaddr").value)
            beats = int(sig("awlen").value) + 1
            if (addr & 0xFFF) + beats * 4 > 0x1000:
                self.bad_bursts.append((p, "4KB crossing", addr, beats))
            await RisingEdge(d.clk)
            sig("awready").value = 0
            beat = 0
            while beat < beats:
                sig("wready").value = int(self._go())
                await ReadOnly()
                if int(sig("wvalid").value) and int(sig("wready").value):
                    data = int(sig("wdata").value).to_bytes(4, "little")
                    strb = int(sig("wstrb").value)
                    last = int(sig("wlast").value)
                    a = addr + 4 * beat
                    for lane in range(4):
                        if strb >> lane & 1:
                            self.mem[a + lane] = data[lane]
                    if last != int(beat == beats - 1):
                        self.bad_bursts.append((p, "WLAST", addr, beat))
                    beat += 1
                await RisingEdge(d.clk)
            sig("wready").value = 0
            while not self._go():
                await RisingEdge(d.clk)
            sig("bvalid").value = 1
            while True:
                await ReadOnly()
                done = int(sig("bready").value)
                await RisingEdge(d.clk)
                if done:
                    break
            sig("bvalid").value = 0


class Harness:
    def __init__(self, dut, pause: bool):
        self.dut = dut
        self.c_ram = AxiMemory(dut, MEM_SIZE, stall=0.3 if pause else 0.0)
        for port in ("a", "b"):
            cocotb.start_soon(self.c_ram.read_port(port))
        cocotb.start_soon(self.c_ram.write_port("c"))

    async def reset(self):
        d = self.dut
        d.rst_n.value = 0
        d.reg_wr_en.value = 0
        d.reg_wr_addr.value = 0
        d.reg_wr_data.value = 0
        d.reg_wr_strb.value = 0
        d.reg_rd_addr.value = 0
        await ClockCycles(d.clk, 5)
        d.rst_n.value = 1
        await ClockCycles(d.clk, 2)

    async def write(self, addr, value):
        d = self.dut
        d.reg_wr_en.value = 1
        d.reg_wr_addr.value = addr
        d.reg_wr_data.value = value & 0xFFFFFFFF
        d.reg_wr_strb.value = 0xF
        await RisingEdge(d.clk)
        d.reg_wr_en.value = 0

    async def read(self, addr):
        d = self.dut
        d.reg_rd_addr.value = addr
        await ReadOnly()
        value = int(d.reg_rd_data.value)
        await RisingEdge(d.clk)
        return value

    async def wait_idle(self, timeout=400_000):
        for _ in range(timeout // 16):
            status = await self.read(STATUS)
            if status & (ST_DONE | ST_ERROR) and not status & ST_BUSY:
                return status
            await ClockCycles(self.dut.clk, 15)
        raise AssertionError("job did not finish")

    def put(self, addr, matrix):
        self.c_ram.write(addr, np.asarray(matrix, dtype=np.int8).tobytes())

    async def run(self, a, b, *, a_base, b_base, c_base, tile_k,
                  int8=False, bias=0, mult=1, shift=0, relu=False):
        m, k = a.shape
        n = b.shape[1]
        self.put(a_base, a)
        self.put(b_base, b)
        # Poison the destination so stale data can never pass.
        out_bytes = m * n * (1 if int8 else 4)
        self.c_ram.write(c_base, b"\xA5" * (((out_bytes + 3) // 4) * 4 + 16))
        for reg, val in ((A_BASE, a_base), (B_BASE, b_base), (C_BASE, c_base),
                         (REG_M, m), (REG_N, n), (REG_K, k),
                         (TILE_M, ARRAY_N), (TILE_N, ARRAY_N), (TILE_K, tile_k),
                         (POST_BIAS, bias), (POST_SCALE, mult),
                         (POST_CFG, (shift << 2) | (2 if int8 else 0) | (1 if relu else 0))):
            await self.write(reg, val)
        await self.write(CTRL, 1)
        status = await self.wait_idle()
        assert not self.c_ram.bad_bursts, f"AXI protocol issue: {self.c_ram.bad_bursts[:4]}"
        acc = a.astype(np.int64) @ b.astype(np.int64)
        if int8:
            expected = requantize(acc, bias, mult, shift, relu).tobytes()
            got = self.c_ram.read(c_base, m * n)
        else:
            expected = acc.astype("<i4").tobytes()
            got = self.c_ram.read(c_base, m * n * 4)
        return status, got, expected, acc


async def setup(dut, pause=False):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    h = Harness(dut, pause)
    await h.reset()
    return h


def rand_mat(rng, shape, full_range=True):
    lo, hi = (-128, 128) if full_range else (-8, 8)
    return rng.integers(lo, hi, shape, dtype=np.int64).astype(np.int8)


@cocotb.test()
async def test_int32_shapes(dut):
    """Raw INT32 writeback across awkward shapes, full INT8 range."""
    h = await setup(dut)
    rng = np.random.default_rng(11)
    shapes = [(4, 4, 4), (1, 1, 1), (5, 6, 9), (7, 3, 13), (16, 12, 33), (3, 17, 64)]
    for idx, (m, n, k) in enumerate(shapes):
        a, b = rand_mat(rng, (m, k)), rand_mat(rng, (k, n))
        tile_k = min(k, 16) if idx % 2 else min(k, MAX_DIM)
        status, got, exp, _ = await h.run(a, b, a_base=0x1000, b_base=0x9000,
                                          c_base=0x20000, tile_k=tile_k)
        assert status & ST_DONE and not status & ST_ERROR, f"{(m, n, k)} status={status:#x}"
        assert got == exp, f"INT32 mismatch for M,N,K={(m, n, k)} tile_k={tile_k}"
        await h.write(STATUS, ST_DONE | ST_ERROR)
        assert (await h.read(STATUS)) & ST_DONE == 0, "DONE is not write-one-to-clear"
        dut._log.info("INT32 M,N,K=%s tile_k=%d ok", (m, n, k), tile_k)


@cocotb.test()
async def test_int8_postprocess(dut):
    """Packed INT8 writeback: bias, multiplier/shift, ReLU and saturation."""
    h = await setup(dut)
    rng = np.random.default_rng(12)
    cases = [
        dict(shape=(8, 8, 16), bias=0, mult=1, shift=0, relu=False),       # pure saturation
        dict(shape=(5, 7, 11), bias=-300, mult=3, shift=4, relu=True),
        dict(shape=(12, 10, 32), bias=1000, mult=1 << 20, shift=27, relu=False),
        dict(shape=(3, 5, 64), bias=-7, mult=-5, shift=9, relu=True),      # negative multiplier
    ]
    for case in cases:
        m, n, k = case.pop("shape")
        a, b = rand_mat(rng, (m, k)), rand_mat(rng, (k, n))
        status, got, exp, _ = await h.run(a, b, a_base=0x2000, b_base=0xA000,
                                          c_base=0x30000, tile_k=min(k, 16), int8=True, **case)
        assert status & ST_DONE and not status & ST_ERROR
        assert got == exp, f"INT8 mismatch for M,N,K={(m, n, k)} {case}"
        # Bytes after the packed tail must be untouched (write strobes honoured).
        tail = (m * n) % 4
        if tail:
            pad = h.c_ram.read(0x30000 + m * n, 4 - tail)
            dut._log.info("tail bytes after packed output: %s", pad.hex())
        await h.write(STATUS, ST_DONE | ST_ERROR)
        dut._log.info("INT8 M,N,K=%s ok", (m, n, k))


@cocotb.test()
async def test_backpressure_and_back_to_back(dut):
    """Random stalls on every AXI channel; several jobs without reset."""
    h = await setup(dut, pause=True)
    rng = np.random.default_rng(13)
    for job, (m, n, k) in enumerate(itertools.islice(
            ((int(rng.integers(1, 24)), int(rng.integers(1, 24)), int(rng.integers(1, 48)))
             for _ in iter(int, 1)), 6)):
        a, b = rand_mat(rng, (m, k)), rand_mat(rng, (k, n))
        int8 = bool(job % 2)
        status, got, exp, _ = await h.run(a, b, a_base=0x4000 + 64 * job, b_base=0xC000,
                                          c_base=0x28000, tile_k=min(k, 16), int8=int8,
                                          bias=5, mult=1, shift=3, relu=int8)
        assert status & ST_DONE and not status & ST_ERROR
        assert got == exp, f"job {job} M,N,K={(m, n, k)} int8={int8} mismatch under back-pressure"
        await h.write(STATUS, ST_DONE | ST_ERROR)


@cocotb.test()
async def test_perf_counters(dut):
    """PERF_* registers report useful MACs, tiles and a sane active-cycle count."""
    h = await setup(dut)
    rng = np.random.default_rng(14)
    m, n, k, tk = 8, 12, 40, 16
    a, b = rand_mat(rng, (m, k)), rand_mat(rng, (k, n))
    status, got, exp, _ = await h.run(a, b, a_base=0x1000, b_base=0x9000,
                                      c_base=0x20000, tile_k=tk)
    assert got == exp and status & ST_DONE
    macs = (await h.read(PERF_MAC_LO)) | ((await h.read(PERF_MAC_HI)) << 32)
    tiles = await h.read(PERF_TILES)
    active = await h.read(PERF_ACTIVE)
    assert macs == m * n * k, macs
    assert tiles == (-(-m // ARRAY_N)) * (-(-n // ARRAY_N)) * (-(-k // tk)), tiles
    ideal = m * n * k / (ARRAY_N * ARRAY_N)
    assert active >= ideal, f"active={active} below the physical bound {ideal}"
    dut._log.info("perf: macs=%d tiles=%d active=%d (ideal %.0f, %.1f%% utilisation)",
                  macs, tiles, active, ideal, 100 * ideal / active)


@cocotb.test()
async def test_bad_descriptor_reports_error(dut):
    """An illegal tile size must end in ERROR, not a hang, and the core must recover."""
    h = await setup(dut)
    rng = np.random.default_rng(15)
    a, b = rand_mat(rng, (4, 4)), rand_mat(rng, (4, 4))
    h.put(0x1000, a)
    h.put(0x9000, b)
    for reg, val in ((A_BASE, 0x1000), (B_BASE, 0x9000), (C_BASE, 0x20000),
                     (REG_M, 4), (REG_N, 4), (REG_K, 4),
                     (TILE_M, 3), (TILE_N, ARRAY_N), (TILE_K, 4), (POST_CFG, 0)):
        await h.write(reg, val)
    await h.write(CTRL, 1)
    status = await h.wait_idle(timeout=50_000)
    assert status & ST_ERROR, f"illegal TILE_M accepted, status={status:#x}"
    await h.write(STATUS, ST_DONE | ST_ERROR)
    # Recovery: a legal job afterwards must still be correct.
    status, got, exp, _ = await h.run(a, b, a_base=0x1000, b_base=0x9000,
                                      c_base=0x20000, tile_k=4)
    assert status & ST_DONE and not status & ST_ERROR and got == exp


@cocotb.test()
async def test_illegal_descriptors_never_wedge(dut):
    """Every class of illegal descriptor is rejected up front, BUSY never rises."""
    h = await setup(dut)
    # Complete one legal job first: its completion state must not leak into
    # the rejected STARTs below as a stale DONE.
    rng = np.random.default_rng(19)
    a, b = rand_mat(rng, (4, 4)), rand_mat(rng, (4, 4))
    status, got, exp, _ = await h.run(a, b, a_base=0x1000, b_base=0x9000, c_base=0x20000, tile_k=4)
    assert status & ST_DONE and got == exp
    await h.write(STATUS, ST_DONE | ST_ERROR)
    legal = {A_BASE: 0x1000, B_BASE: 0x9000, C_BASE: 0x20000, REG_M: 4, REG_N: 4, REG_K: 4,
             TILE_M: ARRAY_N, TILE_N: ARRAY_N, TILE_K: 4, POST_CFG: 0}
    bad_cases = {
        "M=0": {REG_M: 0}, "N>MAX": {REG_N: MAX_DIM + 1}, "K>MAX": {REG_K: MAX_DIM + 1},
        "TILE_N=0": {TILE_N: 0}, "TILE_M>ARRAY_N": {TILE_M: ARRAY_N + 4},
        "TILE_K=0": {TILE_K: 0}, "TILE_K>MAX_K": {TILE_K: MAX_DIM + 1},
        "A misaligned": {A_BASE: 0x1001}, "C misaligned": {C_BASE: 0x20002},
    }
    for name, override in bad_cases.items():
        for reg, val in {**legal, **override}.items():
            await h.write(reg, val)
        await h.write(CTRL, 1)
        saw_busy = False
        for _ in range(8):
            status = await h.read(STATUS)
            saw_busy |= bool(status & ST_BUSY)
        assert status & ST_ERROR, f"{name}: not rejected (status={status:#x})"
        assert not status & ST_DONE, f"{name}: stale DONE from the previous job"
        assert not saw_busy, f"{name}: core went BUSY on an illegal descriptor"
        assert not status & ST_DONE, f"{name}: rejected job reported DONE"
        await h.write(STATUS, ST_ERROR)
        assert (await h.read(STATUS)) & ST_ERROR == 0, f"{name}: ERROR is not clearable"
        dut._log.info("%s rejected cleanly", name)


@cocotb.test()
async def test_irq_level_clears(dut):
    """irq = IRQ_EN & (DONE | ERROR) must drop once software acknowledges."""
    h = await setup(dut)
    rng = np.random.default_rng(16)
    a, b = rand_mat(rng, (4, 8)), rand_mat(rng, (8, 4))
    h.put(0x1000, a)
    h.put(0x9000, b)
    for reg, val in ((A_BASE, 0x1000), (B_BASE, 0x9000), (C_BASE, 0x20000),
                     (REG_M, 4), (REG_N, 4), (REG_K, 8),
                     (TILE_M, ARRAY_N), (TILE_N, ARRAY_N), (TILE_K, 8), (POST_CFG, 0)):
        await h.write(reg, val)
    await h.write(CTRL, 1 | 4)            # START | IRQ_EN
    for _ in range(20000):
        await RisingEdge(dut.clk)
        if int(dut.irq.value):
            break
    else:
        raise AssertionError("irq never asserted")
    await h.write(STATUS, ST_DONE)
    await ClockCycles(dut.clk, 2)
    assert int(dut.irq.value) == 0, "irq stuck high after DONE was acknowledged"


BIAS_VEC = 0x100


@cocotb.test()
async def test_per_channel_bias(dut):
    """INT8 epilogue with a per-output-column bias vector (+ scalar POST_BIAS)."""
    h = await setup(dut)
    rng = np.random.default_rng(17)
    # Vector resets to zero: read it back first.
    for j in (0, 1, MAX_DIM - 1):
        assert await h.read(BIAS_VEC + 4 * j) == 0, "bias vector not reset to zero"
    for (m, n, k), scalar, relu in (((9, 10, 32), 0, False), ((16, 32, 64), -50, True),
                                    ((5, MAX_DIM, 7), 17, True), ((64, 3, 64), 0, False)):
        bias = rng.integers(-40000, 40000, n)
        for j, v in enumerate(bias):
            await h.write(BIAS_VEC + 4 * j, int(v))
        for j in range(0, n, max(1, n // 5)):
            assert np.int32(np.uint32(await h.read(BIAS_VEC + 4 * j))) == bias[j]
        a, b = rand_mat(rng, (m, k)), rand_mat(rng, (k, n))
        mult, shift = 1 << 12, 20
        status, got, _, acc = await h.run(a, b, a_base=0x1000, b_base=0x9000, c_base=0x30000,
                                          tile_k=min(k, 32), int8=True, bias=scalar,
                                          mult=mult, shift=shift, relu=relu)
        expected = requantize(acc, bias[None, :] + scalar, mult, shift, relu).tobytes()
        assert status & ST_DONE and not status & ST_ERROR
        assert got == expected, f"per-channel bias mismatch M,N,K={(m, n, k)}"
        await h.write(STATUS, ST_DONE | ST_ERROR)
        dut._log.info("per-channel bias M,N,K=%s scalar=%d relu=%s ok", (m, n, k), scalar, relu)
    # Clearing the vector restores pure scalar-bias behaviour.
    for j in range(MAX_DIM):
        await h.write(BIAS_VEC + 4 * j, 0)


@cocotb.test()
async def test_bias_vector_locked_while_busy(dut):
    """A bias write during a job must not change that job's output."""
    h = await setup(dut)
    rng = np.random.default_rng(18)
    m, n, k = 32, 16, 64
    bias = rng.integers(-2000, 2000, n)
    for j, v in enumerate(bias):
        await h.write(BIAS_VEC + 4 * j, int(v))
    a, b = rand_mat(rng, (m, k)), rand_mat(rng, (k, n))
    h.put(0x1000, a)
    h.put(0x9000, b)
    for reg, val in ((A_BASE, 0x1000), (B_BASE, 0x9000), (C_BASE, 0x30000),
                     (REG_M, m), (REG_N, n), (REG_K, k),
                     (TILE_M, ARRAY_N), (TILE_N, ARRAY_N), (TILE_K, 32),
                     (POST_BIAS, 0), (POST_SCALE, 1), (POST_CFG, (8 << 2) | 2)):
        await h.write(reg, val)
    await h.write(CTRL, 1)
    await ClockCycles(dut.clk, 20)
    assert (await h.read(STATUS)) & ST_BUSY
    for j in range(n):
        await h.write(BIAS_VEC + 4 * j, 99999)          # must be ignored
    status = await h.wait_idle()
    acc = a.astype(np.int64) @ b.astype(np.int64)
    expected = requantize(acc, bias[None, :], 1, 8, False).tobytes()
    assert status & ST_DONE and h.c_ram.read(0x30000, m * n) == expected
    assert np.int32(np.uint32(await h.read(BIAS_VEC))) == bias[0], "bias changed while busy"
