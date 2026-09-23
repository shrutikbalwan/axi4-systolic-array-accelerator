"""Multi-K compute-chain regression against NumPy."""

import os

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

N = int(os.environ.get("N", "4"))
WPR = N // 4


def pack(values):
    word = 0
    for lane, value in enumerate(values):
        word |= (int(value) & 0xFF) << (lane * 8)
    return word


def words_for(a, b):
    words_a, words_b = [], []
    for k in range(a.shape[1]):
        for w in range(WPR):
            words_a.append(pack(a[w * 4 : (w + 1) * 4, k]))
            words_b.append(pack(b[k, w * 4 : (w + 1) * 4]))
    return words_a, words_b


async def send(dut, side, words):
    valid = getattr(dut, f"{side}_stream_valid")
    ready = getattr(dut, f"{side}_stream_ready")
    data = getattr(dut, f"{side}_stream_data")
    valid.value = 1
    for word in words:
        data.value = word
        while True:
            await RisingEdge(dut.clk)
            if ready.value:
                break
    valid.value = 0


async def reset(dut):
    dut.rst_n.value = 0
    dut.start_tile.value = 0
    dut.a_stream_valid.value = 0
    dut.b_stream_valid.value = 0
    dut.c_stream_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1


async def run_tile(dut, a, b, first, last):
    # The previous tile may have ended in ReadOnly; move to a new timestep
    # before programming the next descriptor.
    await Timer(1, unit="ns")
    a_words, b_words = words_for(a, b)
    dut.k_len.value = a.shape[1]
    dut.first_k.value = int(first)
    dut.last_k.value = int(last)
    dut.start_tile.value = 1
    await RisingEdge(dut.clk)
    dut.start_tile.value = 0
    a_task = cocotb.start_soon(send(dut, "a", a_words))
    b_task = cocotb.start_soon(send(dut, "b", b_words))

    output = []
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.c_stream_valid.value and dut.c_stream_ready.value:
            raw = int(dut.c_stream_data.value)
            output.append(raw - (1 << 32) if raw & (1 << 31) else raw)
            if dut.c_stream_last.value:
                break
        if not last and dut.tile_done.value:
            break
    await a_task
    await b_task
    if last:
        # done is registered and becomes observable after the final output
        # handshake.
        await RisingEdge(dut.clk)
        await ReadOnly()
    return output


@cocotb.test()
async def test_two_k_tiles_accumulate(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    rng = np.random.default_rng(44)
    k0, k1 = 5, 7
    a0 = rng.integers(-128, 128, (N, k0), dtype=np.int64)
    b0 = rng.integers(-128, 128, (k0, N), dtype=np.int64)
    a1 = rng.integers(-128, 128, (N, k1), dtype=np.int64)
    b1 = rng.integers(-128, 128, (k1, N), dtype=np.int64)
    assert await run_tile(dut, a0, b0, True, False) == []
    got = await run_tile(dut, a1, b1, False, True)
    want = (a0 @ b0 + a1 @ b1).reshape(-1).tolist()
    assert got == want
    assert dut.done.value == 1
