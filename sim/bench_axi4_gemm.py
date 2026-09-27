"""Ideal-memory benchmark for tiled_axi4_gemm_top (not part of the pass/fail suite).

    cd sim && make TB=axi4_gemm COCOTB_TEST_MODULES=bench_axi4_gemm N=4

Memory answers every AXI beat in one cycle, so the numbers isolate the
accelerator's own schedule from any SoC interconnect. Compare with the SoC
figures from soc/run_soc_sim.py to see how much time the bus costs.
Writes build/bench/axi4_gemm_ideal_memory_N<N>.csv (committed copies live in
docs/results/).
"""

from __future__ import annotations

import csv
import os

import cocotb
import numpy as np

from test_axi4_gemm_top import (ARRAY_N, PERF_ACTIVE, ST_DONE, STATUS, rand_mat, setup)

CASES = [
    # name,               M,  N,  K, int8
    ("gemm 64x64x64 int32", 64, 64, 64, False),
    ("gemm 64x64x64 int8", 64, 64, 64, True),
    ("mlp layer1 (64x32x64)", 64, 32, 64, True),
    ("mlp layer2 (64x10x32)", 64, 10, 32, True),
]


@cocotb.test()
async def bench(dut):
    h = await setup(dut)
    rng = np.random.default_rng(99)
    rows = []
    for name, m, n, k, int8 in CASES:
        a, b = rand_mat(rng, (m, k)), rand_mat(rng, (k, n))
        start = cocotb.utils.get_sim_time("ns")
        status, got, exp, _ = await h.run(a, b, a_base=0x1000, b_base=0x9000, c_base=0x20000,
                                          tile_k=k, int8=int8, mult=1, shift=8)
        wall = int((cocotb.utils.get_sim_time("ns") - start) / 10)
        assert status & ST_DONE and got == exp
        active = await h.read(PERF_ACTIVE)
        await h.write(STATUS, 0x6)
        macs = m * n * k
        in_words = (m * k + 3) // 4 + (k * n + 3) // 4
        out_words = (m * n + 3) // 4 if int8 else m * n
        rows.append(dict(case=name, array_n=ARRAY_N, macs=macs, active_cycles=active,
                         macs_per_cycle=round(macs / active, 2),
                         utilisation_pct=round(100 * macs / active / ARRAY_N ** 2, 1),
                         in_words=in_words, out_words=out_words, wall_cycles_incl_driver=wall))
        dut._log.info("%-24s active=%6d  %.2f MAC/cycle  %.1f%% of %d PEs",
                      name, active, macs / active, 100 * macs / active / ARRAY_N ** 2, ARRAY_N ** 2)
    out_dir = os.path.join(os.path.dirname(__file__), "..", "build", "bench")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"axi4_gemm_ideal_memory_N{ARRAY_N}.csv")
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
