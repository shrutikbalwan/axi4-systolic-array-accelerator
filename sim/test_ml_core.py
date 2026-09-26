"""End-to-end tiled INT8 GEMM plus integer ML post-processing regression."""

import cocotb
import numpy as np
import os
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

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
    dut.a_stream_valid.value = 1
    dut.b_stream_valid.value = 1
    await RisingEdge(dut.clk)
    for index, (a_word, b_word) in enumerate(zip(aw, bw)):
        dut.a_stream_data.value = a_word
        dut.b_stream_data.value = b_word
        dut.a_stream_last.value = int(index == len(aw) - 1)
        dut.b_stream_last.value = int(index == len(bw) - 1)
        attempts = 0
        while True:
            await RisingEdge(dut.clk)
            if dut.a_stream_ready.value and dut.b_stream_ready.value:
                break
            attempts += 1
            if attempts > 1000:
                raise AssertionError("tile input handshake timed out")
    dut.a_stream_valid.value = 0
    dut.b_stream_valid.value = 0
    dut.a_stream_last.value = 0
    dut.b_stream_last.value = 0


@cocotb.test()
async def test_tiled_ml_core(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.start_job.value = 0
    # Hold the descriptor until the testbench has observed it. Otherwise a
    # permanently-ready consumer can accept a one-cycle tile_valid pulse before
    # Cocotb gets a chance to prepare the corresponding A/B streams.
    dut.tile_ready.value = 0
    dut.out_ready.value = 1
    dut.a_stream_valid.value = 0
    dut.b_stream_valid.value = 0
    dut.relu_en.value = 1
    dut.bias.value = 0
    dut.scale_mult.value = 1
    dut.scale_shift.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    m, n, k = 5, 6, 9
    tm, tn, tk = 4, 4, 4
    rng = np.random.default_rng(2028)
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
    dut.start_job.value = 0

    seen_tiles = 0
    for _cycle in range(20000):
        await RisingEdge(dut.clk)
        if dut.tile_valid.value:
            seen_tiles += 1
            m0, n0, k0 = (int(dut.tile_m_base.value), int(dut.tile_n_base.value), int(dut.tile_k_base.value))
            ml, nl, kl = (int(dut.tile_m_len.value), int(dut.tile_n_len.value), int(dut.tile_k_len.value))
            last_k = bool(dut.tile_last_k.value)
            aw, bw = tile_words(a, b, m0, n0, k0, ml, nl, kl)
            dut.tile_ready.value = 1
            await send_tile(dut, aw, bw)
            dut.tile_ready.value = 0

            if last_k:
                tile_result = []
                while True:
                    await RisingEdge(dut.clk)
                    await ReadOnly()
                    if dut.out_valid.value and dut.out_ready.value:
                        raw = int(dut.out_data.value)
                        tile_result.append(raw - 256 if raw & 0x80 else raw)
                        if dut.out_last.value:
                            break
                tile_array = np.asarray(tile_result, dtype=np.int64).reshape(N, N)
                got[m0 : m0 + ml, n0 : n0 + nl] = tile_array[:ml, :nl]
            else:
                while not dut.tile_valid.value:
                    await RisingEdge(dut.clk)
                    await ReadOnly()

        if dut.done.value:
            break
    else:
        raise AssertionError(f"ML core did not complete within 20000 cycles; tiles_seen={seen_tiles}")

    expected = np.maximum(a @ b, 0).clip(-128, 127)
    np.testing.assert_array_equal(got, expected)
    assert dut.error.value == 0


@cocotb.test()
async def test_wide_scaled_product_does_not_wrap(dut):
    """A positive 64-bit requantization product must clamp to +127."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.start_job.value = 0
    dut.tile_ready.value = 0
    dut.out_ready.value = 1
    dut.a_stream_valid.value = 0
    dut.b_stream_valid.value = 0
    dut.relu_en.value = 0
    dut.bias.value = 0
    dut.scale_mult.value = 1 << 30
    dut.scale_shift.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    dut.matrix_m.value = 1
    dut.matrix_n.value = 1
    dut.matrix_k.value = 1
    dut.tile_m_cfg.value = N
    dut.tile_n_cfg.value = N
    dut.tile_k_cfg.value = 1
    dut.start_job.value = 1
    await RisingEdge(dut.clk)
    dut.start_job.value = 0

    for _ in range(1000):
        await RisingEdge(dut.clk)
        if dut.tile_valid.value:
            dut.tile_ready.value = 1
            await send_tile(dut, [3] + [0] * (WPR - 1), [1] + [0] * (WPR - 1))
            dut.tile_ready.value = 0
            break
    else:
        raise AssertionError("tile descriptor timed out")

    outputs = []
    for _ in range(2000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.out_valid.value and dut.out_ready.value:
            outputs.append(dut.out_data.value.to_signed())
            if dut.out_last.value:
                break
    else:
        raise AssertionError("ML output timed out")

    assert outputs[0] == 127
