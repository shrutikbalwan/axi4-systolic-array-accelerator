"""Runtime M/N/K tile schedule regression."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer


@cocotb.test()
async def test_runtime_edge_tiles_and_k_order(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.start.value = 0
    # Hold the first descriptor until the testbench has observed it.
    dut.tile_ready.value = 0
    dut.tile_done.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut.rst_n.value = 1

    m, n, k = 9, 7, 37
    tm, tn, tk = 4, 4, 16
    dut.matrix_m.value = m
    dut.matrix_n.value = n
    dut.matrix_k.value = k
    dut.tile_m_cfg.value = tm
    dut.tile_n_cfg.value = tn
    dut.tile_k_cfg.value = tk
    dut.start.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut.start.value = 0

    expected = []
    for m0 in range(0, m, tm):
        for n0 in range(0, n, tn):
            for k0 in range(0, k, tk):
                expected.append((
                    m0,
                    n0,
                    k0,
                    min(tm, m - m0),
                    min(tn, n - n0),
                    min(tk, k - k0),
                    k0 == 0,
                    k0 + tk >= k,
                ))

    observed = []
    accepted_pending = False
    for cycle in range(1000):
        if len(observed) >= len(expected):
            break
        await RisingEdge(dut.clk)
        await ReadOnly()
        tile_valid = bool(dut.tile_valid.value)
        await Timer(1, unit="ns")
        if cycle == 0:
            dut.tile_ready.value = 1
        # Complete the tile accepted on the previous edge.  A tile is
        # accepted first, then retired with tile_done on the following edge.
        dut.tile_done.value = int(accepted_pending)
        if tile_valid:
            observed.append((
                int(dut.tile_m_base.value),
                int(dut.tile_n_base.value),
                int(dut.tile_k_base.value),
                int(dut.tile_m_len.value),
                int(dut.tile_n_len.value),
                int(dut.tile_k_len.value),
                bool(dut.tile_first_k.value),
                bool(dut.tile_last_k.value),
            ))
        accepted_pending = tile_valid
    else:
        raise AssertionError(f"scheduler stalled after {len(observed)}/{len(expected)} tiles")

    # The final descriptor was observed but has not yet been accepted.  Allow
    # that acceptance, then complete it and observe the registered done pulse.
    await RisingEdge(dut.clk)
    await ReadOnly()
    await Timer(1, unit="ns")
    dut.tile_done.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert dut.done.value == 1
    await Timer(1, unit="ns")
    dut.tile_done.value = 0
    assert dut.error.value == 0
    assert observed == expected
