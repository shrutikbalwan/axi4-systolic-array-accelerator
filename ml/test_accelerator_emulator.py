import unittest

import numpy as np

from accelerator_emulator import AcceleratorDescriptor, execute_descriptor


class AcceleratorEmulatorTests(unittest.TestCase):
    def setUp(self):
        rng = np.random.default_rng(2040)
        self.a = rng.integers(-8, 8, (5, 6), dtype=np.int8)
        self.b = rng.integers(-8, 8, (6, 7), dtype=np.int8)

    def test_raw_int32_descriptor_writeback(self):
        desc = AcceleratorDescriptor(5, 7, 6, tile_m=4, tile_n=4, tile_k=4)
        result = execute_descriptor(desc, self.a, self.b)
        np.testing.assert_array_equal(result.output, self.a.astype(np.int64) @ self.b.astype(np.int64))
        self.assertEqual(result.writeback_words.size, 35)
        self.assertEqual(result.mac_count, 5 * 7 * 6)
        self.assertEqual(result.tile_count, 2 * 2 * 2)

    def test_packed_int8_ml_writeback(self):
        desc = AcceleratorDescriptor(
            5, 7, 6, tile_m=4, tile_n=4, tile_k=4,
            relu=True, output_int8=True,
        )
        result = execute_descriptor(desc, self.a, self.b)
        expected = np.maximum(self.a.astype(np.int64) @ self.b.astype(np.int64), 0).clip(-128, 127)
        np.testing.assert_array_equal(result.output, expected)
        self.assertEqual(result.writeback_words.size, (5 * 7 + 3) // 4)

    def test_per_channel_bias_matches_quantized_layer(self):
        """One descriptor now covers a whole QuantizedLinear layer contract."""
        from quantized_mlp import QuantizedLinear, quantize_multiplier, quantize_symmetric

        rng = np.random.default_rng(7)
        layer = QuantizedLinear(
            quantize_symmetric(rng.normal(0.0, 0.2, (10, 32))),
            rng.normal(0.0, 0.5, 10),            # non-zero, per-channel
            output_scale=0.04,
        )
        x = quantize_symmetric(rng.normal(size=(9, layer.in_features)) * 0.5)
        acc_scale = x.scale * layer.weights.scale
        bias = np.rint(layer.bias / acc_scale).astype(np.int64)
        mult, shift = quantize_multiplier(acc_scale / layer.output_scale)
        desc = AcceleratorDescriptor(
            9, layer.out_features, layer.in_features, tile_m=4, tile_n=4, tile_k=16,
            post_scale=mult, post_shift=shift, output_int8=True,
            bias_vector=tuple(int(v) for v in bias),
        )
        self.assertGreater(len(set(bias.tolist())), 5)
        result = execute_descriptor(desc, x.values, layer.weights.values.T)
        scalar_only = execute_descriptor(
            AcceleratorDescriptor(9, 10, 32, post_scale=mult, post_shift=shift, output_int8=True),
            x.values, layer.weights.values.T)
        self.assertFalse(np.array_equal(scalar_only.output, result.output))
        np.testing.assert_array_equal(result.output, layer.run_integer_contract(x).values)

    def test_bias_vector_shape_is_checked(self):
        desc = AcceleratorDescriptor(5, 7, 6, output_int8=True, bias_vector=(1, 2, 3))
        with self.assertRaises(ValueError):
            execute_descriptor(desc, self.a, self.b)


if __name__ == "__main__":
    unittest.main()
