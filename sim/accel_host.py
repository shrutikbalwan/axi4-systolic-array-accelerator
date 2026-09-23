"""Host-side model of the accelerator's register map, shared by the tests.

This is the Python equivalent of a bare-metal driver: it knows the register
map (docs/register_map.md) and the feed-order operand layout, and nothing else.
"""

import os

import numpy as np
from cocotb.triggers import RisingEdge

# ---- register map (byte offsets) -------------------------------------------
CTRL = 0x0000
STATUS = 0x0004
LEN = 0x0008
INFO = 0x000C
CYCLES = 0x0010
ACTIVE_CYCLES = 0x0020
MAC_COUNT_LO = 0x0024
MAC_COUNT_HI = 0x0028
A_BASE = 0x1000
B_BASE = 0x2000
C_BASE = 0x3000
WINDOW = 0x1000

CTRL_START = 1 << 0
CTRL_CLR_ACC = 1 << 1
CTRL_SOFT_RST = 1 << 2
CTRL_IRQ_EN = 1 << 3

STATUS_BUSY = 1 << 0
STATUS_DONE = 1 << 1
STATUS_ERR = 1 << 2

OKAY, EXOKAY, SLVERR, DECERR = 0, 1, 2, 3


def params():
    """Array parameters for this build (exported by sim/Makefile)."""
    return int(os.environ.get("N", "4")), int(os.environ.get("KMAX", "16"))


def pack_a(a):
    """A is N x K. The A window holds it in feed order: byte (k*N + r) = A[r][k]."""
    return np.ascontiguousarray(np.asarray(a).T).astype(np.int8).tobytes()


def pack_b(b):
    """B is K x N. The B window holds it row-major: byte (k*N + c) = B[k][c]."""
    return np.ascontiguousarray(np.asarray(b)).astype(np.int8).tobytes()


def reference(a, b):
    return np.asarray(a, dtype=np.int64) @ np.asarray(b, dtype=np.int64)


class Accel:
    """Thin driver over a cocotbext-axi AxiLiteMaster."""

    def __init__(self, dut, master, n, kmax):
        self.dut = dut
        self.m = master
        self.n = n
        self.kmax = kmax

    async def wr(self, addr, value):
        resp = await self.m.write(addr, int(value).to_bytes(4, "little"))
        return int(resp.resp)

    async def rd(self, addr):
        resp = await self.m.read(addr, 4)
        return int.from_bytes(resp.data, "little"), int(resp.resp)

    async def rd_ok(self, addr):
        value, resp = await self.rd(addr)
        assert resp == OKAY, f"read 0x{addr:04x} returned resp {resp}"
        return value

    async def wr_ok(self, addr, value):
        resp = await self.wr(addr, value)
        assert resp == OKAY, f"write 0x{addr:04x} returned resp {resp}"

    async def load(self, a, b):
        a = np.asarray(a)
        b = np.asarray(b)
        k = a.shape[1]
        assert a.shape == (self.n, k) and b.shape == (k, self.n)
        await self.m.write(A_BASE, pack_a(a))
        await self.m.write(B_BASE, pack_b(b))
        await self.wr_ok(LEN, k)

    async def start(self, irq_en=True):
        await self.wr_ok(CTRL, CTRL_START | (CTRL_IRQ_EN if irq_en else 0))

    async def wait_irq(self, max_cycles):
        """Wait for irq with a hard cycle limit (no silent hang)."""
        for _ in range(max_cycles):
            await RisingEdge(self.dut.aclk)
            if self.dut.irq.value == 1:
                return
        raise AssertionError(f"irq not asserted within {max_cycles} cycles")

    async def read_c(self):
        resp = await self.m.read(C_BASE, 4 * self.n * self.n)
        return np.frombuffer(bytes(resp.data), dtype="<i4").reshape(self.n, self.n)

    async def gemm(self, a, b):
        """Full software sequence: load, START, wait irq, read C, clear DONE."""
        await self.load(a, b)
        await self.start(irq_en=True)
        k = np.asarray(a).shape[1]
        await self.wait_irq(max_cycles=4 * (k + 2 * self.n) + 100)
        c = await self.read_c()
        await self.wr_ok(STATUS, STATUS_DONE)
        return c

    async def performance(self):
        """Return counters from the most recently completed run."""
        active = await self.rd_ok(ACTIVE_CYCLES)
        mac_lo = await self.rd_ok(MAC_COUNT_LO)
        mac_hi = await self.rd_ok(MAC_COUNT_HI)
        return {"active_cycles": active, "mac_count": mac_lo | (mac_hi << 32)}
