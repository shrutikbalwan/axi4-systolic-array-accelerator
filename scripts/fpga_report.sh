#!/usr/bin/env bash

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_root="${FPGA_REPORT_DIR:-${repo_root}/build/fpga_report}"

rtl=(
  rtl/reset_sync.sv
  rtl/pe_mac.sv
  rtl/systolic_array.sv
  rtl/ml_postprocess.sv
  rtl/ml_int8_packer.sv
  rtl/tile_scheduler.sv
  rtl/dual_bank_buffer.sv
  rtl/ping_pong_bank_manager.sv
  rtl/tile_accumulator.sv
  rtl/axi4_read_dma.sv
  rtl/axi4_write_dma.sv
  rtl/dma_descriptor_ctrl.sv
  rtl/systolic_tile_adapter.sv
  rtl/tiled_compute_chain.sv
  rtl/tiled_gemm_controller.sv
  rtl/tiled_ml_inference_core.sv
  rtl/tiled_matrix_tile_buffer.sv
  rtl/tiled_stream_gemm_top.sv
  rtl/tiled_dma_shell.sv
  rtl/tiled_axi4_gemm_top.sv
  rtl/axi_lite_slave.sv
  rtl/accel_ctrl.sv
  rtl/systolic_accel_top.sv
)

if (($#)); then
  configurations=("$@")
else
  configurations=(4 8 16)
fi

for tool in yosys nextpnr-ecp5 python3; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    printf 'missing required tool: %s\n' "${tool}" >&2
    exit 127
  fi
done

for n in "${configurations[@]}"; do
  if [[ ! "${n}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'array size must be a positive integer: %s\n' "${n}" >&2
    exit 2
  fi
done

mkdir -p "${output_root}"
cd "${repo_root}"

yosys -V
nextpnr-ecp5 --version

table="${output_root}/table.md"
cat >"${table}" <<'EOF'
**post-route on ECP5 LFE5U-85F, open-source flow**

| Array N | LUTs | FFs | DSPs | BRAMs | Post-route Fmax | Fit |
|---:|---:|---:|---:|---:|---:|:---|
EOF

for n in "${configurations[@]}"; do
  run_dir="${output_root}/N${n}"
  mkdir -p "${run_dir}"

  yosys_cmd="read_verilog -sv ${rtl[*]}; chparam -set N ${n} systolic_accel_top; synth_ecp5 -top systolic_accel_top -json ${run_dir}/out.json"
  printf '\nN=%s synthesis command:\n' "${n}"
  printf 'yosys -q -l "%s/yosys.log" -p "%s"\n' "${run_dir}" "${yosys_cmd}"
  yosys -q -l "${run_dir}/yosys.log" -p "${yosys_cmd}" >"${run_dir}/yosys.stdout.log" 2>&1
  yosys_status=$?
  if ((yosys_status != 0)); then
    tail -n 40 "${run_dir}/yosys.stdout.log" >&2
    printf 'N=%s: synthesis failed (exit %s)\n' "${n}" "${yosys_status}" >&2
    exit "${yosys_status}"
  fi

  printf 'N=%s place-and-route command:\n' "${n}"
  printf 'nextpnr-ecp5 --85k --package CABGA381 --json %s/out.json --freq 100 --timing-allow-fail --report %s/report.json\n' "${run_dir}" "${run_dir}"
  nextpnr-ecp5 \
    --85k \
    --package CABGA381 \
    --json "${run_dir}/out.json" \
    --freq 100 \
    --timing-allow-fail \
    --report "${run_dir}/report.json" \
    >"${run_dir}/nextpnr.log" 2>&1
  nextpnr_status=$?
  if ((nextpnr_status != 0)); then
    if grep -Eiq 'does not fit|exceeds (device )?capacity|overused|too many .* (cells|blocks)|no BELs remaining' "${run_dir}/nextpnr.log"; then
      printf 'N=%s raw nextpnr non-fit report lines:\n' "${n}"
      grep -E 'TRELLIS_COMB:|TRELLIS_FF:|MULT18X18D:|DP16KD:|does not fit|exceeds (device )?capacity|overused|too many .* (cells|blocks)|no BELs remaining' "${run_dir}/nextpnr.log"
      luts=$(grep -E 'TRELLIS_COMB:' "${run_dir}/nextpnr.log" | tail -n 1 | sed -E 's/.*:[[:space:]]*([0-9]+)\/.*/\1/')
      ffs=$(grep -E 'TRELLIS_FF:' "${run_dir}/nextpnr.log" | tail -n 1 | sed -E 's/.*:[[:space:]]*([0-9]+)\/.*/\1/')
      dsps=$(grep -E 'MULT18X18D:' "${run_dir}/nextpnr.log" | tail -n 1 | sed -E 's/.*:[[:space:]]*([0-9]+)\/.*/\1/')
      brams=$(grep -E 'DP16KD:' "${run_dir}/nextpnr.log" | tail -n 1 | sed -E 's/.*:[[:space:]]*([0-9]+)\/.*/\1/')
      printf '| %s | %s | %s | %s | %s | — | **DOES NOT FIT** |\n' \
        "${n}" "${luts}" "${ffs}" "${dsps}" "${brams}" >>"${table}"
      continue
    fi
    tail -n 40 "${run_dir}/nextpnr.log" >&2
    printf 'N=%s: nextpnr failed (exit %s)\n' "${n}" "${nextpnr_status}" >&2
    exit "${nextpnr_status}"
  fi

  printf 'N=%s raw nextpnr report lines:\n' "${n}"
  grep -E 'TRELLIS_COMB:|TRELLIS_FF:|MULT18X18D:|DP16KD:' "${run_dir}/nextpnr.log"
  grep -E 'Max frequency for clock' "${run_dir}/nextpnr.log" | tail -n 1

  report_values=$(python3 -c 'import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
u = d["utilization"]
fmax = min(clock["achieved"] for clock in d["fmax"].values())
print(u["TRELLIS_COMB"]["used"], u["TRELLIS_FF"]["used"], u["MULT18X18D"]["used"], u["DP16KD"]["used"], f"{fmax:.2f}")' \
      "${run_dir}/report.json") || exit $?
  read -r luts ffs dsps brams fmax_unit <<<"${report_values}"
  fmax="${fmax_unit} MHz"
  printf '| %s | %s | %s | %s | %s | %s | FITS |\n' \
    "${n}" "${luts}" "${ffs}" "${dsps}" "${brams}" "${fmax}" >>"${table}"
done

printf '\nGenerated table:\n'
cat "${table}"
