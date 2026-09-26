// Lightweight formal harness for axi_lite_slave response stability.
// Run through formal/axi_lite_slave.sby when SymbiYosys is available.
`default_nettype none

module axi_lite_slave_formal;
    (* gclk *) logic clk;
    (* anyseq *) logic rst_n;
    (* anyseq *) logic [13:0] awaddr;
    (* anyseq *) logic [2:0] awprot;
    (* anyseq *) logic awvalid;
    (* anyseq *) logic [31:0] wdata;
    (* anyseq *) logic [3:0] wstrb;
    (* anyseq *) logic wvalid;
    (* anyseq *) logic bready;
    (* anyseq *) logic [13:0] araddr;
    (* anyseq *) logic [2:0] arprot;
    (* anyseq *) logic arvalid;
    (* anyseq *) logic rready;
    wire awready, wready, arready;
    wire [1:0] bresp, rresp;
    wire bvalid, rvalid;
    wire [31:0] rdata;
    wire reg_wr_en;
    wire [13:0] reg_wr_addr;
    wire [31:0] reg_wr_data;
    wire [3:0] reg_wr_strb;
    wire [13:0] reg_rd_addr;
    (* anyseq *) logic [1:0] reg_wr_resp;
    (* anyseq *) logic [31:0] reg_rd_data;
    (* anyseq *) logic [1:0] reg_rd_resp;

    axi_lite_slave dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awprot(awprot), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(arprot), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
        .reg_wr_strb(reg_wr_strb), .reg_wr_resp(reg_wr_resp), .reg_rd_addr(reg_rd_addr),
        .reg_rd_data(reg_rd_data), .reg_rd_resp(reg_rd_resp)
    );

    axi_lite_destination_fvip_properties fvip_checker (
        .clk(clk), .rst_n(rst_n),
        .s_axi_bvalid(bvalid), .s_axi_bresp(bresp), .s_axi_bready(bready),
        .s_axi_rvalid(rvalid), .s_axi_rdata(rdata),
        .s_axi_rresp(rresp), .s_axi_rready(rready)
    );

    initial assume(!rst_n);

endmodule

`default_nettype wire
