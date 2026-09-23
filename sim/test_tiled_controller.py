"""End-to-end runtime tiled controller regression against NumPy."""

import cocotb
import numpy as np
import os
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

N = int(os.environ.get("N", "4"))
KMAX = int(os.environ.get("KMAX", "16"))
WPR = N // 4


def pack(values):
    word = 0
    for lane, value in enumerate(values):
        word |= (int(value) & 0xFF) << (lane * 8)
    return word


def tile_words(a, b, m0, n0, k0, ml, nl, kl):
    at = np.zeros((N, kl), dtype=np.int64)
    bt = np.zeros((kl, N), dtype=np.int64)
    at[:ml, :] = a[m0 : m0 + ml, k0 : k0 + kl]
    bt[:, :nl] = b[k0 : k0 + kl, n0 : n0 + nl]
    aw, bw = [], []
    for kk in range(kl):
        for w in range(WPR):
            aw.append(pack(at[w * 4 : (w + 1) * 4, kk]))
            bw.append(pack(bt[kk, w * 4 : (w + 1) * 4]))
    return aw, bw


async def send_tile(dut, aw, bw):
    await Timer(1, unit="ns")
    dut.a_stream_valid.value = 1
    dut.b_stream_valid.value = 1
    # The controller launches the compute chain on the next edge; let the
    # adapter enter LOAD before counting the first stream handshake.
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    for index, (a_word, b_word) in enumerate(zip(aw, bw)):
        dut.a_stream_data.value = a_word
        dut.b_stream_data.value = b_word
        dut.a_stream_last.value = int(index == len(aw) - 1)
        dut.b_stream_last.value = int(index == len(bw) - 1)
        while True:
            await RisingEdge(dut.clk)
            if dut.a_stream_ready.value and dut.b_stream_ready.value:
                break
    dut.a_stream_valid.value = 0
    dut.b_stream_valid.value = 0
    dut.a_stream_last.value = 0
    dut.b_stream_last.value = 0


@cocotb.test()
async def test_non_multiple_runtime_tiled_gemm(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.start_job.value = 0
    dut.tile_ready.value = 0
    dut.c_stream_ready.value = 1
    dut.a_stream_valid.value = 0
    dut.b_stream_valid.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    m, n, k = 5, 6, 9
    tm, tn, tk = 4, 4, 4
    rng = np.random.default_rng(2027)
    a = rng.integers(-8, 8, (m, k), dtype=np.int64)
    b = rng.integers(-8, 8, (k, n), dtype=np.int64)
    got = np.zeros((m, n), dtype=np.int64)

    dut.matrix_m.value = m
    dut.matrix_n.value = n
    dut.matrix_k.value = k
    dut.tile_m_cfg.value = tm
    dut.tile_n_cfg.value = tn
    dut.tile_k_cfg.value = tk
    dut.start_job.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut.start_job.value = 0

    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.tile_valid.value:
            await Timer(1, unit="ns")
            dut.tile_ready.value = 1
            m0, n0, k0 = (int(dut.tile_m_base.value), int(dut.tile_n_base.value), int(dut.tile_k_base.value))
            ml, nl, kl = (int(dut.tile_m_len.value), int(dut.tile_n_len.value), int(dut.tile_k_len.value))
            last_k = bool(dut.tile_last_k.value)
            aw, bw = tile_words(a, b, m0, n0, k0, ml, nl, kl)
            await send_tile(dut, aw, bw)

            if last_k:
                tile_result = []
                while True:
                    await RisingEdge(dut.clk)
                    await ReadOnly()
                    if dut.c_stream_valid.value and dut.c_stream_ready.value:
                        raw = int(dut.c_stream_data.value)
                        tile_result.append(raw - (1 << 32) if raw & (1 << 31) else raw)
                        if dut.c_stream_last.value:
                            break
                tile_array = np.asarray(tile_result, dtype=np.int64).reshape(N, N)
                got[m0 : m0 + ml, n0 : n0 + nl] = tile_array[:ml, :nl]
            else:
                # The controller exposes only the scheduler-level tile
                # interface; the internal chain completion is consumed
                # internally before the next tile_valid is presented.
                pass

        if dut.done.value:
            break

    np.testing.assert_array_equal(got, a @ b)
    assert dut.error.value == 0
