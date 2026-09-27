#!/usr/bin/env python3
"""Build + run the RISC-V SoC simulation and turn its console into a verdict.

    python3 soc/run_soc_sim.py              # N=4
    python3 soc/run_soc_sim.py --array-n 8
    python3 soc/run_soc_sim.py --mem-port bus   # DMA via the CPU interconnect

Writes build/soc/n<N>/console.log and build/soc/n<N>/results.json and exits
non-zero unless the firmware printed "SOC TEST PASSED" with zero failures and
bit-exact CRCs. Used by CI.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODEL_H = ROOT / "soc" / "firmware" / "model_data.h"


def golden():
    text = MODEL_H.read_text()
    get = lambda name: re.search(rf"#define {name} (\S+)", text).group(1)
    return {
        "hidden_crc": get("GOLDEN_HIDDEN_CRC").lower().removeprefix("0x").rstrip("u"),
        "logits_crc": get("GOLDEN_LOGITS_CRC").lower().removeprefix("0x").rstrip("u"),
        "correct": int(get("GOLDEN_CORRECT")),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--array-n", type=int, default=4, choices=(4, 8))
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--mem-port", default="direct", choices=("direct", "bus"))
    args = ap.parse_args()

    suffix = "" if args.mem_port == "direct" else "_bus"
    out_dir = ROOT / "build" / "soc" / f"n{args.array_n}{suffix}"
    out_dir.mkdir(parents=True, exist_ok=True)
    log_path = out_dir / "console.log"
    cmd = [sys.executable, str(ROOT / "soc" / "accel_soc.py"), "--array-n", str(args.array_n),
           "--mem-port", args.mem_port]
    with log_path.open("w") as log:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                errors="replace")
        for line in proc.stdout:
            log.write(line)
            if line.startswith(("RESULT", "FAIL", "SOC TEST", "[", "    ", "===")):
                sys.stdout.write(line)
        rc = proc.wait(timeout=args.timeout)
    console = log_path.read_text(errors="replace")

    results = {}
    for key, value in re.findall(r"^RESULT (\w+)=(\S+)", console, re.M):
        results[key] = int(value) if value.isdigit() else value
    (out_dir / "results.json").write_text(json.dumps(results, indent=2) + "\n")

    g = golden()
    problems = []
    if rc != 0:
        problems.append(f"simulator exited with {rc}")
    if "SOC TEST PASSED" not in console:
        problems.append("firmware did not report SOC TEST PASSED")
    if results.get("failures") != 0:
        problems.append(f"firmware failures={results.get('failures')}")
    for prefix in ("", "fused_"):
        for what in ("hidden_crc", "logits_crc"):
            if str(results.get(prefix + what)) != g[what]:
                problems.append(f"{prefix}{what}={results.get(prefix + what)} != golden {g[what]}")
    for key in ("accel_correct", "fused_correct", "cpu_correct"):
        if results.get(key) != g["correct"]:
            problems.append(f"{key}={results.get(key)} != golden {g['correct']}")

    if problems:
        print("\nSoC simulation FAILED:\n  " + "\n  ".join(problems))
        sys.exit(1)
    cpu, fused = results["mlp_cpu_cycles"], results["mlp_fused_cycles"]
    print(f"\nSoC simulation passed: {results['fused_correct']}/{results['images']} correct, "
          f"bit-exact, {cpu / fused:.1f}x faster than the CPU (fused), results in {out_dir}")


if __name__ == "__main__":
    main()
