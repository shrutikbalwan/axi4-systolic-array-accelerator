# Timing template for tiled_axi4_gemm_top. Validate with the target PDK/tool.
set clk_period 10.0
create_clock -name clk -period $clk_period [get_ports clk]
set_clock_uncertainty 0.25 [get_clocks clk]
set_clock_transition 0.15 [get_clocks clk]
set_false_path -from [get_ports rst_n]
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 [all_inputs]
set_load 0.02 [all_outputs]
