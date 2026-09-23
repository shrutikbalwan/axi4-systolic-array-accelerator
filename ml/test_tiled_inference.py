import unittest

import numpy as np

from quantized_mlp import QuantizedLinear, quantize_symmetric
from tiled_inference import SoftwareGemmBackend, run_linear, tiled_gemm


class TiledInferenceTests(unittest.TestCase):
    def test_arbitrary_gemm_is_split_and_accumulated(self):
        rng = np.random.default_rng(33)
        a = rng.integers(-128, 128, (9, 37), dtype=np.int8)
        b = rng.integers(-128, 128, (37, 13), dtype=np.int8)
        got = tiled_gemm(
            SoftwareGemmBackend(array_n=4, kmax=16),
            a,
            b,
            tile_m=4,
            tile_n=4,
            tile_k=16,
        )
        want = a.astype(np.int64) @ b.astype(np.int64)
        np.testing.assert_array_equal(got, want)
        self.assertEqual(got.dtype, np.int32)

    def test_linear_path_matches_quantized_reference(self):
        rng = np.random.default_rng(9)
        x = quantize_symmetric(rng.normal(size=(3, 19)))
        weights = quantize_symmetric(rng.normal(size=(7, 19)))
        bias = rng.normal(size=7)
        layer = QuantizedLinear(weights, bias, output_scale=0.05)
        got = run_linear(
            SoftwareGemmBackend(array_n=4, kmax=16),
            x,
            layer,
            tile_m=4,
            tile_n=4,
            tile_k=16,
            relu=True,
        )
        acc = x.values.astype(np.int64) @ weights.values.T.astype(np.int64)
        want = np.rint(np.maximum(acc * (x.scale * weights.scale) + bias, 0) / 0.05)
        want = want.clip(-128, 127).astype(np.int8)
        np.testing.assert_array_equal(got.values, want)


if __name__ == "__main__":
    unittest.main()
