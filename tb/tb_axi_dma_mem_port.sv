// Test wrapper: axi_dma_mem_port + a behavioural 1-cycle synchronous RAM.
`default_nettype none
module tb_axi_dma_mem_port #(
    parameter logic [31:0] BASE  = 32'h4000_0000,
    parameter int          DEPTH = 1024
) (
    input  wire clk, input wire rst_n,
    input  wire [31:0] a_araddr, input wire [7:0] a_arlen, input wire [2:0] a_arsize,
    input  wire [1:0] a_arburst, input wire a_arvalid, output wire a_arready,
    output wire [31:0] a_rdata, output wire [1:0] a_rresp, output wire a_rlast,
    output wire a_rvalid, input wire a_rready,
    input  wire [31:0] b_araddr, input wire [7:0] b_arlen, input wire [2:0] b_arsize,
    input  wire [1:0] b_arburst, input wire b_arvalid, output wire b_arready,
    output wire [31:0] b_rdata, output wire [1:0] b_rresp, output wire b_rlast,
    output wire b_rvalid, input wire b_rready,
    input  wire [31:0] c_awaddr, input wire [7:0] c_awlen, input wire [2:0] c_awsize,
    input  wire [1:0] c_awburst, input wire c_awvalid, output wire c_awready,
    input  wire [31:0] c_wdata, input wire [3:0] c_wstrb, input wire c_wlast,
    input  wire c_wvalid, output wire c_wready,
    output wire [1:0] c_bresp, output wire c_bvalid, input wire c_bready
);
    localparam int AW = $clog2(DEPTH);
    wire [AW-1:0] mem_addr;
    wire [3:0]    mem_we;
    wire [31:0]   mem_wdata;
    logic [31:0]  mem_rdata;
    logic [31:0]  ram [0:DEPTH-1];

    always_ff @(posedge clk) begin
        for (int i = 0; i < 4; i++)
            if (mem_we[i]) ram[mem_addr][i*8 +: 8] <= mem_wdata[i*8 +: 8];
        mem_rdata <= ram[mem_addr];
    end

    axi_dma_mem_port #(.BASE(BASE), .DEPTH(DEPTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .a_araddr(a_araddr), .a_arlen(a_arlen), .a_arsize(a_arsize), .a_arburst(a_arburst),
        .a_arvalid(a_arvalid), .a_arready(a_arready), .a_rdata(a_rdata), .a_rresp(a_rresp),
        .a_rlast(a_rlast), .a_rvalid(a_rvalid), .a_rready(a_rready),
        .b_araddr(b_araddr), .b_arlen(b_arlen), .b_arsize(b_arsize), .b_arburst(b_arburst),
        .b_arvalid(b_arvalid), .b_arready(b_arready), .b_rdata(b_rdata), .b_rresp(b_rresp),
        .b_rlast(b_rlast), .b_rvalid(b_rvalid), .b_rready(b_rready),
        .c_awaddr(c_awaddr), .c_awlen(c_awlen), .c_awsize(c_awsize), .c_awburst(c_awburst),
        .c_awvalid(c_awvalid), .c_awready(c_awready), .c_wdata(c_wdata), .c_wstrb(c_wstrb),
        .c_wlast(c_wlast), .c_wvalid(c_wvalid), .c_wready(c_wready),
        .c_bresp(c_bresp), .c_bvalid(c_bvalid), .c_bready(c_bready),
        .mem_addr(mem_addr), .mem_we(mem_we), .mem_wdata(mem_wdata), .mem_rdata(mem_rdata)
    );
endmodule
`default_nettype wire
