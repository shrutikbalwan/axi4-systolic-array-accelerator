`default_nettype none

module ping_pong_bank_manager_formal;
    (* gclk *) logic clk;
    (* anyseq *) logic rst_n;
    (* anyseq *) logic fill_req;
    (* anyseq *) logic fill_done;
    (* anyseq *) logic consume_ready;
    (* anyseq *) logic consume_done;

    wire fill_gnt, fill_bank, consume_valid, consume_bank;
    wire fill_active, consume_active, busy, error;

    ping_pong_bank_manager dut (
        .clk(clk), .rst_n(rst_n), .fill_req(fill_req), .fill_gnt(fill_gnt),
        .fill_bank(fill_bank), .fill_done(fill_done),
        .consume_valid(consume_valid), .consume_ready(consume_ready),
        .consume_bank(consume_bank), .consume_done(consume_done),
        .fill_active(fill_active), .consume_active(consume_active),
        .busy(busy), .error(error)
    );

    ping_pong_bank_manager_properties props (
        .clk(clk), .rst_n(rst_n), .fill_req(fill_req), .fill_gnt(fill_gnt),
        .fill_done(fill_done), .consume_valid(consume_valid),
        .consume_ready(consume_ready), .consume_done(consume_done),
        .fill_active(fill_active), .consume_active(consume_active),
        .busy(busy), .error(error)
    );

    initial assume(!rst_n);
endmodule

`default_nettype wire
