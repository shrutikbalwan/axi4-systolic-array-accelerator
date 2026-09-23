"""Descriptor-level golden model for the connected AXI4 tiled ML top."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

try:
    from .quantized_mlp import requantize_int32
    from .tiled_inference import SoftwareGemmBackend, tiled_gemm
except ImportError:
    from quantized_mlp import requantize_int32
    from tiled_inference import SoftwareGemmBackend, tiled_gemm


@dataclass(frozen=True)
class AcceleratorDescriptor:
    matrix_m: int
    matrix_n: int
    matrix_k: int
    tile_m: int = 4
    tile_n: int = 4
    tile_k: int = 16
    post_bias: int = 0
    post_scale: int = 1
    post_shift: int = 0
    relu: bool = False
    output_int8: bool = False


@dataclass(frozen=True)
class AcceleratorResult:
    accumulator: np.ndarray
    output: np.ndarray
    writeback_words: np.ndarray
    mac_count: int
    tile_count: int


def _pack_int8(values: np.ndarray) -> np.ndarray:
    flat = np.asarray(values, dtype=np.int8).reshape(-1)
    words = []
    for start in range(0, flat.size, 4):
        word = 0
        for lane, value in enumerate(flat[start : start + 4]):
            word |= (int(value) & 0xFF) << (lane * 8)
        words.append(word)
    return np.asarray(words, dtype=np.uint32)


def execute_descriptor(
    descriptor: AcceleratorDescriptor,
    a: np.ndarray,
    b: np.ndarray,
) -> AcceleratorResult:
    """Execute the descriptor contract against row-major matrices."""

    a = np.asarray(a, dtype=np.int8)
    b = np.asarray(b, dtype=np.int8)
    if a.shape != (descriptor.matrix_m, descriptor.matrix_k):
        raise ValueError(f"A shape does not match descriptor: {a.shape}")
    if b.shape != (descriptor.matrix_k, descriptor.matrix_n):
        raise ValueError(f"B shape does not match descriptor: {b.shape}")
    if min(descriptor.tile_m, descriptor.tile_n, descriptor.tile_k) <= 0:
        raise ValueError("tile dimensions must be positive")
    if descriptor.tile_m > 4 or descriptor.tile_n > 4 or descriptor.tile_k > 16:
        raise ValueError("descriptor tile exceeds ARRAY_N=4/KMAX=16 reference")

    accumulator = tiled_gemm(
        SoftwareGemmBackend(array_n=4, kmax=16), a, b,
        tile_m=descriptor.tile_m,
        tile_n=descriptor.tile_n,
        tile_k=descriptor.tile_k,
    )
    if descriptor.output_int8:
        output = requantize_int32(
            accumulator, descriptor.post_bias, descriptor.post_scale,
            descriptor.post_shift, relu=descriptor.relu,
        )
        writeback_words = _pack_int8(output)
    else:
        output = accumulator
        writeback_words = accumulator.astype("<i4").reshape(-1).view(np.uint32)

    tile_count = (
        ((descriptor.matrix_m + descriptor.tile_m - 1) // descriptor.tile_m)
        * ((descriptor.matrix_n + descriptor.tile_n - 1) // descriptor.tile_n)
        * ((descriptor.matrix_k + descriptor.tile_k - 1) // descriptor.tile_k)
    )
    return AcceleratorResult(
        accumulator=accumulator,
        output=output,
        writeback_words=writeback_words,
        mac_count=descriptor.matrix_m * descriptor.matrix_n * descriptor.matrix_k,
        tile_count=tile_count,
    )
