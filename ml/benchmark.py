"""Report theoretical tiled-accelerator work and measured software timing."""

from __future__ import annotations

import argparse
import time

import numpy as np

from tiled_inference import SoftwareGemmBackend, tiled_gemm


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--m", type=int, default=32)
    parser.add_argument("--n", type=int, default=32)
    parser.add_argument("--k", type=int, default=64)
    parser.add_argument("--array-n", type=int, default=4)
    parser.add_argument("--kmax", type=int, default=16)
    args = parser.parse_args()
    rng = np.random.default_rng(2026)
    a = rng.integers(-128, 128, (args.m, args.k), dtype=np.int8)
    b = rng.integers(-128, 128, (args.k, args.n), dtype=np.int8)
    backend = SoftwareGemmBackend(args.array_n, args.kmax)

    start = time.perf_counter()
    result = tiled_gemm(
        backend,
        a,
        b,
        tile_m=args.array_n,
        tile_n=args.array_n,
        tile_k=args.kmax,
    )
    elapsed = time.perf_counter() - start
    expected = a.astype(np.int64) @ b.astype(np.int64)
    np.testing.assert_array_equal(result, expected)

    macs = args.m * args.n * args.k
    m_tiles = (args.m + args.array_n - 1) // args.array_n
    n_tiles = (args.n + args.array_n - 1) // args.array_n
    k_tiles = (args.k + args.kmax - 1) // args.kmax
    tile_count = m_tiles * n_tiles * k_tiles
    padded_mac_slots = m_tiles * n_tiles * args.array_n * args.array_n * args.k
    ideal_compute_cycles = m_tiles * n_tiles * (
        args.k + k_tiles * (2 * args.array_n - 1)
    )
    a_words = (args.m * args.k + 3) // 4
    b_words = (args.k * args.n + 3) // 4
    c_int32_words = args.m * args.n
    c_int8_words = (c_int32_words + 3) // 4
    print(f"shape={args.m}x{args.k}x{args.n}")
    print(f"macs={macs}")
    print(f"tile_count={tile_count}")
    print(f"padded_mac_slots={padded_mac_slots}")
    print(f"array_mac_utilization={macs / padded_mac_slots:.6f}")
    print(f"ideal_compute_cycles={ideal_compute_cycles}")
    print(f"ideal_useful_macs_per_cycle={macs / ideal_compute_cycles:.4f}")
    print(f"a_input_words={a_words}")
    print(f"b_input_words={b_words}")
    print(f"c_int32_words={c_int32_words}")
    print(f"c_packed_int8_words={c_int8_words}")
    print(f"software_seconds={elapsed:.6f}")
    print(f"software_macs_per_second={macs / elapsed:.2f}")


if __name__ == "__main__":
    main()
