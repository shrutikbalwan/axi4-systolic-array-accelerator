"""Contiguous matrix streams through the tile buffer and tiled GEMM top."""

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge


def pack(values):
    word = 0
    for lane, value in enumerate(values):
        word |= (int(value) & 0xFF) << (lane * 8)
    return word


def packed_row_major(matrix):
    flat = matrix.reshape(-1)
    return [pack(flat[index : index + 4]) for index in range(0, len(flat), 4)]


@cocotb.test()
async def test_contiguous_stream_gemm_with_edges(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.start_job.value = 0
    dut.a_in_valid.value = 0
    dut.b_in_valid.value = 0
    dut.c_out_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    m, n, k = 5, 6, 9
    rng = np.random.default_rng(2029)
    a = rng.integers(-8, 8, (m, k), dtype=np.int64)
    b = rng.integers(-8, 8, (k, n), dtype=np.int64)
    a_words = packed_row_major(a)
    b_words = packed_row_major(b)

    dut.matrix_m.value = m
    dut.matrix_n.value = n
    dut.matrix_k.value = k
    dut.tile_m_cfg.value = 4
    dut.tile_n_cfg.value = 4
    dut.tile_k_cfg.value = 4
    dut.start_job.value = 1
    await RisingEdge(dut.clk)
    dut.start_job.value = 0

    ai = bi = 0
    for _cycle in range(5000):
        if not (ai < len(a_words) or bi < len(b_words)):
            break
        a_active = ai < len(a_words)
        b_active = bi < len(b_words)
        dut.a_in_valid.value = int(a_active)
        dut.b_in_valid.value = int(b_active)
        if a_active:
            dut.a_in_data.value = a_words[ai]
        if b_active:
            dut.b_in_data.value = b_words[bi]
        await RisingEdge(dut.clk)
        if a_active and dut.a_in_ready.value:
            ai += 1
        if b_active and dut.b_in_ready.value:
            bi += 1
    else:
        raise AssertionError(f"input stream stalled: a={ai}/{len(a_words)} b={bi}/{len(b_words)}")

    dut.a_in_valid.value = 0
    dut.b_in_valid.value = 0
    await ReadOnly()

    result = []
    for _cycle in range(20000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.c_out_valid.value and dut.c_out_ready.value:
            if not dut.c_out_data.value.is_resolvable:
                raise AssertionError(f"unresolved output word {len(result)}")
            raw = int(dut.c_out_data.value)
            result.append(raw - (1 << 32) if raw & (1 << 31) else raw)
            if dut.c_out_last.value:
                break
    else:
        raise AssertionError(f"output stream stalled after {len(result)} words")

    np.testing.assert_array_equal(np.asarray(result).reshape(m, n), a @ b)
    assert dut.error.value == 0
