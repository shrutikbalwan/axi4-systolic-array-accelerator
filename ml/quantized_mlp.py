"""Reference contract for an INT8 inference pipeline.

The hardware core computes signed INT8 x INT8 products into signed INT32
accumulators. This module keeps that arithmetic explicit and uses tiled GEMM
so it remains useful before and after the RTL grows a DMA/tile controller.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable

import numpy as np


I8_MIN, I8_MAX = -128, 127
I32_MIN, I32_MAX = -(1 << 31), (1 << 31) - 1


@dataclass(frozen=True)
class Int8Tensor:
    """Signed INT8 values plus the real-value scale represented by one LSB."""

    values: np.ndarray
    scale: float

    def __post_init__(self) -> None:
        values = np.asarray(self.values)
        if values.dtype != np.int8:
            raise TypeError("Int8Tensor.values must have dtype int8")
        if not np.isfinite(self.scale) or self.scale <= 0:
            raise ValueError("scale must be a finite positive number")
        object.__setattr__(self, "values", np.ascontiguousarray(values))


def quantize_symmetric(values: np.ndarray, *, scale: float | None = None) -> Int8Tensor:
    """Quantize real values with one symmetric scale and round-to-nearest.

    The scale is max(abs(values))/127 unless supplied. A supplied scale is
    useful for matching a trained model's calibration constants.
    """

    real = np.asarray(values, dtype=np.float64)
    if not np.all(np.isfinite(real)):
        raise ValueError("values must be finite")
    if scale is None:
        peak = float(np.max(np.abs(real))) if real.size else 0.0
        scale = peak / I8_MAX if peak else 1.0
    if not np.isfinite(scale) or scale <= 0:
        raise ValueError("scale must be a finite positive number")
    q = np.rint(real / scale).clip(I8_MIN, I8_MAX).astype(np.int8)
    return Int8Tensor(q, float(scale))


def dequantize(tensor: Int8Tensor) -> np.ndarray:
    return tensor.values.astype(np.float64) * tensor.scale


def requantize_int32(
    acc: np.ndarray,
    bias: np.ndarray | int,
    scale_mult: int,
    scale_shift: int,
    *,
    relu: bool = False,
) -> np.ndarray:
    """Mirror ``rtl/ml_postprocess.sv`` using integer arithmetic.

    The multiplier is signed and the shift is arithmetic. Results saturate to
    signed INT8 after optional ReLU; this is the hardware contract used when a
    calibrated floating-point scale is converted into integer parameters.
    """

    if scale_shift < 0 or scale_shift > 63:
        raise ValueError("scale_shift must be in 0..63")
    acc64 = np.asarray(acc, dtype=np.int64)
    bias64 = np.asarray(bias, dtype=np.int64)
    shifted = ((acc64 + bias64) * np.int64(scale_mult)) >> scale_shift
    if relu:
        shifted = np.maximum(shifted, 0)
    return np.clip(shifted, I8_MIN, I8_MAX).astype(np.int8)


def quantize_multiplier(real_scale: float) -> tuple[int, int]:
    """Approximate a positive real scale as ``multiplier / 2**shift``.

    The result is directly consumable by ``rtl/ml_postprocess.sv``. Keeping
    the multiplier signed and below INT32_MAX leaves room for the RTL product
    while retaining high precision for normal neural-network scales.
    """

    if not np.isfinite(real_scale) or real_scale <= 0:
        raise ValueError("real_scale must be finite and positive")
    shift = 30
    multiplier = int(np.rint(real_scale * (1 << shift)))
    while multiplier > I32_MAX and shift > 0:
        shift -= 1
        multiplier = int(np.rint(real_scale * (1 << shift)))
    if multiplier <= 0 or multiplier > I32_MAX:
        raise ValueError("real_scale is outside the representable range")
    return multiplier, shift


def _checked_int32(values: np.ndarray) -> np.ndarray:
    """Return int32 values, failing instead of silently wrapping."""

    values = np.asarray(values, dtype=np.int64)
    if values.size and (values.min() < I32_MIN or values.max() > I32_MAX):
        raise OverflowError("INT32 accumulator overflow")
    return values.astype(np.int32)


def tiled_gemm_int8(
    a: np.ndarray,
    b: np.ndarray,
    *,
    tile_m: int = 4,
    tile_n: int = 4,
    tile_k: int = 16,
) -> np.ndarray:
    """Compute ``a @ b`` as INT8 tiles with an INT32 output.

    The tile boundaries mirror the future controller: K tiles accumulate into
    the same output tile, while M/N edge tiles are zero-padded conceptually.
    """

    a = np.asarray(a, dtype=np.int8)
    b = np.asarray(b, dtype=np.int8)
    if a.ndim != 2 or b.ndim != 2 or a.shape[1] != b.shape[0]:
        raise ValueError(f"incompatible GEMM shapes: {a.shape} and {b.shape}")
    if min(tile_m, tile_n, tile_k) <= 0:
        raise ValueError("tile dimensions must be positive")

    m, k = a.shape
    _, n = b.shape
    out = np.zeros((m, n), dtype=np.int64)
    for m0 in range(0, m, tile_m):
        for n0 in range(0, n, tile_n):
            tile = np.zeros((min(tile_m, m - m0), min(tile_n, n - n0)), dtype=np.int64)
            for k0 in range(0, k, tile_k):
                ak = a[m0 : m0 + tile_m, k0 : k0 + tile_k].astype(np.int64)
                bk = b[k0 : k0 + tile_k, n0 : n0 + tile_n].astype(np.int64)
                tile += ak @ bk
                _checked_int32(tile)
            out[m0 : m0 + tile.shape[0], n0 : n0 + tile.shape[1]] = tile
    return _checked_int32(out)


@dataclass(frozen=True)
class QuantizedLinear:
    """One quantized fully-connected layer, with per-tensor scales."""

    weights: Int8Tensor  # shape: out_features x in_features
    bias: np.ndarray  # real-valued bias, shape: out_features
    output_scale: float

    def __post_init__(self) -> None:
        if self.weights.values.ndim != 2:
            raise ValueError("weights must be a matrix")
        bias = np.asarray(self.bias, dtype=np.float64)
        if bias.shape != (self.weights.values.shape[0],):
            raise ValueError("bias shape must equal the number of output features")
        if not np.isfinite(self.output_scale) or self.output_scale <= 0:
            raise ValueError("output_scale must be positive and finite")
        object.__setattr__(self, "bias", bias)

    @property
    def in_features(self) -> int:
        return self.weights.values.shape[1]

    @property
    def out_features(self) -> int:
        return self.weights.values.shape[0]

    def run(self, x: Int8Tensor, *, tile_m: int = 4, tile_n: int = 4, tile_k: int = 16) -> Int8Tensor:
        if x.values.ndim != 2 or x.values.shape[1] != self.in_features:
            raise ValueError("input shape does not match layer")
        acc = tiled_gemm_int8(
            x.values,
            self.weights.values.T,
            tile_m=tile_m,
            tile_n=tile_n,
            tile_k=tile_k,
        ).astype(np.int64)
        real = acc * (x.scale * self.weights.scale) + self.bias
        return quantize_symmetric(real, scale=self.output_scale)

    def run_integer_contract(
        self,
        x: Int8Tensor,
        *,
        relu: bool = False,
        tile_m: int = 4,
        tile_n: int = 4,
        tile_k: int = 16,
    ) -> Int8Tensor:
        """Run the layer using the same integer post-process as the RTL."""

        if x.values.ndim != 2 or x.values.shape[1] != self.in_features:
            raise ValueError("input shape does not match layer")
        acc = tiled_gemm_int8(
            x.values,
            self.weights.values.T,
            tile_m=tile_m,
            tile_n=tile_n,
            tile_k=tile_k,
        )
        accumulator_scale = x.scale * self.weights.scale
        bias_acc = np.rint(self.bias / accumulator_scale).astype(np.int64)
        multiplier, shift = quantize_multiplier(accumulator_scale / self.output_scale)
        values = requantize_int32(
            acc,
            bias_acc,
            multiplier,
            shift,
            relu=relu,
        )
        return Int8Tensor(values, self.output_scale)


@dataclass(frozen=True)
class QuantizedMLP:
    hidden: QuantizedLinear
    output: QuantizedLinear

    def run(self, x: Int8Tensor, *, tile_m: int = 4, tile_n: int = 4, tile_k: int = 16) -> np.ndarray:
        hidden = self.hidden.run(x, tile_m=tile_m, tile_n=tile_n, tile_k=tile_k)
        hidden_relu = Int8Tensor(np.maximum(hidden.values, 0).astype(np.int8), hidden.scale)
        logits = self.output.run(hidden_relu, tile_m=tile_m, tile_n=tile_n, tile_k=tile_k)
        return logits.values.argmax(axis=1)

    def run_integer_contract(
        self,
        x: Int8Tensor,
        *,
        tile_m: int = 4,
        tile_n: int = 4,
        tile_k: int = 16,
    ) -> np.ndarray:
        """Run both layers using the RTL multiplier/shift contract."""

        hidden = self.hidden.run_integer_contract(
            x, relu=True, tile_m=tile_m, tile_n=tile_n, tile_k=tile_k
        )
        logits = self.output.run_integer_contract(
            hidden, tile_m=tile_m, tile_n=tile_n, tile_k=tile_k
        )
        return logits.values.argmax(axis=1)


def make_deterministic_mlp(seed: int = 2026) -> QuantizedMLP:
    """Create a reproducible 784->128->10 network for integration tests."""

    rng = np.random.default_rng(seed)
    w1_real = rng.normal(0.0, 0.08, (128, 784))
    w2_real = rng.normal(0.0, 0.08, (10, 128))
    w1 = quantize_symmetric(w1_real)
    w2 = quantize_symmetric(w2_real)
    return QuantizedMLP(
        hidden=QuantizedLinear(w1, np.zeros(128), output_scale=0.05),
        output=QuantizedLinear(w2, np.zeros(10), output_scale=0.05),
    )
