# -----------------------------------------------------------------------------
# design.sdc - timing constraints for systolic_accel_top
#
# Single clock domain (aclk). The AXI4-Lite interface is assumed to be driven
# and sampled by logic on the same clock, with 30% of the period budgeted
# outside this block on each side.
#
# STATUS: written against the SDC subset OpenSTA accepts; NOT yet validated by
# a place-and-route run (no PDK in the development environment).
# -----------------------------------------------------------------------------

set clk_period 10.0 ;# ns, 100 MHz target
set io_budget  [expr {0.3 * $clk_period}]

create_clock -name aclk -period $clk_period [get_ports aclk]
set_clock_uncertainty 0.25 [get_clocks aclk]
set_clock_transition  0.15 [get_clocks aclk]

# AXI4-Lite inputs and outputs
set axi_inputs [get_ports {s_axi_awaddr* s_axi_awprot* s_axi_awvalid \
                           s_axi_wdata* s_axi_wstrb* s_axi_wvalid s_axi_bready \
                           s_axi_araddr* s_axi_arprot* s_axi_arvalid s_axi_rready}]
set axi_outputs [get_ports {s_axi_awready s_axi_wready s_axi_bresp* s_axi_bvalid \
                            s_axi_arready s_axi_rdata* s_axi_rresp* s_axi_rvalid irq}]

set_input_delay  $io_budget -clock aclk $axi_inputs
set_output_delay $io_budget -clock aclk $axi_outputs

# aresetn is asynchronous and goes only to reset_sync, whose output is released
# synchronously. The raw pin therefore has no timing relationship to aclk.
set_false_path -from [get_ports aresetn]

set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 [all_inputs]
set_load 0.02 [all_outputs]
