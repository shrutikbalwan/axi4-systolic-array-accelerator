// -----------------------------------------------------------------------------
// tiled_gemm_controller.sv - runtime scheduler + multi-K compute chain.
//
// The memory/DMA wrapper presents the current tile through A/B streams while
// this controller owns the tile sequence. tile_valid exposes the descriptor;
// tile_ready means the buffers are prepared and launches the compute chain.
// tile_done advances K/M/N. C is emitted only for the final K tile of each
// output tile, after tile_accumulator has combined all reduction tiles.
// -----------------------------------------------------------------------------
`default_nettype none

module tiled_gemm_controller #(
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
    output wire [31:0]             c_stream_data,
    output wire                    c_stream_valid,
    input  wire                    c_stream_ready,
    output wire                    c_stream_last
);

    wire sched_busy, sched_done, sched_error;
    wire chain_busy, chain_done, chain_tile_done, chain_error;
    wire launch = tile_valid && tile_ready;

    assign busy  = sched_busy || chain_busy;
    assign done  = sched_done;
    assign error = sched_error || chain_error;

    tile_scheduler #(.TILE_M(ARRAY_N), .TILE_N(ARRAY_N), .TILE_K(KMAX)) u_sched (
        .clk(clk), .rst_n(rst_n), .start(start_job),
        .matrix_m(matrix_m), .matrix_n(matrix_n), .matrix_k(matrix_k),
        .tile_m_cfg(tile_m_cfg), .tile_n_cfg(tile_n_cfg), .tile_k_cfg(tile_k_cfg),
        .busy(sched_busy), .error(sched_error), .tile_valid(tile_valid),
        .tile_ready(tile_ready), .tile_done(chain_tile_done),
        .tile_m_base(tile_m_base), .tile_n_base(tile_n_base),
        .tile_k_base(tile_k_base), .tile_m_len(tile_m_len),
        .tile_n_len(tile_n_len), .tile_k_len(tile_k_len),
        .tile_first_k(tile_first_k), .tile_last_k(tile_last_k), .done(sched_done)
    );

    tiled_compute_chain #(.N(ARRAY_N), .KMAX(KMAX)) u_chain (
        .clk(clk), .rst_n(rst_n), .start_tile(launch), .k_len(tile_k_len[15:0]),
        .first_k(tile_first_k), .last_k(tile_last_k), .busy(chain_busy),
        .done(chain_done), .tile_done(chain_tile_done), .error(chain_error),
        .a_stream_data(a_stream_data), .a_stream_valid(a_stream_valid),
        .a_stream_ready(a_stream_ready), .a_stream_last(a_stream_last),
        .b_stream_data(b_stream_data), .b_stream_valid(b_stream_valid),
        .b_stream_ready(b_stream_ready), .b_stream_last(b_stream_last),
        .c_stream_data(c_stream_data), .c_stream_valid(c_stream_valid),
        .c_stream_ready(c_stream_ready), .c_stream_last(c_stream_last)
    );

    // chain_done is the final output completion; sched_done is the job pulse.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_chain_done = chain_done;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
