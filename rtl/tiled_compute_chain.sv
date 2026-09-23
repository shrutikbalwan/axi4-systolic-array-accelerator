// -----------------------------------------------------------------------------
// tiled_compute_chain.sv - stream adapter + systolic array + K accumulation.
// -----------------------------------------------------------------------------
`default_nettype none

module tiled_compute_chain #(
    parameter int N    = 4,
    parameter int KMAX = 16
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start_tile,
    input  wire [15:0]             k_len,
    input  wire                    first_k,
    input  wire                    last_k,
    output wire                    busy,
    output wire                    done,
    output wire                    tile_done,
    output wire                    error,
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

    wire adapter_busy, adapter_error;
    wire accumulator_busy, accumulator_done, accumulator_tile_done, accumulator_error;
    wire [31:0] partial_data;
    wire partial_valid, partial_ready, partial_last;

    assign busy  = adapter_busy || accumulator_busy;
    assign done  = accumulator_done;
    assign tile_done = accumulator_tile_done;
    assign error = adapter_error || accumulator_error;

    // The adapter's done pulse marks completion of the partial tile stream;
    // tile_accumulator owns the externally visible completion because it may
    // still need to accumulate additional K tiles or drain the final tile.
    /* verilator lint_off PINCONNECTEMPTY */
    systolic_tile_adapter #(.N(N), .KMAX(KMAX)) u_adapter (
        .clk(clk), .rst_n(rst_n), .start(start_tile), .k_len(k_len),
        .busy(adapter_busy), .done(), .error(adapter_error),
        .a_stream_data(a_stream_data), .a_stream_valid(a_stream_valid),
        .a_stream_ready(a_stream_ready), .a_stream_last(a_stream_last),
        .b_stream_data(b_stream_data), .b_stream_valid(b_stream_valid),
        .b_stream_ready(b_stream_ready), .b_stream_last(b_stream_last),
        .c_stream_data(partial_data), .c_stream_valid(partial_valid),
        .c_stream_ready(partial_ready), .c_stream_last(partial_last)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    tile_accumulator #(.N(N), .ACC_W(32)) u_accumulator (
        .clk(clk), .rst_n(rst_n), .start_tile(start_tile),
        .first_k(first_k), .last_k(last_k), .busy(accumulator_busy),
        .done(accumulator_done), .tile_done(accumulator_tile_done),
        .error(accumulator_error),
        .in_data(partial_data), .in_valid(partial_valid),
        .in_ready(partial_ready), .in_last(partial_last),
        .out_data(c_stream_data), .out_valid(c_stream_valid),
        .out_ready(c_stream_ready), .out_last(c_stream_last)
    );

endmodule

`default_nettype wire
