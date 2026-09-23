# Physical-design targets

Two implementation configurations are provided:

- `openlane/config.json` targets the original `systolic_accel_top` compatibility
  core and uses `constraints/design.sdc`.
- `openlane/config_tiled_axi4_gemm.json` targets the connected DMA/tiled/ML
  top and uses `constraints/tiled_axi4_gemm.sdc`.

Both are 100 MHz starting templates for sky130. Neither is a measured P&R
result in this repository. A credible hardware report must record the chosen
`MAX_M/MAX_N/MAX_K`, utilization, timing slack/Fmax, memory inference, and
power for the actual board or PDK run.
