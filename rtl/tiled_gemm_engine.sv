// -----------------------------------------------------------------------------
// tiled_gemm_engine.sv - pipelined whole-matrix tiled GEMM engine.
//
// Drop-in replacement for tiled_matrix_tile_buffer + tiled_gemm_controller
// inside tiled_stream_gemm_top (selected with PIPELINED=1).
//
// Why it is faster. The reference path moves every output tile through three
// serial hand-offs: the tile buffer streams the tile's K vectors to the tile
// adapter over a 32-bit port (K*N/4 cycles), the adapter feeds and drains the
// array, then N*N results travel one word per cycle through the K accumulator
// and back into the buffer, and only then does the scheduler issue the next
// tile. Here the whole A and B matrices are already on chip, so:
//
//   * the array is fed one full K vector (N bytes of A, N bytes of B) per
//     cycle directly from the operand buffers - no per-tile copy and no 32-bit
//     bottleneck, which matters most for N >= 8;
//   * the full K reduction happens in one pass (K <= MAX_K is on chip), so no
//     partial tiles are re-accumulated; TILE_K is validated but not needed;
//   * all N*N accumulators are captured into the C buffer in one cycle, in
//     the same cycle the array is cleared for the next tile;
//   * finished rows of C stream out while later rows are still computing.
//
// Per output tile: K feed cycles + (2N-1) drain cycles + 1 capture/clear
// cycle. The systolic_array input contract is unchanged (docs/dataflow.md).
//
// Stream contracts are identical to the reference path: A (M x K) and B
// (K x N) arrive row-major, four INT8 values per word; C leaves row-major as
// one INT32 per word. Edge tiles are zero-padded.
// -----------------------------------------------------------------------------
`default_nettype none

module tiled_gemm_engine #(
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
    output logic                   busy,
    output logic                   done,
    output logic                   error,

    input  wire [31:0]             a_in_data,
    input  wire                    a_in_valid,
    output logic                   a_in_ready,
    input  wire [31:0]             b_in_data,
    input  wire                    b_in_valid,
    output logic                   b_in_ready,

    output logic [31:0]            c_out_data,
    output logic                   c_out_valid,
    input  wire                    c_out_ready,
    output logic                   c_out_last,

    // Cycles in which the array consumed a real K vector (for profiling).
    output logic                   feed_active
);

    localparam int N = ARRAY_N;
    localparam int DRAIN_CYCLES = 2 * N - 1;
    localparam int DRAIN_W = $clog2(DRAIN_CYCLES + 1);
    localparam int IN_WORDS_MAX = ((MAX_M * MAX_K) + 3) / 4;
    localparam int BN_WORDS_MAX = ((MAX_K * MAX_N) + 3) / 4;
    localparam int IN_WORD_W = $clog2(IN_WORDS_MAX + 1);
    localparam int BN_WORD_W = $clog2(BN_WORDS_MAX + 1);

    generate
        if (ARRAY_N < 4 || (ARRAY_N % 4) != 0) begin : g_bad_array
            initial $fatal(1, "tiled_gemm_engine: ARRAY_N must be a multiple of 4");
        end
    endgenerate

    typedef enum logic [2:0] {S_IDLE, S_LOAD, S_CLEAR, S_FEED, S_DRAIN, S_CAPTURE, S_FLUSH_OUT}
        state_t;
    state_t state;

    logic [31:0] m_q, n_q, k_q, tm_q, tn_q;
    logic [IN_WORD_W-1:0] a_in_count;
    logic [BN_WORD_W-1:0] b_in_count;
    logic [31:0] m0_q, n0_q, feed_k;
    logic [DRAIN_W-1:0] drain_count;
    logic [31:0] rows_ready;          // rows of C that are final and may be output
    logic [31:0] out_row, out_col, out_count;

    logic signed [7:0]  a_mem [0:MAX_M*MAX_K-1];
    logic signed [7:0]  b_mem [0:MAX_K*MAX_N-1];
    logic signed [31:0] c_mem [0:MAX_M*MAX_N-1];

    wire a_accept = a_in_valid && a_in_ready;
    wire b_accept = b_in_valid && b_in_ready;
    wire c_accept = c_out_valid && c_out_ready;

    wire [63:0] a_total_bytes = m_q * k_q;
    wire [63:0] b_total_bytes = k_q * n_q;
    // MAX_* bounds (checked at start) keep these word counts within 32 bits.
    /* verilator lint_off WIDTHTRUNC */
    wire [31:0] a_total_words = (a_total_bytes + 64'd3) >> 2;
    wire [31:0] b_total_words = (b_total_bytes + 64'd3) >> 2;
    /* verilator lint_on WIDTHTRUNC */
    wire [31:0] c_total = m_q * n_q;

    wire [31:0] tm_len = ((m_q - m0_q) < tm_q) ? (m_q - m0_q) : tm_q;
    wire [31:0] tn_len = ((n_q - n0_q) < tn_q) ? (n_q - n0_q) : tn_q;
    wire last_n_block = (n0_q + tn_len >= n_q);
    wire last_m_block = (m0_q + tm_len >= m_q);

    wire bad_cfg = (matrix_m == 0) || (matrix_n == 0) || (matrix_k == 0) ||
                   (matrix_m > MAX_M) || (matrix_n > MAX_N) || (matrix_k > MAX_K) ||
                   (tile_m_cfg == 0) || (tile_m_cfg > N) || (tile_m_cfg[1:0] != 0) ||
                   (tile_n_cfg == 0) || (tile_n_cfg > N) || (tile_n_cfg[1:0] != 0) ||
                   (tile_k_cfg == 0) || (tile_k_cfg > MAX_K);

    // ---------------------------------------------------------------- array
    logic [N*8-1:0]  arr_a_flat, arr_b_flat;
    wire  [N*N*32-1:0] arr_acc_flat;
    wire arr_en    = (state == S_FEED) || (state == S_DRAIN);
    wire arr_clear = (state == S_CLEAR) || (state == S_CAPTURE);

    systolic_array #(.N(N), .IN_W(8), .ACC_W(32)) u_array (
        .clk(clk), .rst_n(rst_n), .en(arr_en), .clr_acc(arr_clear), .flush(arr_clear),
        .a_flat(arr_a_flat), .b_flat(arr_b_flat), .acc_flat(arr_acc_flat)
    );

    integer r, c, lane, byte_index;
    always_comb begin
        // One K vector per feed cycle, zero-padded outside the M x N edge.
        arr_a_flat = '0;
        arr_b_flat = '0;
        if (state == S_FEED) begin
            for (r = 0; r < N; r = r + 1)
                if ((r < tm_len) && (m0_q + r < MAX_M) && (feed_k < MAX_K))
                    arr_a_flat[r*8 +: 8] = a_mem[(m0_q + r) * MAX_K + feed_k];
            for (c = 0; c < N; c = c + 1)
                if ((c < tn_len) && (n0_q + c < MAX_N) && (feed_k < MAX_K))
                    arr_b_flat[c*8 +: 8] = b_mem[feed_k * MAX_N + n0_q + c];
        end
    end

    // --------------------------------------------------------------- control
    always_comb begin
        busy        = (state != S_IDLE);
        feed_active = (state == S_FEED);
        a_in_ready  = (state == S_LOAD) && (a_in_count < a_total_words[IN_WORD_W-1:0]);
        b_in_ready  = (state == S_LOAD) && (b_in_count < b_total_words[BN_WORD_W-1:0]);
        // Output runs concurrently with compute: any element whose row is final.
        c_out_valid = (state != S_IDLE) && (state != S_LOAD) &&
                      (out_count < c_total) && (out_row < rows_ready);
        c_out_last  = c_out_valid && (out_count == c_total - 1);
        c_out_data  = ((out_row < MAX_M) && (out_col < MAX_N)) ?
                      c_mem[out_row * MAX_N + out_col] : 32'd0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            m_q <= 0; n_q <= 0; k_q <= 0; tm_q <= 0; tn_q <= 0;
            a_in_count  <= 0;
            b_in_count  <= 0;
            m0_q        <= 0;
            n0_q        <= 0;
            feed_k      <= 0;
            drain_count <= 0;
            rows_ready  <= 0;
            out_row     <= 0;
            out_col     <= 0;
            out_count   <= 0;
            done        <= 1'b0;
            error       <= 1'b0;
        end else begin
            done <= 1'b0;

            // ---- output side (independent of the compute state) ----------
            if (c_accept) begin
                out_count <= out_count + 1;
                if (out_col + 1 >= n_q) begin
                    out_col <= 0;
                    out_row <= out_row + 1;
                end else begin
                    out_col <= out_col + 1;
                end
            end

            case (state)
                S_IDLE: begin
                    if (start_job) begin
                        if (bad_cfg) begin
                            error <= 1'b1;
                        end else begin
                            m_q <= matrix_m;
                            n_q <= matrix_n;
                            k_q <= matrix_k;
                            tm_q <= tile_m_cfg;
                            tn_q <= tile_n_cfg;
                            a_in_count <= 0;
                            b_in_count <= 0;
                            rows_ready <= 0;
                            out_row <= 0;
                            out_col <= 0;
                            out_count <= 0;
                            error <= 1'b0;
                            state <= S_LOAD;
                        end
                    end
                end

                S_LOAD: begin
                    if (a_accept) begin
                        for (lane = 0; lane < 4; lane = lane + 1) begin
                            byte_index = a_in_count * 4 + lane;
                            if (byte_index < a_total_bytes)
                                a_mem[byte_index / k_q * MAX_K + (byte_index % k_q)] <=
                                    $signed(a_in_data[lane*8 +: 8]);
                        end
                        a_in_count <= a_in_count + 1'b1;
                    end
                    if (b_accept) begin
                        for (lane = 0; lane < 4; lane = lane + 1) begin
                            byte_index = b_in_count * 4 + lane;
                            if (byte_index < b_total_bytes)
                                b_mem[byte_index / n_q * MAX_N + (byte_index % n_q)] <=
                                    $signed(b_in_data[lane*8 +: 8]);
                        end
                        b_in_count <= b_in_count + 1'b1;
                    end
                    if ((a_in_count + a_accept >= a_total_words) &&
                        (b_in_count + b_accept >= b_total_words)) begin
                        m0_q <= 0;
                        n0_q <= 0;
                        state <= S_CLEAR;
                    end
                end

                S_CLEAR: begin              // clear accumulators + operand pipeline once
                    feed_k <= 0;
                    state  <= S_FEED;
                end

                S_FEED: begin
                    if (feed_k == k_q - 1) begin
                        drain_count <= 0;
                        state <= S_DRAIN;
                    end else begin
                        feed_k <= feed_k + 1;
                    end
                end

                S_DRAIN: begin
                    if (drain_count == DRAIN_W'(DRAIN_CYCLES - 1))
                        state <= S_CAPTURE;
                    else
                        drain_count <= drain_count + 1'b1;
                end

                S_CAPTURE: begin
                    // acc_flat is final this cycle; the array clears on this edge.
                    for (int cr = 0; cr < N; cr++)
                        for (int cc = 0; cc < N; cc++)
                            if ((cr < tm_len) && (cc < tn_len) &&
                                (m0_q + cr < MAX_M) && (n0_q + cc < MAX_N))
                                c_mem[(m0_q + cr) * MAX_N + n0_q + cc] <=
                                    $signed(arr_acc_flat[(cr*N + cc)*32 +: 32]);
                    feed_k <= 0;
                    if (last_n_block) begin
                        rows_ready <= m0_q + tm_len;
                        n0_q <= 0;
                        if (last_m_block) begin
                            state <= S_FLUSH_OUT;
                        end else begin
                            m0_q  <= m0_q + tm_len;
                            state <= S_FEED;
                        end
                    end else begin
                        n0_q  <= n0_q + tn_len;
                        state <= S_FEED;
                    end
                end

                S_FLUSH_OUT: begin          // compute finished; wait for the last rows
                    if (c_accept && (out_count == c_total - 1)) begin
                        state <= S_IDLE;
                        done  <= 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // Unused: TILE_K only needs validating (the full K is reduced in one pass).
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_cfg = ^tile_k_cfg;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
