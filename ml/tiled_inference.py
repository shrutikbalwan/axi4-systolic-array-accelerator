"""Tiled ML execution layer shared by software and hardware backends.

The backend boundary is intentionally tiny: a backend accepts one accelerator-
sized INT8 GEMM and returns an INT32 matrix. The scheduler handles arbitrary
M/K/N dimensions, K-tile accumulation, bias and ReLU. Today this can use the
software reference backend; tomorrow the same scheduler can call the AXI/DMA
driver without changing the model logic.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

import numpy as np

try:  # Works both as ``python -m ml...`` and unittest discovery from ml/.
    from .quantized_mlp import Int8Tensor, QuantizedLinear, quantize_symmetric, tiled_gemm_int8
except ImportError:
    from quantized_mlp import Int8Tensor, QuantizedLinear, quantize_symmetric, tiled_gemm_int8


class GemmBackend(Protocol):
    def gemm(self, a: np.ndarray, b: np.ndarray) -> np.ndarray:
        """Return signed INT32 ``a @ b`` for one accelerator-sized tile."""


@dataclass(frozen=True)
class SoftwareGemmBackend:
    """Bit-accurate stand-in for the current RTL accelerator."""

    array_n: int = 4
    kmax: int = 16

    def gemm(self, a: np.ndarray, b: np.ndarray) -> np.ndarray:
        if a.shape[0] > self.array_n or b.shape[1] > self.array_n:
            raise ValueError("tile exceeds configured systolic-array dimensions")
        if a.shape[1] > self.kmax:
            raise ValueError("K tile exceeds configured KMAX")
        return tiled_gemm_int8(
            a,
            b,
            tile_m=self.array_n,
            tile_n=self.array_n,
            tile_k=self.kmax,
        )


def tiled_gemm(
    backend: GemmBackend,
    a: np.ndarray,
    b: np.ndarray,
    *,
    tile_m: int,
    tile_n: int,
    tile_k: int,
) -> np.ndarray:
    """Schedule an arbitrary INT8 GEMM over accelerator-sized tiles."""

    a = np.asarray(a, dtype=np.int8)
    b = np.asarray(b, dtype=np.int8)
    if a.ndim != 2 or b.ndim != 2 or a.shape[1] != b.shape[0]:
        raise ValueError(f"incompatible GEMM shapes: {a.shape} and {b.shape}")
    if min(tile_m, tile_n, tile_k) <= 0:
        raise ValueError("tile dimensions must be positive")

    m, k = a.shape
    _, n = b.shape
    result = np.zeros((m, n), dtype=np.int64)
    for m0 in range(0, m, tile_m):
        for n0 in range(0, n, tile_n):
            out_m = min(tile_m, m - m0)
            out_n = min(tile_n, n - n0)
            tile_acc = np.zeros((out_m, out_n), dtype=np.int64)
            for k0 in range(0, k, tile_k):
                partial = backend.gemm(
                    a[m0 : m0 + out_m, k0 : k0 + tile_k],
                    b[k0 : k0 + tile_k, n0 : n0 + out_n],
                )
                if partial.shape != tile_acc.shape:
                    raise ValueError("backend returned the wrong tile shape")
                tile_acc += partial.astype(np.int64)
            result[m0 : m0 + out_m, n0 : n0 + out_n] = tile_acc

    if result.size and (result.min() < -(1 << 31) or result.max() > (1 << 31) - 1):
        raise OverflowError("tiled accumulator exceeds signed INT32")
    return result.astype(np.int32)


def run_linear(
    backend: GemmBackend,
    x: Int8Tensor,
    layer: QuantizedLinear,
    *,
    tile_m: int,
    tile_n: int,
    tile_k: int,
    relu: bool = False,
) -> Int8Tensor:
    """Run one quantized linear layer through the tiled backend."""

    if x.values.ndim != 2 or x.values.shape[1] != layer.in_features:
        raise ValueError("input shape does not match layer")
    acc = tiled_gemm(
        backend,
        x.values,
        layer.weights.values.T,
        tile_m=tile_m,
        tile_n=tile_n,
        tile_k=tile_k,
    ).astype(np.float64)
    real = acc * (x.scale * layer.weights.scale) + layer.bias
    if relu:
        real = np.maximum(real, 0.0)
    return quantize_symmetric(real, scale=layer.output_scale)
