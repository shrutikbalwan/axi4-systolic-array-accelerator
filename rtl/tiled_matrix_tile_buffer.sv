// -----------------------------------------------------------------------------
// tiled_matrix_tile_buffer.sv - contiguous matrix <-> padded tile bridge.
//
// A/B input streams are row-major INT8 matrices packed four bytes per word.
// The bridge stores them, presents one ARRAY_N x ARRAY_N tile at a time in the
// feed order expected by tiled_gemm_controller, and captures fixed-size INT32
// output tiles into a row-major C buffer. Edge elements are zero padded and
// never written outside the requested M x N result.
//
// This reference integration block is intentionally parameterized so FPGA
// users can map the arrays to BRAM/URAM or replace them with banked memories.
// It is not a claim that arbitrary MAX_* values infer efficient RAM on every
// vendor; synthesis reports must be checked for the target device.
// -----------------------------------------------------------------------------
`default_nettype none

module tiled_matrix_tile_buffer #(
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
    output logic                    launch_compute,
    output logic                    busy,
    output logic                    done,
    output logic                    error,

    input  wire [31:0]             a_in_data,
    input  wire                    a_in_valid,
    output logic                    a_in_ready,
    input  wire [31:0]             b_in_data,
    input  wire                    b_in_valid,
    output logic                    b_in_ready,

    input  wire                    tile_valid,
    output logic                    tile_ready,
    input  wire [31:0]             tile_m_base,
    input  wire [31:0]             tile_n_base,
    input  wire [31:0]             tile_k_base,
    input  wire [31:0]             tile_m_len,
    input  wire [31:0]             tile_n_len,
    input  wire [31:0]             tile_k_len,
    output logic [31:0]             tile_a_data,
    output logic                    tile_a_valid,
    input  wire                    tile_a_ready,
    output logic                    tile_a_last,
    output logic [31:0]             tile_b_data,
    output logic                    tile_b_valid,
    input  wire                    tile_b_ready,
    output logic                    tile_b_last,

    input  wire [31:0]             tile_c_data,
    input  wire                    tile_c_valid,
    output logic                    tile_c_ready,
    input  wire                    tile_c_last,
    input  wire                    compute_done,

    output logic [31:0]             c_out_data,
    output logic                    c_out_valid,
    input  wire                    c_out_ready,
    output logic                    c_out_last
);

    localparam int BYTES_PER_WORD = 4;
    localparam int WORDS_PER_ROW = (ARRAY_N * 8) / 32;
    localparam int TILE_WORDS_MAX = MAX_K * WORDS_PER_ROW;
    localparam int TILE_WORD_W = (TILE_WORDS_MAX > 1) ? $clog2(TILE_WORDS_MAX + 1) : 1;
    localparam int IN_WORDS_MAX = ((MAX_M * MAX_K) + 3) / 4;
    localparam int BN_WORDS_MAX = ((MAX_K * MAX_N) + 3) / 4;
    localparam int IN_WORD_W = (IN_WORDS_MAX > 1) ? $clog2(IN_WORDS_MAX + 1) : 1;
    localparam int BN_WORD_W = (BN_WORDS_MAX > 1) ? $clog2(BN_WORDS_MAX + 1) : 1;
    localparam int C_WORDS_MAX = MAX_M * MAX_N;
    localparam int C_WORD_W = (C_WORDS_MAX > 1) ? $clog2(C_WORDS_MAX + 1) : 1;
    localparam int TILE_C_WORDS = ARRAY_N * ARRAY_N;
    localparam int TILE_C_WORD_W = (TILE_C_WORDS > 1) ? $clog2(TILE_C_WORDS) : 1;

    generate
        if (ARRAY_N < 4 || (ARRAY_N % 4) != 0) begin : g_bad_array
            initial $fatal(1, "tiled_matrix_tile_buffer: ARRAY_N must be a multiple of 4");
        end
    endgenerate

    typedef enum logic [2:0] {S_IDLE, S_LOAD, S_READY, S_SEND, S_CAPTURE, S_OUTPUT} state_t;
    state_t state;

    logic [31:0] m_q, n_q, k_q;
    logic [IN_WORD_W-1:0] a_in_count;
    logic [BN_WORD_W-1:0] b_in_count;
    logic [TILE_WORD_W-1:0] tile_word_count;
    logic [TILE_C_WORD_W-1:0] tile_c_count;
    logic [C_WORD_W-1:0] c_out_count;
    logic [31:0] tm_q, tn_q, tk_q;
    logic [31:0] tm_len_q, tn_len_q, tk_len_q;

    logic signed [7:0] a_mem [0:MAX_M*MAX_K-1];
    logic signed [7:0] b_mem [0:MAX_K*MAX_N-1];
    logic signed [31:0] c_mem [0:MAX_M*MAX_N-1];

    wire a_accept = a_in_valid && a_in_ready;
    wire b_accept = b_in_valid && b_in_ready;
    wire tile_accept = tile_valid && tile_ready;
    wire tile_word_accept = tile_a_valid && tile_b_valid && tile_a_ready && tile_b_ready;
    wire c_accept = tile_c_valid && tile_c_ready;
    wire c_output_accept = c_out_valid && c_out_ready;

    wire [63:0] a_total_bytes = m_q * k_q;
    wire [63:0] b_total_bytes = k_q * n_q;
    wire [31:0] a_total_words = (a_total_bytes + 64'd3) >> 2;
    wire [31:0] b_total_words = (b_total_bytes + 64'd3) >> 2;
    wire [31:0] tile_total_words = tk_len_q * WORDS_PER_ROW;
    wire [31:0] c_total_words = m_q * n_q;

    integer lane;
    integer load_lane;
    integer byte_index;
    integer a_row;
    integer a_col;
    integer b_row;
    integer b_col;
    integer tile_k_offset;
    integer tile_word_group;
    integer tile_lane;
    integer c_row;
    integer c_col;
    integer out_row;
    integer out_col;

    always_comb begin
        // Keep BUSY asserted while the completed matrix is waiting for the
        // writeback consumer; otherwise software could launch a new job and
        // overwrite the result buffer.
        busy = (state != S_IDLE);
        a_in_ready = (state == S_LOAD) && (a_in_count < a_total_words[IN_WORD_W-1:0]);
        b_in_ready = (state == S_LOAD) && (b_in_count < b_total_words[BN_WORD_W-1:0]);
        tile_ready = (state == S_READY);
        tile_a_valid = (state == S_SEND);
        tile_b_valid = (state == S_SEND);
        tile_a_last = tile_a_valid && (tile_word_count == tile_total_words - 1);
        tile_b_last = tile_b_valid && (tile_word_count == tile_total_words - 1);
        tile_c_ready = (state == S_CAPTURE);
        c_out_valid = (state == S_OUTPUT);
        c_out_last = c_out_valid && (c_out_count == c_total_words - 1);

        tile_a_data = 32'd0;
        tile_b_data = 32'd0;
        for (lane = 0; lane < BYTES_PER_WORD; lane = lane + 1) begin
            tile_k_offset = tile_word_count / WORDS_PER_ROW;
            tile_word_group = tile_word_count % WORDS_PER_ROW;
            tile_lane = tile_word_group * BYTES_PER_WORD + lane;
            a_row = tm_q + tile_lane;
            a_col = tk_q + tile_k_offset;
            b_row = tk_q + tile_k_offset;
            b_col = tn_q + tile_lane;
            if ((a_row < (tm_q + tm_len_q)) && (a_col < (tk_q + tk_len_q)) &&
                (a_row < MAX_M) && (a_col < MAX_K))
                tile_a_data[lane*8 +: 8] = a_mem[a_row*MAX_K + a_col];
            if ((b_row < (tk_q + tk_len_q)) && (b_col < (tn_q + tn_len_q)) &&
                (b_row < MAX_K) && (b_col < MAX_N))
                tile_b_data[lane*8 +: 8] = b_mem[b_row*MAX_N + b_col];
        end

        if (n_q != 0) begin
            out_row = c_out_count / n_q;
            out_col = c_out_count % n_q;
            c_out_data = c_mem[out_row*MAX_N + out_col];
        end else begin
            out_row = 0;
            out_col = 0;
            c_out_data = '0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            m_q            <= 0;
            n_q            <= 0;
            k_q            <= 0;
            a_in_count     <= 0;
            b_in_count     <= 0;
            tile_word_count <= 0;
            tile_c_count   <= 0;
            c_out_count    <= 0;
            tm_q           <= 0;
            tn_q           <= 0;
            tk_q           <= 0;
            tm_len_q       <= 0;
            tn_len_q       <= 0;
            tk_len_q       <= 0;
            launch_compute <= 1'b0;
            done           <= 1'b0;
            error          <= 1'b0;
        end else begin
            launch_compute <= 1'b0;
            done <= 1'b0;

            if (state == S_IDLE && start_job) begin
                if ((matrix_m == 0) || (matrix_n == 0) || (matrix_k == 0) ||
                    (matrix_m > MAX_M) || (matrix_n > MAX_N) || (matrix_k > MAX_K)) begin
                    error <= 1'b1;
                end else begin
                    m_q <= matrix_m;
                    n_q <= matrix_n;
                    k_q <= matrix_k;
                    a_in_count <= 0;
                    b_in_count <= 0;
                    error <= 1'b0;
                    state <= S_LOAD;
                end
            end else begin
                case (state)
                    S_LOAD: begin
                        if (a_accept) begin
                            for (load_lane = 0; load_lane < BYTES_PER_WORD; load_lane = load_lane + 1) begin
                                byte_index = a_in_count * BYTES_PER_WORD + load_lane;
                                if (byte_index < a_total_bytes)
                                    a_mem[byte_index / MAX_K * MAX_K + (byte_index % MAX_K)] <=
                                        $signed(a_in_data[load_lane*8 +: 8]);
                            end
                            a_in_count <= a_in_count + 1'b1;
                        end
                        if (b_accept) begin
                            for (load_lane = 0; load_lane < BYTES_PER_WORD; load_lane = load_lane + 1) begin
                                byte_index = b_in_count * BYTES_PER_WORD + load_lane;
                                if (byte_index < b_total_bytes)
                                    b_mem[byte_index / MAX_N * MAX_N + (byte_index % MAX_N)] <=
                                        $signed(b_in_data[load_lane*8 +: 8]);
                            end
                            b_in_count <= b_in_count + 1'b1;
                        end
                        if ((a_in_count + a_accept >= a_total_words) &&
                            (b_in_count + b_accept >= b_total_words)) begin
                            state <= S_READY;
                            launch_compute <= 1'b1;
                        end
                    end

                    S_READY: begin
                        if (compute_done) begin
                            c_out_count <= 0;
                            state <= S_OUTPUT;
                        end else if (tile_accept) begin
                            tm_q <= tile_m_base;
                            tn_q <= tile_n_base;
                            tk_q <= tile_k_base;
                            tm_len_q <= tile_m_len;
                            tn_len_q <= tile_n_len;
                            tk_len_q <= tile_k_len;
                            tile_word_count <= 0;
                            state <= S_SEND;
                        end
                    end

                    S_SEND: begin
                        if (tile_word_accept) begin
                            if (tile_word_count == tile_total_words - 1) begin
                                tile_c_count <= 0;
                                state <= S_CAPTURE;
                            end else begin
                                tile_word_count <= tile_word_count + 1'b1;
                            end
                        end
                    end

                    S_CAPTURE: begin
                        if (c_accept) begin
                            c_row = tile_c_count / ARRAY_N;
                            c_col = tile_c_count % ARRAY_N;
                            if ((c_row < tm_len_q) && (c_col < tn_len_q))
                                c_mem[(tm_q + c_row) * MAX_N + (tn_q + c_col)] <= $signed(tile_c_data);
                            if (tile_c_count == TILE_C_WORDS - 1) begin
                                state <= S_READY;
                            end else begin
                                tile_c_count <= tile_c_count + 1'b1;
                            end
                        end
                    end

                    S_OUTPUT: begin
                        if (c_output_accept) begin
                            if (c_out_count == c_total_words - 1) begin
                                state <= S_IDLE;
                                done <= 1'b1;
                            end else begin
                                c_out_count <= c_out_count + 1'b1;
                            end
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

    // The input and output LAST signals are advisory; fixed word counts are
    // authoritative so DMA burst boundaries do not affect tile boundaries.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_inputs = tile_c_last;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
