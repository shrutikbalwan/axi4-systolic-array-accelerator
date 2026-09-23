import unittest

import numpy as np

from quantized_mlp import (
    Int8Tensor,
    QuantizedLinear,
    make_deterministic_mlp,
    quantize_symmetric,
    quantize_multiplier,
    requantize_int32,
    tiled_gemm_int8,
)


class QuantizedMLPTests(unittest.TestCase):
    def test_tiled_gemm_matches_numpy_for_uneven_tiles(self):
        rng = np.random.default_rng(1)
        a = rng.integers(-128, 128, (7, 19), dtype=np.int8)
        b = rng.integers(-128, 128, (19, 11), dtype=np.int8)
        got = tiled_gemm_int8(a, b, tile_m=4, tile_n=4, tile_k=16)
        want = a.astype(np.int64) @ b.astype(np.int64)
        np.testing.assert_array_equal(got, want)
        self.assertEqual(got.dtype, np.int32)

    def test_int8_extremes_fit_int32(self):
        a = np.full((4, 16), -128, dtype=np.int8)
        b = np.full((16, 4), 127, dtype=np.int8)
        got = tiled_gemm_int8(a, b)
        np.testing.assert_array_equal(got, np.full((4, 4), -260096, dtype=np.int32))

    def test_linear_layer_matches_explicit_reference(self):
        x = quantize_symmetric(np.array([[0.25, -0.5, 0.75]], dtype=np.float64))
        w = quantize_symmetric(np.array([[1.0, -0.5, 0.25], [-0.25, 0.5, 1.0]]))
        layer = QuantizedLinear(w, np.array([0.1, -0.2]), output_scale=0.01)
        got = layer.run(x, tile_m=2, tile_n=2, tile_k=2)
        acc = x.values.astype(np.int64) @ w.values.T.astype(np.int64)
        real = acc * x.scale * w.scale + layer.bias
        want = np.rint(real / layer.output_scale).clip(-128, 127).astype(np.int8)
        np.testing.assert_array_equal(got.values, want)

    def test_mlp_handles_non_array_sized_dimensions(self):
        model = make_deterministic_mlp()
        x = quantize_symmetric(np.zeros((3, 784), dtype=np.float64))
        predictions = model.run(x, tile_m=4, tile_n=4, tile_k=16)
        self.assertEqual(predictions.shape, (3,))
        self.assertTrue(np.all((predictions >= 0) & (predictions < 10)))

    def test_mlp_integer_contract_handles_non_array_sized_dimensions(self):
        model = make_deterministic_mlp()
        x = quantize_symmetric(np.zeros((3, 784), dtype=np.float64))
        predictions = model.run_integer_contract(x, tile_m=4, tile_n=4, tile_k=16)
        self.assertEqual(predictions.shape, (3,))
        self.assertTrue(np.all((predictions >= 0) & (predictions < 10)))

    def test_integer_requantization_relu_and_saturation(self):
        acc = np.array([[-1000, -1, 0, 1, 1000]], dtype=np.int64)
        bias = np.array([[0, 0, 0, 0, 0]], dtype=np.int64)
        got = requantize_int32(acc, bias, scale_mult=1, scale_shift=0, relu=False)
        np.testing.assert_array_equal(got, [[-128, -1, 0, 1, 127]])
        got_relu = requantize_int32(acc, bias, scale_mult=1, scale_shift=0, relu=True)
        np.testing.assert_array_equal(got_relu, [[0, 0, 0, 1, 127]])

    def test_integer_linear_contract_tracks_float_scale(self):
        x = quantize_symmetric(np.array([[0.25, -0.5, 0.75]], dtype=np.float64))
        w = quantize_symmetric(np.array([[1.0, -0.5, 0.25], [-0.25, 0.5, 1.0]]))
        layer = QuantizedLinear(w, np.array([0.1, -0.2]), output_scale=0.01)
        got = layer.run_integer_contract(x, tile_m=2, tile_n=2, tile_k=2)
        want = layer.run(x, tile_m=2, tile_n=2, tile_k=2)
        np.testing.assert_allclose(got.values, want.values, atol=1)

    def test_multiplier_is_rtl_representable(self):
        multiplier, shift = quantize_multiplier(0.125)
        self.assertGreater(multiplier, 0)
        self.assertGreaterEqual(shift, 0)
        self.assertLessEqual(multiplier, (1 << 31) - 1)


if __name__ == "__main__":
    unittest.main()
