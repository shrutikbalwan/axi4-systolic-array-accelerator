// -----------------------------------------------------------------------------
// systolic_accel_top.sv - INT8 systolic GEMM accelerator, AXI4-Lite SLAVE.
//
//   aresetn --> reset_sync --> rst_n (async assert, sync de-assert)
//   s_axi_* <--> axi_lite_slave <--reg port--> accel_ctrl <--> systolic_array
//
// The address space is 16 KiB (14 address bits); see docs/register_map.md.
// -----------------------------------------------------------------------------
`default_nettype none

module systolic_accel_top #(
    parameter int N    = 4,     // array is N x N; N*8 must be a multiple of 32
    parameter int KMAX = 16     // largest inner dimension K per run
) (
    input  wire          aclk,
    input  wire          aresetn,

    input  wire  [13:0]  s_axi_awaddr,
    input  wire  [2:0]   s_axi_awprot,
    input  wire          s_axi_awvalid,
    output wire          s_axi_awready,
    input  wire  [31:0]  s_axi_wdata,
    input  wire  [3:0]   s_axi_wstrb,
    input  wire          s_axi_wvalid,
    output wire          s_axi_wready,
    output wire  [1:0]   s_axi_bresp,
    output wire          s_axi_bvalid,
    input  wire          s_axi_bready,
    input  wire  [13:0]  s_axi_araddr,
    input  wire  [2:0]   s_axi_arprot,
    input  wire          s_axi_arvalid,
    output wire          s_axi_arready,
    output wire  [31:0]  s_axi_rdata,
    output wire  [1:0]   s_axi_rresp,
    output wire          s_axi_rvalid,
    input  wire          s_axi_rready,

    output wire          irq            // level: STATUS.DONE & CTRL.IRQ_EN
);

    localparam int IN_W  = 8;
    localparam int ACC_W = 32;

    wire rst_n;

    wire         reg_wr_en;
    wire [13:0]  reg_wr_addr;
    wire [31:0]  reg_wr_data;
    wire [3:0]   reg_wr_strb;
    wire [1:0]   reg_wr_resp;
    wire [13:0]  reg_rd_addr;
    wire [31:0]  reg_rd_data;
    wire [1:0]   reg_rd_resp;

    wire                   arr_en;
    wire                   arr_clr_acc;
    wire                   arr_flush;
    wire [N*IN_W-1:0]      arr_a_flat;
    wire [N*IN_W-1:0]      arr_b_flat;
    wire [N*N*ACC_W-1:0]   arr_acc_flat;

    reset_sync u_reset_sync (
        .clk    (aclk),
        .arst_n (aresetn),
        .rst_n  (rst_n)
    );

    axi_lite_slave #(
        .ADDR_W (14),
        .DATA_W (32)
    ) u_axi (
        .clk           (aclk),
        .rst_n         (rst_n),
        .s_axi_awaddr  (s_axi_awaddr),
        .s_axi_awprot  (s_axi_awprot),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),
        .s_axi_wdata   (s_axi_wdata),
        .s_axi_wstrb   (s_axi_wstrb),
        .s_axi_wvalid  (s_axi_wvalid),
        .s_axi_wready  (s_axi_wready),
        .s_axi_bresp   (s_axi_bresp),
        .s_axi_bvalid  (s_axi_bvalid),
        .s_axi_bready  (s_axi_bready),
        .s_axi_araddr  (s_axi_araddr),
        .s_axi_arprot  (s_axi_arprot),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),
        .s_axi_rdata   (s_axi_rdata),
        .s_axi_rresp   (s_axi_rresp),
        .s_axi_rvalid  (s_axi_rvalid),
        .s_axi_rready  (s_axi_rready),
        .reg_wr_en     (reg_wr_en),
        .reg_wr_addr   (reg_wr_addr),
        .reg_wr_data   (reg_wr_data),
        .reg_wr_strb   (reg_wr_strb),
        .reg_wr_resp   (reg_wr_resp),
        .reg_rd_addr   (reg_rd_addr),
        .reg_rd_data   (reg_rd_data),
        .reg_rd_resp   (reg_rd_resp)
    );

    accel_ctrl #(
        .N     (N),
        .KMAX  (KMAX),
        .IN_W  (IN_W),
        .ACC_W (ACC_W)
    ) u_ctrl (
        .clk          (aclk),
        .rst_n        (rst_n),
        .reg_wr_en    (reg_wr_en),
        .reg_wr_addr  (reg_wr_addr),
        .reg_wr_data  (reg_wr_data),
        .reg_wr_strb  (reg_wr_strb),
        .reg_wr_resp  (reg_wr_resp),
        .reg_rd_addr  (reg_rd_addr),
        .reg_rd_data  (reg_rd_data),
        .reg_rd_resp  (reg_rd_resp),
        .arr_en       (arr_en),
        .arr_clr_acc  (arr_clr_acc),
        .arr_flush    (arr_flush),
        .arr_a_flat   (arr_a_flat),
        .arr_b_flat   (arr_b_flat),
        .arr_acc_flat (arr_acc_flat),
        .irq          (irq)
    );

    systolic_array #(
        .N     (N),
        .IN_W  (IN_W),
        .ACC_W (ACC_W)
    ) u_array (
        .clk      (aclk),
        .rst_n    (rst_n),
        .en       (arr_en),
        .clr_acc  (arr_clr_acc),
        .flush    (arr_flush),
        .a_flat   (arr_a_flat),
        .b_flat   (arr_b_flat),
        .acc_flat (arr_acc_flat)
    );

endmodule

`default_nettype wire
