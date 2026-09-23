"""Train and quantize a small real classifier for the accelerator demo.

This optional script uses sklearn's built-in 8x8 handwritten-digits dataset,
so it needs no network or checked-in dataset. The trained floating-point MLP
is converted to the repository's INT8 layer contract and evaluated through the
same tiled backend intended for the RTL/FPGA implementation.

Example:
    python ml/train_digits.py --max-iter 250
"""

from __future__ import annotations

import argparse

import numpy as np

from quantized_mlp import Int8Tensor, QuantizedLinear, QuantizedMLP, quantize_symmetric
from tiled_inference import SoftwareGemmBackend


def build_model(seed: int, max_iter: int):
    from sklearn.datasets import load_digits
    from sklearn.model_selection import train_test_split
    from sklearn.neural_network import MLPClassifier

    dataset = load_digits()
    x = dataset.data.astype(np.float64) / 16.0
    y = dataset.target
    x_train, x_test, y_train, y_test = train_test_split(
        x, y, test_size=0.2, random_state=seed, stratify=y
    )
    fp = MLPClassifier(
        hidden_layer_sizes=(32,),
        activation="relu",
        solver="adam",
        max_iter=max_iter,
        random_state=seed,
    )
    fp.fit(x_train, y_train)

    # sklearn stores weights as [in_features, out_features]; the accelerator
    # contract stores them as [out_features, in_features].
    w1 = quantize_symmetric(fp.coefs_[0].T)
    w2 = quantize_symmetric(fp.coefs_[1].T)
    hidden_float = np.maximum(x_train @ fp.coefs_[0] + fp.intercepts_[0], 0.0)
    hidden_scale = max(float(np.max(np.abs(hidden_float))) / 127.0, 1e-6)
    qmlp = QuantizedMLP(
        hidden=QuantizedLinear(w1, fp.intercepts_[0], output_scale=hidden_scale),
        output=QuantizedLinear(w2, fp.intercepts_[1], output_scale=0.05),
    )
    xq = quantize_symmetric(x_test)
    pred_float = fp.predict(x_test)
    pred_quant = qmlp.run(
        xq,
        tile_m=4,
        tile_n=4,
        tile_k=16,
    )
    pred_integer = qmlp.run_integer_contract(
        xq,
        tile_m=4,
        tile_n=4,
        tile_k=16,
    )
    float_acc = float(np.mean(pred_float == y_test))
    quant_acc = float(np.mean(pred_quant == y_test))
    integer_acc = float(np.mean(pred_integer == y_test))
    return float_acc, quant_acc, integer_acc, len(y_test)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--max-iter", type=int, default=250)
    args = parser.parse_args()
    try:
        float_acc, quant_acc, integer_acc, samples = build_model(args.seed, args.max_iter)
    except ImportError as exc:
        raise SystemExit("Install scikit-learn to run the optional digits demo") from exc
    print(f"samples={samples}")
    print(f"float_accuracy={float_acc:.4f}")
    print(f"quantized_accuracy={quant_acc:.4f}")
    print(f"integer_rtl_contract_accuracy={integer_acc:.4f}")


if __name__ == "__main__":
    main()
