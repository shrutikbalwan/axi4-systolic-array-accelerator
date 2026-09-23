// -----------------------------------------------------------------------------
// tiled_dma_shell.sv - SoC-facing shell for the tiled accelerator path.
//
// This top-level connects descriptor registers to three reusable movers:
//   A and B are read from memory as INT8-packed words;
//   C is written back as 32-bit result words.
// The stream ports are the boundary for tile buffers/scheduler/compute logic.
// The legacy systolic_accel_top remains unchanged and is still the regression
// baseline.
// -----------------------------------------------------------------------------
`default_nettype none

module tiled_dma_shell #(
    parameter int ADDR_W    = 32,
    parameter int DATA_W    = 32,
    parameter int MAX_BURST = 16
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    reg_wr_en,
    input  wire [11:0]             reg_wr_addr,
    input  wire [31:0]             reg_wr_data,
    input  wire [3:0]              reg_wr_strb,
    output wire [1:0]              reg_wr_resp,
    input  wire [11:0]             reg_rd_addr,
    output wire [31:0]             reg_rd_data,
    output wire [1:0]              reg_rd_resp,
    output wire                    irq,
    output wire                    job_start,
    output wire                    job_busy,
    output wire                    job_done,
    output wire                    job_error,
    output wire [31:0]             job_matrix_m,
    output wire [31:0]             job_matrix_n,
    output wire [31:0]             job_matrix_k,
    output wire [31:0]             job_tile_m,
    output wire [31:0]             job_tile_n,
    output wire [31:0]             job_tile_k,
    output wire signed [31:0]      job_post_bias,
    output wire signed [31:0]      job_post_scale,
    output wire                    job_post_relu,
    output wire [5:0]              job_post_shift,
    output wire                    job_output_int8,

    output wire [ADDR_W-1:0]       a_axi_araddr,
    output wire [7:0]              a_axi_arlen,
    output wire [2:0]              a_axi_arsize,
    output wire [1:0]              a_axi_arburst,
    output wire                    a_axi_arvalid,
    input  wire                    a_axi_arready,
    input  wire [DATA_W-1:0]       a_axi_rdata,
    input  wire [1:0]              a_axi_rresp,
    input  wire                    a_axi_rlast,
    input  wire                    a_axi_rvalid,
    output wire                    a_axi_rready,

    output wire [ADDR_W-1:0]       b_axi_araddr,
    output wire [7:0]              b_axi_arlen,
    output wire [2:0]              b_axi_arsize,
    output wire [1:0]              b_axi_arburst,
    output wire                    b_axi_arvalid,
    input  wire                    b_axi_arready,
    input  wire [DATA_W-1:0]       b_axi_rdata,
    input  wire [1:0]              b_axi_rresp,
    input  wire                    b_axi_rlast,
    input  wire                    b_axi_rvalid,
    output wire                    b_axi_rready,

    output wire [ADDR_W-1:0]       c_axi_awaddr,
    output wire [7:0]              c_axi_awlen,
    output wire [2:0]              c_axi_awsize,
    output wire [1:0]              c_axi_awburst,
    output wire                    c_axi_awvalid,
    input  wire                    c_axi_awready,
    output wire [DATA_W-1:0]       c_axi_wdata,
    output wire [DATA_W/8-1:0]     c_axi_wstrb,
    output wire                    c_axi_wlast,
    output wire                    c_axi_wvalid,
    input  wire                    c_axi_wready,
    input  wire [1:0]              c_axi_bresp,
    input  wire                    c_axi_bvalid,
    output wire                    c_axi_bready,
    input  wire                    compute_busy_in,
    input  wire                    compute_done_in,
    input  wire                    compute_error_in,
    input  wire [31:0]             perf_active_cycles,
    input  wire [63:0]             perf_mac_count,
    input  wire [31:0]             perf_tile_count,

    output wire [DATA_W-1:0]       a_stream_data,
    output wire                    a_stream_valid,
    input  wire                    a_stream_ready,
    output wire                    a_stream_last,
    output wire [DATA_W-1:0]       b_stream_data,
    output wire                    b_stream_valid,
    input  wire                    b_stream_ready,
    output wire                    b_stream_last,
    input  wire [DATA_W-1:0]       c_stream_data,
    input  wire                    c_stream_valid,
    output wire                    c_stream_ready,
    input  wire                    c_stream_last
);

    wire dma_start;
    wire dma_abort;
    wire dma_busy;
    wire dma_done;
    wire dma_error;
    wire irq_en_unused;
    wire [31:0] a_base, b_base, c_base;
    wire [31:0] matrix_m, matrix_n, matrix_k;
    wire [31:0] tile_m_unused, tile_n_unused, tile_k_unused;
    wire signed [31:0] post_bias_unused, post_scale_unused;
    wire post_relu_unused;
    wire [5:0] post_shift_unused;
    wire post_output_int8_unused;

    // INT8 operands are packed four per 32-bit beat; C is one INT32 per beat.
    wire [63:0] matrix_m_ext = {32'd0, matrix_m};
    wire [63:0] matrix_n_ext = {32'd0, matrix_n};
    wire [63:0] matrix_k_ext = {32'd0, matrix_k};
    wire [63:0] a_bytes  = matrix_m_ext * matrix_k_ext;
    wire [63:0] b_bytes  = matrix_k_ext * matrix_n_ext;
    wire [63:0] a_words  = (a_bytes + 64'd3) >> 2;
    wire [63:0] b_words  = (b_bytes + 64'd3) >> 2;
    wire [63:0] c_elements = matrix_m_ext * matrix_n_ext;
    wire [63:0] c_words  = post_output_int8_unused ? ((c_elements + 64'd3) >> 2) : c_elements;

    wire a_busy, a_done, a_error;
    wire b_busy, b_done, b_error;
    wire c_busy, c_done, c_error;

    assign dma_busy  = a_busy || b_busy || c_busy || compute_busy_in;
    logic a_complete_q, b_complete_q, c_complete_q, compute_complete_q;
    assign dma_done  = (a_complete_q || a_done) &&
                       (b_complete_q || b_done) &&
                       (c_complete_q || c_done) &&
                       (compute_complete_q || compute_done_in);
    assign dma_error = a_error || b_error || c_error || compute_error_in;
    assign job_start = dma_start;
    assign job_busy = dma_busy;
    assign job_done = dma_done;
    assign job_error = dma_error;
    assign job_matrix_m = matrix_m;
    assign job_matrix_n = matrix_n;
    assign job_matrix_k = matrix_k;
    assign job_tile_m = tile_m_unused;
    assign job_tile_n = tile_n_unused;
    assign job_tile_k = tile_k_unused;
    assign job_post_bias = post_bias_unused;
    assign job_post_scale = post_scale_unused;
    assign job_post_relu = post_relu_unused;
    assign job_post_shift = post_shift_unused;
    assign job_output_int8 = post_output_int8_unused;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_complete_q <= 1'b0;
            b_complete_q <= 1'b0;
            c_complete_q <= 1'b0;
            compute_complete_q <= 1'b0;
        end else if (dma_start) begin
            a_complete_q <= 1'b0;
            b_complete_q <= 1'b0;
            c_complete_q <= 1'b0;
            compute_complete_q <= 1'b0;
        end else begin
            if (a_done) a_complete_q <= 1'b1;
            if (b_done) b_complete_q <= 1'b1;
            if (c_done) c_complete_q <= 1'b1;
            if (compute_done_in) compute_complete_q <= 1'b1;
        end
    end

    dma_descriptor_ctrl u_desc (
        .clk          (clk),
        .rst_n        (rst_n),
        .reg_wr_en    (reg_wr_en),
        .reg_wr_addr  (reg_wr_addr),
        .reg_wr_data  (reg_wr_data),
        .reg_wr_strb  (reg_wr_strb),
        .reg_wr_resp  (reg_wr_resp),
        .reg_rd_addr  (reg_rd_addr),
        .reg_rd_data  (reg_rd_data),
        .reg_rd_resp  (reg_rd_resp),
        .dma_start    (dma_start),
        .dma_abort    (dma_abort),
        .irq_en       (irq_en_unused),
        .a_base       (a_base),
        .b_base       (b_base),
        .c_base       (c_base),
        .matrix_m     (matrix_m),
        .matrix_n     (matrix_n),
        .matrix_k     (matrix_k),
        .tile_m       (tile_m_unused),
        .tile_n       (tile_n_unused),
        .tile_k       (tile_k_unused),
        .post_bias    (post_bias_unused),
        .post_scale_mult(post_scale_unused),
        .post_relu    (post_relu_unused),
        .post_scale_shift(post_shift_unused),
        .post_output_int8(post_output_int8_unused),
        .dma_busy     (dma_busy),
        .dma_done     (dma_done),
        .dma_error    (dma_error),
        .perf_active_cycles(perf_active_cycles),
        .perf_mac_count(perf_mac_count),
        .perf_tile_count(perf_tile_count),
        .irq          (irq)
    );

    axi4_read_dma #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .MAX_BURST(MAX_BURST)) u_a_dma (
        .clk(clk), .rst_n(rst_n), .start(dma_start), .base_addr(a_base),
        .word_count(a_words[31:0]), .busy(a_busy), .done(a_done), .error(a_error),
        .m_axi_araddr(a_axi_araddr), .m_axi_arlen(a_axi_arlen),
        .m_axi_arsize(a_axi_arsize), .m_axi_arburst(a_axi_arburst),
        .m_axi_arvalid(a_axi_arvalid), .m_axi_arready(a_axi_arready),
        .m_axi_rdata(a_axi_rdata), .m_axi_rresp(a_axi_rresp),
        .m_axi_rlast(a_axi_rlast), .m_axi_rvalid(a_axi_rvalid),
        .m_axi_rready(a_axi_rready), .stream_data(a_stream_data),
        .stream_valid(a_stream_valid), .stream_ready(a_stream_ready),
        .stream_last(a_stream_last)
    );

    axi4_read_dma #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .MAX_BURST(MAX_BURST)) u_b_dma (
        .clk(clk), .rst_n(rst_n), .start(dma_start), .base_addr(b_base),
        .word_count(b_words[31:0]), .busy(b_busy), .done(b_done), .error(b_error),
        .m_axi_araddr(b_axi_araddr), .m_axi_arlen(b_axi_arlen),
        .m_axi_arsize(b_axi_arsize), .m_axi_arburst(b_axi_arburst),
        .m_axi_arvalid(b_axi_arvalid), .m_axi_arready(b_axi_arready),
        .m_axi_rdata(b_axi_rdata), .m_axi_rresp(b_axi_rresp),
        .m_axi_rlast(b_axi_rlast), .m_axi_rvalid(b_axi_rvalid),
        .m_axi_rready(b_axi_rready), .stream_data(b_stream_data),
        .stream_valid(b_stream_valid), .stream_ready(b_stream_ready),
        .stream_last(b_stream_last)
    );

    axi4_write_dma #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .MAX_BURST(MAX_BURST)) u_c_dma (
        .clk(clk), .rst_n(rst_n), .start(dma_start), .base_addr(c_base),
        .word_count(c_words[31:0]), .busy(c_busy), .done(c_done), .error(c_error),
        .m_axi_awaddr(c_axi_awaddr), .m_axi_awlen(c_axi_awlen),
        .m_axi_awsize(c_axi_awsize), .m_axi_awburst(c_axi_awburst),
        .m_axi_awvalid(c_axi_awvalid), .m_axi_awready(c_axi_awready),
        .m_axi_wdata(c_axi_wdata), .m_axi_wstrb(c_axi_wstrb),
        .m_axi_wlast(c_axi_wlast), .m_axi_wvalid(c_axi_wvalid),
        .m_axi_wready(c_axi_wready), .m_axi_bresp(c_axi_bresp),
        .m_axi_bvalid(c_axi_bvalid), .m_axi_bready(c_axi_bready),
        .stream_data(c_stream_data), .stream_valid(c_stream_valid),
        .stream_ready(c_stream_ready), .stream_last(c_stream_last)
    );

    // ABORT is exposed by the descriptor block for the eventual controller;
    // the simple movers finish their current AXI transaction before reset.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_abort = dma_abort;
    wire unused_descriptor = ^{irq_en_unused, tile_m_unused, tile_n_unused, tile_k_unused,
                               post_bias_unused, post_scale_unused, post_relu_unused,
                               post_shift_unused, post_output_int8_unused};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
