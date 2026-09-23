`default_nettype none

module ping_pong_bank_manager_properties (
    input wire clk,
    input wire rst_n,
    input wire fill_req,
    input wire fill_gnt,
    input wire fill_done,
    input wire consume_valid,
    input wire consume_ready,
    input wire consume_done,
    input wire fill_active,
    input wire consume_active,
    input wire busy,
    input wire error
);
    // Keep the properties in the immediate-assertion subset understood by
    // both Yosys/SymbiYosys and commercial SystemVerilog formal tools.
    always @(posedge clk) begin
        if (rst_n) begin
            if ($past(rst_n) && $past(fill_done && !fill_active))
                assert(error);
            if ($past(rst_n) && $past(consume_done && !consume_active))
                assert(error);
            if (fill_gnt)
                assert(fill_req);
            if ($past(rst_n) && $past(error))
                assert(error);
            if ($past(rst_n) && $past((fill_req && fill_gnt) ||
                                      (consume_valid && consume_ready)))
                assert(busy);
        end
    end
endmodule

`default_nettype wire
