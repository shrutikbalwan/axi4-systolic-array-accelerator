// -----------------------------------------------------------------------------
// tiled_ml_inference_core.sv - tiled INT8 GEMM with ML output post-processing.
//
// This is the compute-side ML integration boundary. A/B arrive as packed INT8
// tile streams selected by the runtime descriptor, the existing tiled GEMM
// controller produces INT32 C values, and ml_postprocess converts each value
// to a saturated INT8 result. The legacy AXI-Lite top remains independent.
// -----------------------------------------------------------------------------
`default_nettype none

module tiled_ml_inference_core #(
    parameter int ARRAY_N = 4,
    parameter int KMAX    = 16
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
    input  wire                    relu_en,
    input  wire signed [31:0]       bias,
    input  wire signed [31:0]       scale_mult,
    input  wire [5:0]               scale_shift,
    output wire                    busy,
    output wire                    done,
    output wire                    error,

    output wire                    tile_valid,
    input  wire                    tile_ready,
    output wire [31:0]             tile_m_base,
    output wire [31:0]             tile_n_base,
    output wire [31:0]             tile_k_base,
    output wire [31:0]             tile_m_len,
    output wire [31:0]             tile_n_len,
    output wire [31:0]             tile_k_len,
    output wire                    tile_first_k,
    output wire                    tile_last_k,

    input  wire [31:0]             a_stream_data,
    input  wire                    a_stream_valid,
    output wire                    a_stream_ready,
    input  wire                    a_stream_last,
    input  wire [31:0]             b_stream_data,
    input  wire                    b_stream_valid,
    output wire                    b_stream_ready,
    input  wire                    b_stream_last,

    output wire signed [7:0]       out_data,
    output wire                    out_valid,
    input  wire                    out_ready,
    output wire                    out_last
);

    wire signed [31:0] acc_data;
    wire acc_valid;
    wire acc_ready;
    wire acc_last;
    wire post_valid;
    wire unused_tile_done;
    logic last_q;

    // The one-entry registered post-process stage is allowed to accept a new
    // accumulator word when its current result is empty or being consumed.
    assign acc_ready = !post_valid || out_ready;
    assign out_valid = post_valid;

    tiled_gemm_controller #(.ARRAY_N(ARRAY_N), .KMAX(KMAX)) u_controller (
        .clk(clk), .rst_n(rst_n), .start_job(start_job),
        .matrix_m(matrix_m), .matrix_n(matrix_n), .matrix_k(matrix_k),
        .tile_m_cfg(tile_m_cfg), .tile_n_cfg(tile_n_cfg), .tile_k_cfg(tile_k_cfg),
        .busy(busy), .done(done), .error(error),
        .tile_valid(tile_valid), .tile_ready(tile_ready),
        .tile_m_base(tile_m_base), .tile_n_base(tile_n_base),
        .tile_k_base(tile_k_base), .tile_m_len(tile_m_len),
        .tile_n_len(tile_n_len), .tile_k_len(tile_k_len),
        .tile_first_k(tile_first_k), .tile_last_k(tile_last_k),
        .tile_done(unused_tile_done),
        .a_stream_data(a_stream_data), .a_stream_valid(a_stream_valid),
        .a_stream_ready(a_stream_ready), .a_stream_last(a_stream_last),
        .b_stream_data(b_stream_data), .b_stream_valid(b_stream_valid),
        .b_stream_ready(b_stream_ready), .b_stream_last(b_stream_last),
        .c_stream_data(acc_data), .c_stream_valid(acc_valid),
        .c_stream_ready(acc_ready), .c_stream_last(acc_last)
    );

    assign out_last = post_valid && last_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            last_q <= 1'b0;
        else if (acc_valid && acc_ready)
            last_q <= acc_last;
    end

    ml_postprocess u_postprocess (
        .clk(clk), .rst_n(rst_n),
        .valid_in(acc_valid && acc_ready),
        .acc_in(acc_data), .bias_in(bias),
        .scale_mult(scale_mult), .scale_shift(scale_shift), .relu_en(relu_en),
        .valid_out(post_valid), .data_out(out_data)
    );

endmodule

`default_nettype wire
