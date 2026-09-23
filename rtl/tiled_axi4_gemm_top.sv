// -----------------------------------------------------------------------------
// tiled_axi4_gemm_top.sv - connected AXI4 DMA + tiled GEMM composition.
//
// Control writes program tiled_dma_shell. Its A/B read streams feed the
// matrix/tile buffer and tiled_stream_gemm_top; the row-major INT32 result
// stream feeds the shell's C write DMA. The original AXI4-Lite accelerator
// remains unchanged and is not replaced by this experimental top.
// -----------------------------------------------------------------------------
`default_nettype none

module tiled_axi4_gemm_top #(
    parameter int ADDR_W    = 32,
    parameter int DATA_W    = 32,
    parameter int MAX_BURST = 16,
    parameter int ARRAY_N   = 4,
    parameter int MAX_M     = 64,
    parameter int MAX_N     = 64,
    parameter int MAX_K     = 64
) (
    input wire clk, input wire rst_n,
    input wire reg_wr_en, input wire [11:0] reg_wr_addr,
    input wire [31:0] reg_wr_data, input wire [3:0] reg_wr_strb,
    output wire [1:0] reg_wr_resp, input wire [11:0] reg_rd_addr,
    output wire [31:0] reg_rd_data, output wire [1:0] reg_rd_resp,
    output wire irq,

    output wire [ADDR_W-1:0] a_axi_araddr, output wire [7:0] a_axi_arlen,
    output wire [2:0] a_axi_arsize, output wire [1:0] a_axi_arburst,
    output wire a_axi_arvalid, input wire a_axi_arready,
    input wire [DATA_W-1:0] a_axi_rdata, input wire [1:0] a_axi_rresp,
    input wire a_axi_rlast, input wire a_axi_rvalid, output wire a_axi_rready,

    output wire [ADDR_W-1:0] b_axi_araddr, output wire [7:0] b_axi_arlen,
    output wire [2:0] b_axi_arsize, output wire [1:0] b_axi_arburst,
    output wire b_axi_arvalid, input wire b_axi_arready,
    input wire [DATA_W-1:0] b_axi_rdata, input wire [1:0] b_axi_rresp,
    input wire b_axi_rlast, input wire b_axi_rvalid, output wire b_axi_rready,

    output wire [ADDR_W-1:0] c_axi_awaddr, output wire [7:0] c_axi_awlen,
    output wire [2:0] c_axi_awsize, output wire [1:0] c_axi_awburst,
    output wire c_axi_awvalid, input wire c_axi_awready,
    output wire [DATA_W-1:0] c_axi_wdata, output wire [DATA_W/8-1:0] c_axi_wstrb,
    output wire c_axi_wlast, output wire c_axi_wvalid, input wire c_axi_wready,
    input wire [1:0] c_axi_bresp, input wire c_axi_bvalid, output wire c_axi_bready
);

    wire shell_job_start, shell_job_busy, shell_job_done, shell_job_error;
    wire compute_busy, compute_done, compute_error;
    logic [31:0] perf_active_q, perf_tile_count_q;
    logic [63:0] perf_mac_q;
    wire [31:0] shell_m, shell_n, shell_k;
    wire [31:0] shell_tm, shell_tn, shell_tk;
    wire signed [31:0] shell_bias, shell_scale;
    wire shell_relu;
    wire [5:0] shell_shift;
    wire shell_output_int8;
    wire [DATA_W-1:0] a_stream_data, b_stream_data, c_stream_data;
    wire a_stream_valid, b_stream_valid, c_stream_valid;
    wire a_stream_ready, b_stream_ready, c_stream_ready;
    wire a_stream_last, b_stream_last, c_stream_last;
    wire [31:0] ml_stream_data;
    wire ml_stream_valid, ml_stream_ready, ml_stream_last;
    wire raw_c_ready;
    wire signed [31:0] raw_c_data;
    wire raw_c_valid, raw_c_last;
    wire [63:0] perf_mac_target = {32'd0, shell_m} * {32'd0, shell_n} * {32'd0, shell_k};
    wire [63:0] perf_m_tiles = (shell_tm != 0) ? (({32'd0, shell_m} + shell_tm - 1) / shell_tm) : 0;
    wire [63:0] perf_n_tiles = (shell_tn != 0) ? (({32'd0, shell_n} + shell_tn - 1) / shell_tn) : 0;
    wire [63:0] perf_k_tiles = (shell_tk != 0) ? (({32'd0, shell_k} + shell_tk - 1) / shell_tk) : 0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_active_q <= 0;
            perf_mac_q <= 0;
            perf_tile_count_q <= 0;
        end else if (shell_job_start) begin
            perf_active_q <= 0;
            perf_mac_q <= perf_mac_target;
            if ((shell_tm != 0) && (shell_tn != 0) && (shell_tk != 0))
                perf_tile_count_q <= perf_m_tiles * perf_n_tiles * perf_k_tiles;
            else
                perf_tile_count_q <= 0;
        end else if (compute_busy) begin
            perf_active_q <= perf_active_q + 1'b1;
        end
    end
    wire unused_status = shell_job_busy ^ shell_job_done ^ shell_job_error ^
                         (^shell_bias) ^ (^shell_scale) ^ shell_relu ^ (^shell_shift) ^ shell_output_int8;

    tiled_dma_shell #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .MAX_BURST(MAX_BURST)) u_dma (
        .clk(clk), .rst_n(rst_n),
        .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
        .reg_wr_strb(reg_wr_strb), .reg_wr_resp(reg_wr_resp),
        .reg_rd_addr(reg_rd_addr), .reg_rd_data(reg_rd_data),
        .reg_rd_resp(reg_rd_resp), .irq(irq),
        .job_start(shell_job_start), .job_busy(shell_job_busy),
        .job_done(shell_job_done), .job_error(shell_job_error),
        .job_matrix_m(shell_m), .job_matrix_n(shell_n), .job_matrix_k(shell_k),
        .job_tile_m(shell_tm), .job_tile_n(shell_tn), .job_tile_k(shell_tk),
        .job_post_bias(shell_bias), .job_post_scale(shell_scale),
        .job_post_relu(shell_relu), .job_post_shift(shell_shift),
        .job_output_int8(shell_output_int8),
        .a_axi_araddr(a_axi_araddr), .a_axi_arlen(a_axi_arlen),
        .a_axi_arsize(a_axi_arsize), .a_axi_arburst(a_axi_arburst),
        .a_axi_arvalid(a_axi_arvalid), .a_axi_arready(a_axi_arready),
        .a_axi_rdata(a_axi_rdata), .a_axi_rresp(a_axi_rresp),
        .a_axi_rlast(a_axi_rlast), .a_axi_rvalid(a_axi_rvalid), .a_axi_rready(a_axi_rready),
        .b_axi_araddr(b_axi_araddr), .b_axi_arlen(b_axi_arlen),
        .b_axi_arsize(b_axi_arsize), .b_axi_arburst(b_axi_arburst),
        .b_axi_arvalid(b_axi_arvalid), .b_axi_arready(b_axi_arready),
        .b_axi_rdata(b_axi_rdata), .b_axi_rresp(b_axi_rresp),
        .b_axi_rlast(b_axi_rlast), .b_axi_rvalid(b_axi_rvalid), .b_axi_rready(b_axi_rready),
        .c_axi_awaddr(c_axi_awaddr), .c_axi_awlen(c_axi_awlen),
        .c_axi_awsize(c_axi_awsize), .c_axi_awburst(c_axi_awburst),
        .c_axi_awvalid(c_axi_awvalid), .c_axi_awready(c_axi_awready),
        .c_axi_wdata(c_axi_wdata), .c_axi_wstrb(c_axi_wstrb), .c_axi_wlast(c_axi_wlast),
        .c_axi_wvalid(c_axi_wvalid), .c_axi_wready(c_axi_wready),
        .c_axi_bresp(c_axi_bresp), .c_axi_bvalid(c_axi_bvalid), .c_axi_bready(c_axi_bready),
        .compute_busy_in(compute_busy), .compute_done_in(compute_done),
        .compute_error_in(compute_error),
        .perf_active_cycles(perf_active_q), .perf_mac_count(perf_mac_q),
        .perf_tile_count(perf_tile_count_q),
        .a_stream_data(a_stream_data), .a_stream_valid(a_stream_valid),
        .a_stream_ready(a_stream_ready), .a_stream_last(a_stream_last),
        .b_stream_data(b_stream_data), .b_stream_valid(b_stream_valid),
        .b_stream_ready(b_stream_ready), .b_stream_last(b_stream_last),
        .c_stream_data(c_stream_data), .c_stream_valid(c_stream_valid),
        .c_stream_ready(c_stream_ready), .c_stream_last(c_stream_last)
    );

    assign raw_c_ready = shell_output_int8 ? ml_stream_ready : c_stream_ready;

    ml_int8_packer u_ml_packer (
        .clk(clk), .rst_n(rst_n), .bias(shell_bias), .scale_mult(shell_scale),
        .relu_en(shell_relu), .scale_shift(shell_shift),
        .in_valid(raw_c_valid && shell_output_int8), .in_ready(ml_stream_ready),
        .in_data(raw_c_data), .in_last(raw_c_last),
        .out_valid(ml_stream_valid), .out_ready(c_stream_ready),
        .out_data(ml_stream_data), .out_last(ml_stream_last)
    );

    assign c_stream_data = shell_output_int8 ? ml_stream_data : raw_c_data;
    assign c_stream_valid = shell_output_int8 ? ml_stream_valid : raw_c_valid;
    assign c_stream_last = shell_output_int8 ? ml_stream_last : raw_c_last;

    tiled_stream_gemm_top #(.ARRAY_N(ARRAY_N), .MAX_M(MAX_M), .MAX_N(MAX_N), .MAX_K(MAX_K)) u_compute (
        .clk(clk), .rst_n(rst_n), .start_job(shell_job_start),
        .matrix_m(shell_m), .matrix_n(shell_n), .matrix_k(shell_k),
        .tile_m_cfg(shell_tm), .tile_n_cfg(shell_tn), .tile_k_cfg(shell_tk),
        .busy(compute_busy), .done(compute_done), .error(compute_error),
        .a_in_data(a_stream_data), .a_in_valid(a_stream_valid), .a_in_ready(a_stream_ready),
        .b_in_data(b_stream_data), .b_in_valid(b_stream_valid), .b_in_ready(b_stream_ready),
        .c_out_data(raw_c_data), .c_out_valid(raw_c_valid),
        .c_out_ready(raw_c_ready), .c_out_last(raw_c_last)
    );

    /* verilator lint_off UNUSED */
    wire unused_status_pin = unused_status;
    /* verilator lint_on UNUSED */

endmodule

`default_nettype wire
