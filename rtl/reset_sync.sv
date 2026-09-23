// -----------------------------------------------------------------------------
// reset_sync.sv - active-low reset: asserted asynchronously, released
// synchronously to clk after two flops (AXI ARESETn requirement, IHI0022 A3.1.2).
// -----------------------------------------------------------------------------
`default_nettype none

module reset_sync (
    input  wire  clk,
    input  wire  arst_n,    // raw, asynchronous
    output wire  rst_n      // async assert, sync de-assert
);

    // sync[1] is the reset for the rest of the design (an async use) and is
    // also clocked here (a sync use). That is what a reset synchroniser is.
    /* verilator lint_off SYNCASYNCNET */
    logic [1:0] sync;
    /* verilator lint_on SYNCASYNCNET */

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) sync <= 2'b00;
        else         sync <= {sync[0], 1'b1};
    end

    assign rst_n = sync[1];

endmodule

`default_nettype wire
