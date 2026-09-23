// Assertions for binding to axi_lite_slave in a SymbiYosys harness.
// This file is intentionally outside the synthesizable RTL source list.
`default_nettype none

module axi_lite_slave_properties #(
    parameter int DATA_W = 32
) (
    input wire                 clk,
    input wire                 rst_n,
    input wire                 bvalid,
    input wire [1:0]           bresp,
    input wire                 bready,
    input wire                 rvalid,
    input wire [DATA_W-1:0]    rdata,
    input wire [1:0]           rresp,
    input wire                 rready
);

    // AXI responses must remain asserted and stable while back-pressured.
    assert_bvalid_stability:
        assert property (@(posedge clk) disable iff (!rst_n)
            bvalid && !bready |=> bvalid && $stable(bresp));

    assert_rvalid_stability:
        assert property (@(posedge clk) disable iff (!rst_n)
            rvalid && !rready |=> rvalid && $stable({rdata, rresp}));

    cover_bchannel_backpressure:
        cover property (@(posedge clk) disable iff (!rst_n)
            bvalid && !bready ##[1:4] bvalid && bready);

    cover_rchannel_backpressure:
        cover property (@(posedge clk) disable iff (!rst_n)
            rvalid && !rready ##[1:4] rvalid && rready);

endmodule

`default_nettype wire
