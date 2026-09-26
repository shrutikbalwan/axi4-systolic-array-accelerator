#!/usr/bin/env bash
# Everything CI runs, runnable locally. Needs verilator, iverilog, yosys on PATH
# and a Python with cocotb>=2.1, numpy, cocotbext-axi.
#
#   scripts/run_checks.sh            # lint + array tb + synth + cocotb (Icarus and Verilator)
#   SIMS=icarus scripts/run_checks.sh
#
# Note: Verilator's generated makefiles cannot build inside a path that
# contains spaces; run from a checkout whose path has none.
set -euo pipefail
cd "$(dirname "$0")/.."

SIMS=${SIMS:-"icarus verilator"}
SIZES=${SIZES:-"4 8"}
PYTHON=${PYTHON:-python3}
RTL="rtl/reset_sync.sv rtl/pe_mac.sv rtl/systolic_array.sv rtl/ml_postprocess.sv rtl/ml_int8_packer.sv rtl/tile_scheduler.sv rtl/dual_bank_buffer.sv rtl/ping_pong_bank_manager.sv rtl/tile_accumulator.sv rtl/axi4_read_dma.sv rtl/axi4_write_dma.sv rtl/dma_descriptor_ctrl.sv rtl/systolic_tile_adapter.sv rtl/tiled_compute_chain.sv rtl/tiled_gemm_controller.sv rtl/tiled_ml_inference_core.sv rtl/tiled_matrix_tile_buffer.sv rtl/tiled_stream_gemm_top.sv rtl/tiled_dma_shell.sv rtl/tiled_axi4_gemm_top.sv rtl/axi_lite_slave.sv rtl/accel_ctrl.sv rtl/systolic_accel_top.sv"
BUILD=${BUILD:-build}
mkdir -p "$BUILD"

echo "== quantized ML reference regression =="
$PYTHON -m unittest discover -s ml -p 'test_*.py'

echo "== portable C driver compile check =="
if command -v gcc >/dev/null 2>&1; then
    gcc -std=c11 -Wall -Wextra -Werror -Isw -c sw/test_compile.c -o "$BUILD/driver_test.o"
    echo "   C headers compile cleanly"
else
    echo "   GCC unavailable; C driver compile skipped"
fi

echo "== tiled ML benchmark reference =="
$PYTHON ml/benchmark.py --m 32 --n 32 --k 64 > "$BUILD/ml_benchmark.txt"
cat "$BUILD/ml_benchmark.txt"

echo "== lint (verilator -Wall, warnings are fatal) =="
for cfg in "4 16" "8 16" "16 16" "8 64"; do
    set -- $cfg
    verilator --lint-only -Wall -GN="$1" -GKMAX="$2" $RTL --top-module systolic_accel_top
    echo "   N=$1 KMAX=$2 clean"
done

echo "== lint connected tiled AXI4/ML top =="
# The connected composition intentionally adapts runtime 32-bit descriptors to
# narrower tile-local counters and contains a few procedural temporaries used
# only for address remapping. Keep the strict legacy-core lint above, while
# documenting these composition-level waivers instead of hiding all warnings.
verilator --lint-only -Wall \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ \
    -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -GARRAY_N=4 -GMAX_M=64 -GMAX_N=64 -GMAX_K=64 \
    $RTL --top-module tiled_axi4_gemm_top
echo "   tiled_axi4_gemm_top clean"

echo "== illegal parameters must not elaborate =="
if iverilog -g2012 -o /dev/null -s systolic_accel_top -Psystolic_accel_top.N=2 $RTL 2>/dev/null; then
    echo "   N=2 elaborated but must not"; exit 1
fi
echo "   N=2 rejected"

echo "== array regression (tb/tb_array.sv, Verilator) =="
for cfg in "4 4" "4 1" "4 9" "8 8" "8 3" "16 16"; do
    set -- $cfg
    dir="$BUILD/tb_array_N$1_K$2"
    verilator --binary --timing -Wno-TIMESCALEMOD -GN="$1" -GK="$2" \
        rtl/pe_mac.sv rtl/systolic_array.sv tb/tb_array.sv --top-module tb_array \
        -Mdir "$dir" > "$dir.build.log" 2>&1 || { cat "$dir.build.log"; exit 1; }
    "$dir/Vtb_array" > "$dir.log"
    grep -q '^PASS$' "$dir.log" || { cat "$dir.log"; exit 1; }
    echo "   N=$1 K=$2 $(grep -E 'runs=' "$dir.log" | sed 's/.*runs=/runs=/')"
done

echo "== synthesis smoke test (yosys, generic cells) =="
for n in 4 8; do
    yosys -q -l "$BUILD/synth_N$n.log" -p "
        read_verilog -sv $RTL
        chparam -set N $n systolic_accel_top
        synth -top systolic_accel_top -flatten
        check -assert
        select -assert-none t:\$dlatch t:\$_DLATCH_*
        tee -o $BUILD/synth_N$n.stat stat
    "
    cells=$(grep -m1 -E '^ +[0-9]+ +cells$|Number of cells' "$BUILD/synth_N$n.stat" | grep -oE '[0-9]+' | head -1)
    echo "   N=$n: elaborates, no latches, $cells cells"
done

echo "== formal AXI protocol and ownership checks =="
if command -v sby >/dev/null 2>&1; then
    # The [files] paths in each harness are relative to formal/.
    (cd formal && sby -f axi_lite_slave.sby)
    (cd formal && sby -f axi4_read_dma.sby)
    (cd formal && sby -f axi4_write_dma.sby)
    (cd formal && sby -f ping_pong_bank_manager.sby)
    echo "   AXI-Lite, AXI4 DMA, and ping-pong ownership proofs passed"
else
    echo "   SymbiYosys unavailable; formal proof skipped"
fi

echo "== cocotb regression =="
for sim in $SIMS; do
    for tb in array accel tile scheduler chain read_dma write_dma tiled ml_core stream_gemm descriptor ml_packer; do
        for n in $SIZES; do
            log="$BUILD/cocotb_${sim}_${tb}_N$n.log"
            (cd sim && make SIM="$sim" TB="$tb" N="$n" \
                COCOTB_RESULTS_FILE="results_${sim}_${tb}_N$n.xml" > "../$log" 2>&1) || true
            summary=$(grep -oE 'TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+' "$log" | tail -1)
            if [ -z "$summary" ] || ! echo "$summary" | grep -q 'FAIL=0'; then
                tail -40 "$log"; echo "   $sim $tb N=$n FAILED"; exit 1
            fi
            echo "   $sim $tb N=$n: $summary"
        done
    done
done

echo "ALL CHECKS PASSED"
