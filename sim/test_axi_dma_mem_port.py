"""Regression for rtl/axi_dma_mem_port.sv (direct DMA burst port into RAM).

Drives the three AXI4 masters exactly like the accelerator's DMA engines do,
against tb/tb_axi_dma_mem_port.sv (DUT + 1-cycle synchronous RAM). A Python
shadow memory records every accepted write; every read beat is checked against
it. Covers concurrent A/B reads, round-robin fairness, WSTRB, random
RREADY/WVALID stalls, out-of-range SLVERR, and one-beat-per-cycle throughput.
"""

from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

BASE = 0x4000_0000
DEPTH = 1024
OKAY, SLVERR = 0, 2


class Tb:
    def __init__(self, dut):
        self.dut = dut
        self.shadow = [0] * DEPTH
        self.rng = random.Random(1)

    async def reset(self):
        d = self.dut
        for p in ("a", "b"):
            for s in ("araddr", "arlen", "arvalid", "rready"):
                getattr(d, f"{p}_{s}").value = 0
            getattr(d, f"{p}_arsize").value = 2
            getattr(d, f"{p}_arburst").value = 1
        for s in ("awaddr", "awlen", "awvalid", "wdata", "wstrb", "wlast", "wvalid", "bready"):
            getattr(d, f"c_{s}").value = 0
        d.c_awsize.value = 2
        d.c_awburst.value = 1
        d.rst_n.value = 0
        await ClockCycles(d.clk, 3)
        d.rst_n.value = 1
        await RisingEdge(d.clk)

    async def write_burst(self, addr, words, strb=None, stall=0.0):
        d = self.dut
        strb = strb or [0xF] * len(words)
        d.c_awaddr.value = addr
        d.c_awlen.value = len(words) - 1
        d.c_awvalid.value = 1
        while True:
            await ReadOnly()                 # sample READY before the edge
            fire = int(d.c_awready.value)
            await RisingEdge(d.clk)
            if fire:
                break
        d.c_awvalid.value = 0
        i = 0
        while i < len(words):
            go = self.rng.random() >= stall
            d.c_wvalid.value = int(go)
            d.c_wdata.value = words[i]
            d.c_wstrb.value = strb[i]
            d.c_wlast.value = int(i == len(words) - 1)
            await ReadOnly()
            fire = go and int(d.c_wready.value)
            await RisingEdge(d.clk)
            if fire:
                i += 1
        d.c_wvalid.value = 0
        d.c_bready.value = 1
        while True:
            await ReadOnly()
            if int(d.c_bvalid.value):
                resp = int(d.c_bresp.value)
                break
            await RisingEdge(d.clk)
        await RisingEdge(d.clk)
        d.c_bready.value = 0
        if resp == OKAY:
            base = (addr - BASE) // 4
            for j, (w, s) in enumerate(zip(words, strb)):
                old = self.shadow[base + j]
                for lane in range(4):
                    if s >> lane & 1:
                        old = (old & ~(0xFF << 8 * lane)) | (w & (0xFF << 8 * lane))
                self.shadow[base + j] = old
        return resp

    async def read_burst(self, port, addr, beats, stall=0.0):
        d = self.dut
        sig = lambda s: getattr(d, f"{port}_{s}")
        sig("araddr").value = addr
        sig("arlen").value = beats - 1
        sig("arvalid").value = 1
        waited = 0
        while True:
            await ReadOnly()                 # sample READY before the edge
            fire = int(sig("arready").value)
            await RisingEdge(d.clk)
            if fire:
                break
            waited += 1
        sig("arvalid").value = 0
        data, resps, lasts = [], [], []
        first_cycle = None
        cycles = 0
        while len(data) < beats:
            ready = self.rng.random() >= stall
            sig("rready").value = int(ready)
            await ReadOnly()
            cycles += 1
            if ready and int(sig("rvalid").value):
                if first_cycle is None:
                    first_cycle = cycles
                data.append(int(sig("rdata").value))
                resps.append(int(sig("rresp").value))
                lasts.append(int(sig("rlast").value))
            await RisingEdge(d.clk)
        sig("rready").value = 0
        assert lasts == [0] * (beats - 1) + [1], f"{port}: RLAST pattern {lasts}"
        return data, resps, cycles - first_cycle + 1, waited


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    tb = Tb(dut)
    await tb.reset()
    return tb


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_write_then_read_back(dut):
    tb = await start(dut)
    for base in (0, 17, 256, DEPTH - 16):
        words = [tb.rng.getrandbits(32) for _ in range(16)]
        assert await tb.write_burst(BASE + 4 * base, words) == OKAY
    for base in (0, 17, 256, DEPTH - 16):
        data, resps, _, _ = await tb.read_burst("a", BASE + 4 * base, 16)
        assert resps == [OKAY] * 16
        assert data == tb.shadow[base:base + 16]


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_one_beat_per_cycle(dut):
    """With RREADY/WVALID held high a 16-beat burst streams in 16 cycles."""
    tb = await start(dut)
    words = list(range(1, 17))
    await tb.write_burst(BASE, words)
    data, _, span, _ = await tb.read_burst("b", BASE, 16)
    assert data == words
    assert span == 16, f"16-beat read burst took {span} cycles (want 16)"


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_concurrent_reads_with_backpressure(dut):
    """A and B stream different regions at once under random RREADY stalls."""
    tb = await start(dut)
    for base in range(0, 512, 16):
        await tb.write_burst(BASE + 4 * base, [tb.rng.getrandbits(32) for _ in range(16)],
                             stall=0.3)

    async def reader(port, region):
        for i in range(8):
            beats = tb.rng.randint(1, 16)
            addr = region + 16 * i
            data, resps, _, _ = await tb.read_burst(port, BASE + 4 * addr, beats, stall=0.4)
            assert resps == [OKAY] * beats
            assert data == tb.shadow[addr:addr + beats], f"{port} burst {i} mismatch"

    ta = cocotb.start_soon(reader("a", 0))
    tb_ = cocotb.start_soon(reader("b", 256))
    await ta
    await tb_


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_round_robin_is_fair(dut):
    """Two masters that request simultaneously are granted alternately."""
    tb = await start(dut)
    grants = []
    d = dut

    async def watch():
        while True:
            await ReadOnly()
            if int(d.a_arready.value) and int(d.a_arvalid.value):
                grants.append("a")
            if int(d.b_arready.value) and int(d.b_arvalid.value):
                grants.append("b")
            await RisingEdge(d.clk)

    cocotb.start_soon(watch())

    async def reader(port):
        for _ in range(4):
            await tb.read_burst(port, BASE, 4)

    ta = cocotb.start_soon(reader("a"))
    tb_ = cocotb.start_soon(reader("b"))
    await ta
    await tb_
    assert len(grants) == 8, grants
    assert "aa" not in "".join(grants[:6]) and "bb" not in "".join(grants[:6]), grants


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_write_strobes(dut):
    tb = await start(dut)
    await tb.write_burst(BASE + 64, [0x11223344, 0x55667788])
    await tb.write_burst(BASE + 64, [0xAABBCCDD, 0xEEFF0011], strb=[0b0101, 0b1000])
    data, _, _, _ = await tb.read_burst("a", BASE + 64, 2)
    assert data == [0x11BB33DD, 0xEE667788], [hex(x) for x in data]


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_out_of_range_is_slverr_and_harmless(dut):
    tb = await start(dut)
    guard = [tb.rng.getrandbits(32) for _ in range(4)]
    await tb.write_burst(BASE + 4 * (DEPTH - 4), guard)
    # Burst running off the end, below BASE, and misaligned: all SLVERR.
    assert await tb.write_burst(BASE + 4 * (DEPTH - 2), [1, 2, 3, 4]) == SLVERR
    # Exact boundary: ending one word past RAM is an error...
    assert await tb.write_burst(BASE + 4 * (DEPTH - 3), [1, 2, 3, 4]) == SLVERR
    _, resps, _, _ = await tb.read_burst("a", BASE + 4 * (DEPTH - 1), 2)
    assert resps == [SLVERR] * 2
    # ...while a burst ending on the last word is fine.
    _, resps, _, _ = await tb.read_burst("a", BASE + 4 * (DEPTH - 1), 1)
    assert resps == [OKAY]
    assert await tb.write_burst(BASE - 16, [1, 2]) == SLVERR
    assert await tb.write_burst(BASE + 2, [1]) == SLVERR
    data, resps, _, _ = await tb.read_burst("a", BASE + 4 * (DEPTH - 2), 4)
    assert resps == [SLVERR] * 4
    data, resps, _, _ = await tb.read_burst("b", BASE + 4 * (DEPTH - 4), 4)
    assert resps == [OKAY] * 4 and data == guard, "an erroring write reached RAM"
