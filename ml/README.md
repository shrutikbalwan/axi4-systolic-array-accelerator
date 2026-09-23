# Quantized ML demonstration

This directory is the software reference model for the accelerator's ML path.
It deliberately has no dependency on PyTorch: the quantization, tiled GEMM,
bias, ReLU and requantization rules are explicit and can be mirrored in RTL.

The first target is a small INT8 fully-connected network suitable for MNIST:

```text
784 INT8 inputs -> 128 INT8 hidden units -> ReLU -> 10 INT8 logits
```

The model is expressed as tiled matrix operations so the same schedule can be
used with the existing `N x N` core today and with the planned DMA/tiled RTL
controller later. Run the self-checking reference tests with:

```sh
python -m unittest discover -s ml -p 'test_*.py'
```

The reference model is not an accuracy claim for a trained network. It is the
bit-accurate contract that a trained/quantized model and the RTL must satisfy.
`requantize_int32` mirrors the RTL post-processing multiplier, arithmetic shift,
ReLU and INT8 saturation rules directly.

`accelerator_emulator.py` adds a descriptor-level golden model for the
connected AXI4 top, including raw INT32 or packed INT8 writeback, tile counts,
and MAC accounting.

For a reproducible trained-model demonstration, install scikit-learn and run:

```sh
python ml/train_digits.py --max-iter 250
```

The script trains a small 64-32-10 MLP on sklearn's built-in handwritten
digits dataset, quantizes both layers, and reports floating-point accuracy,
floating-scale quantized accuracy, and accuracy using the integer
multiplier/shift contract consumed by the RTL.

For a reproducible shape/throughput baseline, run:

```sh
python ml/benchmark.py --m 32 --n 32 --k 64
```
