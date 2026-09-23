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


if __name__ == "__main__":
    unittest.main()
