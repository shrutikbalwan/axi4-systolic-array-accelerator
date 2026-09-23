// -----------------------------------------------------------------------------
// tiled_stream_gemm_top.sv - contiguous matrix stream to tiled GEMM top.
//
// This composes the matrix/tile buffer with the runtime scheduler and compute
// chain. It is the bridge-level reference top for connecting AXI4 DMA streams
// to the tiled accelerator; the AXI4-Lite legacy top remains unchanged.
// -----------------------------------------------------------------------------
`default_nettype none

module tiled_stream_gemm_top #(
    parameter int ARRAY_N = 4,
    parameter int MAX_M   = 64,
    parameter int MAX_N   = 64,
    parameter int MAX_K   = 64
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start_job,
    input  wire [31:0]             matrix_m,
    input  wire [31:0]             matrix_n,
    input  wire [31:0]             matrix_k,
    input  wire [31:0]             tile_m_cfg,
    input  wire [31:0]             tile_n_cfg,
    input  wire [31:0]             tile_k_cfg,
    output wire                    busy,
    output wire                    done,
    output wire                    error,

    input  wire [31:0]             a_in_data,
    input  wire                    a_in_valid,
    output wire                    a_in_ready,
    input  wire [31:0]             b_in_data,
    input  wire                    b_in_valid,
    output wire                    b_in_ready,
    output wire [31:0]             c_out_data,
    output wire                    c_out_valid,
    input  wire                    c_out_ready,
    output wire                    c_out_last
);

    wire launch_compute;
    wire buffer_busy, buffer_done, buffer_error;
    wire controller_busy, controller_done, controller_error;
    wire tile_valid, tile_ready;
    wire [31:0] tile_m_base, tile_n_base, tile_k_base;
    wire [31:0] tile_m_len, tile_n_len, tile_k_len;
    wire tile_first_k, tile_last_k;
    wire [31:0] tile_a_data, tile_b_data;
    wire tile_a_valid, tile_a_ready, tile_a_last;
    wire tile_b_valid, tile_b_ready, tile_b_last;
    wire [31:0] tile_c_data;
    wire tile_c_valid, tile_c_ready, tile_c_last;
    wire controller_tile_done;
    logic start_q;
    logic [31:0] matrix_m_q, matrix_n_q, matrix_k_q;
    logic [31:0] tile_m_cfg_q, tile_n_cfg_q, tile_k_cfg_q;

    // Latch the job descriptor before releasing the buffer. This prevents a
    // software write to the control registers during input loading from
    // changing the dimensions seen by the later scheduler.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_q <= 1'b0;
            matrix_m_q <= 0;
            matrix_n_q <= 0;
            matrix_k_q <= 0;
            tile_m_cfg_q <= 0;
            tile_n_cfg_q <= 0;
            tile_k_cfg_q <= 0;
        end else begin
            start_q <= 1'b0;
            if (start_job && !busy) begin
                start_q <= 1'b1;
                matrix_m_q <= matrix_m;
                matrix_n_q <= matrix_n;
                matrix_k_q <= matrix_k;
                tile_m_cfg_q <= tile_m_cfg;
                tile_n_cfg_q <= tile_n_cfg;
                tile_k_cfg_q <= tile_k_cfg;
            end
        end
    end

    assign busy = buffer_busy || controller_busy;
    assign done = buffer_done;
    assign error = buffer_error || controller_error;

    tiled_matrix_tile_buffer #(
        .ARRAY_N(ARRAY_N), .MAX_M(MAX_M), .MAX_N(MAX_N), .MAX_K(MAX_K)
    ) u_buffer (
        .clk(clk), .rst_n(rst_n), .start_job(start_q),
        .matrix_m(matrix_m_q), .matrix_n(matrix_n_q), .matrix_k(matrix_k_q),
        .launch_compute(launch_compute), .busy(buffer_busy),
        .done(buffer_done), .error(buffer_error),
        .a_in_data(a_in_data), .a_in_valid(a_in_valid), .a_in_ready(a_in_ready),
        .b_in_data(b_in_data), .b_in_valid(b_in_valid), .b_in_ready(b_in_ready),
        .tile_valid(tile_valid), .tile_ready(tile_ready),
        .tile_m_base(tile_m_base), .tile_n_base(tile_n_base),
        .tile_k_base(tile_k_base), .tile_m_len(tile_m_len),
        .tile_n_len(tile_n_len), .tile_k_len(tile_k_len),
        .tile_a_data(tile_a_data), .tile_a_valid(tile_a_valid),
        .tile_a_ready(tile_a_ready), .tile_a_last(tile_a_last),
        .tile_b_data(tile_b_data), .tile_b_valid(tile_b_valid),
        .tile_b_ready(tile_b_ready), .tile_b_last(tile_b_last),
        .tile_c_data(tile_c_data), .tile_c_valid(tile_c_valid),
        .tile_c_ready(tile_c_ready), .tile_c_last(tile_c_last),
        .tile_done(controller_tile_done), .tile_last_k(tile_last_k),
        .compute_done(controller_done),
        .c_out_data(c_out_data), .c_out_valid(c_out_valid),
        .c_out_ready(c_out_ready), .c_out_last(c_out_last)
    );

    tiled_gemm_controller #(.ARRAY_N(ARRAY_N), .KMAX(MAX_K)) u_controller (
        .clk(clk), .rst_n(rst_n), .start_job(launch_compute),
        .matrix_m(matrix_m_q), .matrix_n(matrix_n_q), .matrix_k(matrix_k_q),
        .tile_m_cfg(tile_m_cfg_q), .tile_n_cfg(tile_n_cfg_q), .tile_k_cfg(tile_k_cfg_q),
        .busy(controller_busy), .done(controller_done), .error(controller_error),
        .tile_valid(tile_valid), .tile_ready(tile_ready),
        .tile_m_base(tile_m_base), .tile_n_base(tile_n_base),
        .tile_k_base(tile_k_base), .tile_m_len(tile_m_len),
        .tile_n_len(tile_n_len), .tile_k_len(tile_k_len),
        .tile_first_k(tile_first_k), .tile_last_k(tile_last_k),
        .a_stream_data(tile_a_data), .a_stream_valid(tile_a_valid),
        .a_stream_ready(tile_a_ready), .a_stream_last(tile_a_last),
        .b_stream_data(tile_b_data), .b_stream_valid(tile_b_valid),
        .b_stream_ready(tile_b_ready), .b_stream_last(tile_b_last),
        .c_stream_data(tile_c_data), .c_stream_valid(tile_c_valid),
        .c_stream_ready(tile_c_ready), .c_stream_last(tile_c_last),
        .tile_done(controller_tile_done)
    );

endmodule

`default_nettype wire
