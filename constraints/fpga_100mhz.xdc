# Generic FPGA timing template. Add board-specific create_clock/pin constraints
# in the platform wrapper; this file intentionally contains no invented pins.
create_clock -name aclk -period 10.000 [get_ports clk]
set_clock_uncertainty 0.250 [get_clocks aclk]
