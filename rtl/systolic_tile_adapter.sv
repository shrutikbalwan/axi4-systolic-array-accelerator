// -----------------------------------------------------------------------------
// systolic_tile_adapter.sv - stream-to-tile wrapper around systolic_array.
//
// Accepts one packed A/B tile, runs the proven array schedule, and streams the
// N*N INT32 results. A and B streams contain WPR=N*8/32 words per K vector;
// the adapter stores K vectors, so the same interface can be fed by the AXI4
// read DMA or by a testbench. This is the compute-side boundary for the tiled
// DMA shell.
// -----------------------------------------------------------------------------
`default_nettype none

module systolic_tile_adapter #(
    parameter int N     = 4,
    parameter int KMAX  = 16,
    parameter int IN_W  = 8,
    parameter int ACC_W = 32
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start,
    input  wire [15:0]             k_len,
    output logic                    busy,
    output logic                    done,
    output logic                    error,

    input  wire [31:0]             a_stream_data,
    input  wire                    a_stream_valid,
    output logic                    a_stream_ready,
    input  wire                    a_stream_last,
    input  wire [31:0]             b_stream_data,
    input  wire                    b_stream_valid,
    output logic                    b_stream_ready,
    input  wire                    b_stream_last,

    output logic [31:0]             c_stream_data,
    output logic                    c_stream_valid,
    input  wire                    c_stream_ready,
    output logic                    c_stream_last
);

    localparam int WPR      = (N * IN_W) / 32;
    localparam int BUF_WORDS = KMAX * WPR;
    localparam int COUNT_W  = (BUF_WORDS > 1) ? $clog2(BUF_WORDS + 1) : 1;
    localparam int RES_WORDS = N * N;
    localparam int RES_W    = (RES_WORDS > 1) ? $clog2(RES_WORDS) : 1;
    localparam int DRAIN_CYCLES = 2 * N - 1;
    localparam int DRAIN_W  = (DRAIN_CYCLES > 1) ? $clog2(DRAIN_CYCLES) : 1;

    generate
        if (N < 4) begin : g_bad_n
            initial $fatal(1, "systolic_tile_adapter: N must be at least 4");
        end
        if ((N * IN_W) % 32 != 0) begin : g_bad_pack
            initial $fatal(1, "systolic_tile_adapter: N*IN_W must be a multiple of 32");
        end
        if (KMAX < 1) begin : g_bad_kmax
            initial $fatal(1, "systolic_tile_adapter: KMAX must be positive");
        end
    endgenerate

    typedef enum logic [2:0] {S_IDLE, S_LOAD, S_CLEAR, S_FEED, S_DRAIN, S_OUTPUT} state_t;
    state_t state;
    logic [15:0] k_q;
    logic [COUNT_W-1:0] a_count, b_count;
    logic [15:0] feed_k;
    logic [DRAIN_W-1:0] drain_count;
    logic [RES_W-1:0] c_count;
    logic [31:0] a_mem [0:BUF_WORDS-1];
    logic [31:0] b_mem [0:BUF_WORDS-1];

    wire [COUNT_W-1:0] total_words = k_q * WPR;
    wire a_accept = a_stream_valid && a_stream_ready;
    wire b_accept = b_stream_valid && b_stream_ready;
    wire a_complete_next = (a_count + a_accept >= total_words);
    wire b_complete_next = (b_count + b_accept >= total_words);

    wire arr_en, arr_clr_acc, arr_flush;
    wire [N*IN_W-1:0] arr_a_flat, arr_b_flat;
    wire [N*N*ACC_W-1:0] arr_acc_flat;

    assign busy = (state != S_IDLE);
    assign a_stream_ready = (state == S_LOAD) && (a_count < total_words);
    assign b_stream_ready = (state == S_LOAD) && (b_count < total_words);
    assign arr_en = (state == S_FEED) || (state == S_DRAIN);
    assign arr_clr_acc = (state == S_CLEAR);
    assign arr_flush = (state == S_CLEAR);

    generate
        for (genvar j = 0; j < WPR; j++) begin : g_feed_words
            assign arr_a_flat[j*32 +: 32] = (state == S_FEED) ? a_mem[feed_k*WPR + j] : 32'd0;
            assign arr_b_flat[j*32 +: 32] = (state == S_FEED) ? b_mem[feed_k*WPR + j] : 32'd0;
        end
    endgenerate

    assign c_stream_valid = (state == S_OUTPUT);
    assign c_stream_data = arr_acc_flat[c_count*ACC_W +: 32];
    assign c_stream_last = c_stream_valid && (c_count == RES_WORDS - 1);

    systolic_array #(.N(N), .IN_W(IN_W), .ACC_W(ACC_W)) u_array (
        .clk(clk), .rst_n(rst_n), .en(arr_en), .clr_acc(arr_clr_acc),
        .flush(arr_flush), .a_flat(arr_a_flat), .b_flat(arr_b_flat),
        .acc_flat(arr_acc_flat)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            k_q         <= 0;
            a_count     <= 0;
            b_count     <= 0;
            feed_k      <= 0;
            drain_count <= 0;
            c_count     <= 0;
            done        <= 1'b0;
            error       <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        if ((k_len == 0) || (k_len > KMAX)) begin
                            error <= 1'b1;
                        end else begin
                            k_q     <= k_len;
                            a_count <= 0;
                            b_count <= 0;
                            error   <= 1'b0;
                            state   <= S_LOAD;
                        end
                    end
                end

                S_LOAD: begin
                    if (a_accept) begin
                        a_mem[a_count] <= a_stream_data;
                        a_count <= a_count + 1'b1;
                    end
                    if (b_accept) begin
                        b_mem[b_count] <= b_stream_data;
                        b_count <= b_count + 1'b1;
                    end
                    if (a_complete_next && b_complete_next) begin
                        state <= S_CLEAR;
                    end
                end

                S_CLEAR: begin
                    feed_k      <= 0;
                    drain_count <= 0;
                    state       <= S_FEED;
                end

                S_FEED: begin
                    if (feed_k == k_q - 1'b1) begin
                        drain_count <= 0;
                        state <= S_DRAIN;
                    end else begin
                        feed_k <= feed_k + 1'b1;
                    end
                end

                S_DRAIN: begin
                    if (drain_count == DRAIN_CYCLES - 1) begin
                        c_count <= 0;
                        state <= S_OUTPUT;
                    end else begin
                        drain_count <= drain_count + 1'b1;
                    end
                end

                S_OUTPUT: begin
                    if (c_stream_valid && c_stream_ready) begin
                        if (c_count == RES_WORDS - 1) begin
                            state <= S_IDLE;
                            done  <= 1'b1;
                        end else begin
                            c_count <= c_count + 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // Stream LAST is advisory; word counts are authoritative because the
    // adapter may be fed by a burst engine whose burst boundaries differ.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_last = a_stream_last ^ b_stream_last;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
