// -----------------------------------------------------------------------------
// accel_ctrl.sv - register file, operand buffers and run FSM.
//
// Computes C = A x B with A: N x K, B: K x N, 1 <= K <= KMAX, signed INT8 in,
// signed INT32 out. The register map is documented in docs/register_map.md;
// every offset below is a BYTE offset, converted to a word index exactly once
// (in the *_word signals).
//
// Operand buffers are stored in FEED ORDER: feed vector k is the N bytes that
// the array consumes on feed cycle k.
//   A window: byte (k*N + r) = A[r][k]     (i.e. A transposed, row-major)
//   B window: byte (k*N + c) = B[k][c]     (B row-major)
// so feed vector k is WPR = N*IN_W/32 consecutive words starting at k*WPR.
//
// Run sequence (one START):
//   IDLE --START--> CLEAR (1 cycle: clr_acc + flush)
//        --> FEED  (LEN cycles: vector k = 0..LEN-1 on a_flat/b_flat, en=1)
//        --> DRAIN (DRAIN_CYCLES = 2N-2 + PE_LATENCY cycles: zeros, en=1)
//        --> IDLE with DONE set (sticky, W1C) and irq = DONE & IRQ_EN.
// The last accumulation lands on the final DRAIN edge (docs/dataflow.md), so
// results are final in the same cycle DONE becomes visible.
// Results are read directly from the accumulators, which hold while en = 0.
// -----------------------------------------------------------------------------
`default_nettype none

module accel_ctrl #(
    parameter int N     = 4,
    parameter int KMAX  = 16,
    parameter int IN_W  = 8,
    parameter int ACC_W = 32
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // Register port (from axi_lite_slave)
    input  wire                     reg_wr_en,
    input  wire  [13:0]             reg_wr_addr,
    input  wire  [31:0]             reg_wr_data,
    input  wire  [3:0]              reg_wr_strb,
    output logic [1:0]              reg_wr_resp,
    input  wire  [13:0]             reg_rd_addr,
    output logic [31:0]             reg_rd_data,
    output logic [1:0]              reg_rd_resp,

    // Systolic array
    output logic                    arr_en,
    output logic                    arr_clr_acc,
    output logic                    arr_flush,
    output logic [N*IN_W-1:0]       arr_a_flat,
    output logic [N*IN_W-1:0]       arr_b_flat,
    input  wire  [N*N*ACC_W-1:0]    arr_acc_flat,

    output logic                    irq
);

    // -------------------------------------------------------------------------
    // Parameters and the register map (byte offsets)
    // -------------------------------------------------------------------------
    localparam int PE_LATENCY   = 1;                    // operand register in pe_mac
    localparam int DRAIN_CYCLES = 2*N - 2 + PE_LATENCY; // = 2N-1, docs/dataflow.md
    // Words per feed vector. Clamped to 1 so an illegal N reaches the $error
    // check below instead of failing first on a zero-sized array.
    localparam int WPR          = ((N*IN_W) / 32 > 0) ? (N*IN_W) / 32 : 1;
    localparam int BUF_WORDS    = KMAX * WPR;           // words per operand buffer
    localparam int RES_WORDS    = N * N;                // result words
    localparam int WIN_WORDS    = 1024;                 // each window is 4 KiB
    localparam int BUF_IDX_W    = (BUF_WORDS > 1) ? $clog2(BUF_WORDS) : 1;
    localparam int RES_IDX_W    = (RES_WORDS > 1) ? $clog2(RES_WORDS) : 1;
    localparam int DRAIN_W      = $clog2(DRAIN_CYCLES + 1);

    localparam logic [1:0] WIN_REGS = 2'd0;   // 0x0000
    localparam logic [1:0] WIN_A    = 2'd1;   // 0x1000
    localparam logic [1:0] WIN_B    = 2'd2;   // 0x2000
    localparam logic [1:0] WIN_C    = 2'd3;   // 0x3000

    localparam logic [11:0] OFF_CTRL   = 12'h000;
    localparam logic [11:0] OFF_STATUS = 12'h004;
    localparam logic [11:0] OFF_LEN    = 12'h008;
    localparam logic [11:0] OFF_INFO   = 12'h00C;
    localparam logic [11:0] OFF_CYCLES = 12'h010;
    // Keep the historical 0x014..0x01C holes DECERR-compatible. Performance
    // counters live in the next register block so existing software and tests
    // retain the original address map.
    localparam logic [11:0] OFF_ACTIVE = 12'h020;
    localparam logic [11:0] OFF_MAC_LO = 12'h024;
    localparam logic [11:0] OFF_MAC_HI = 12'h028;

    // The single place byte offsets become word indices.
    localparam logic [9:0] W_CTRL   = OFF_CTRL[11:2];
    localparam logic [9:0] W_STATUS = OFF_STATUS[11:2];
    localparam logic [9:0] W_LEN    = OFF_LEN[11:2];
    localparam logic [9:0] W_INFO   = OFF_INFO[11:2];
    localparam logic [9:0] W_CYCLES = OFF_CYCLES[11:2];
    localparam logic [9:0] W_ACTIVE = OFF_ACTIVE[11:2];
    localparam logic [9:0] W_MAC_LO = OFF_MAC_LO[11:2];
    localparam logic [9:0] W_MAC_HI = OFF_MAC_HI[11:2];

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    // -------------------------------------------------------------------------
    // Elaboration-time checks: fail loudly rather than mis-build.
    // -------------------------------------------------------------------------
    generate
        if (IN_W != 8) begin : g_chk_in_w
            $fatal(1, "accel_ctrl: IN_W must be 8 (operands are packed one per WSTRB byte lane)");
        end
        if (ACC_W != 32) begin : g_chk_acc_w
            $fatal(1, "accel_ctrl: ACC_W must be 32 (one result per 32-bit AXI word)");
        end
        if ((N * IN_W) % 32 != 0) begin : g_chk_n
            $fatal(1, "accel_ctrl: N*IN_W must be a multiple of 32 (N = 4, 8, 12, ...)");
        end
        if (BUF_WORDS > WIN_WORDS || RES_WORDS > WIN_WORDS) begin : g_chk_window
            $fatal(1, "accel_ctrl: an operand or result window exceeds 4 KiB");
        end
        if (KMAX < 1 || KMAX > 65535) begin : g_chk_kmax
            $fatal(1, "accel_ctrl: KMAX must be in 1..65535 (LEN is 16 bits)");
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Address decode
    // -------------------------------------------------------------------------
    wire [1:0] wr_win  = reg_wr_addr[13:12];
    wire [9:0] wr_word = reg_wr_addr[11:2];
    wire [1:0] rd_win  = reg_rd_addr[13:12];
    wire [9:0] rd_word = reg_rd_addr[11:2];

    // Address bits [1:0] select a byte within the word; for a 32-bit AXI4-Lite
    // slave that information is carried by WSTRB, so they are ignored.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_addr_lsbs = ^{reg_wr_addr[1:0], reg_rd_addr[1:0]};
    /* verilator lint_on UNUSEDSIGNAL */

    // "word < SIZE" is constant-true when a window is exactly full; keep the
    // comparison out of the netlist (and out of the lint) in that case.
    logic wr_in_buf, rd_in_buf, wr_in_res, rd_in_res;
    generate
        if (BUF_WORDS == WIN_WORDS) begin : g_buf_full
            assign wr_in_buf = 1'b1;
            assign rd_in_buf = 1'b1;
        end else begin : g_buf_part
            assign wr_in_buf = (wr_word < 10'(BUF_WORDS));
            assign rd_in_buf = (rd_word < 10'(BUF_WORDS));
        end
        if (RES_WORDS == WIN_WORDS) begin : g_res_full
            assign wr_in_res = 1'b1;
            assign rd_in_res = 1'b1;
        end else begin : g_res_part
            assign wr_in_res = (wr_word < 10'(RES_WORDS));
            assign rd_in_res = (rd_word < 10'(RES_WORDS));
        end
    endgenerate

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE  = 2'd0,
        S_CLEAR = 2'd1,
        S_FEED  = 2'd2,
        S_DRAIN = 2'd3
    } state_t;

    state_t                state;
    logic                  irq_en;
    logic                  done;
    logic                  err;
    logic [15:0]           len;
    logic [15:0]           feed_k;      // feed vector index, 0 .. len-1
    logic [BUF_IDX_W-1:0]  feed_base;   // = feed_k * WPR, maintained incrementally
    logic [DRAIN_W-1:0]    drain_cnt;
    logic [31:0]           cycles;      // cycles of the last run, START to DONE
    logic [31:0]           active_cycles; // FEED + DRAIN cycles of the last run
    logic [63:0]           mac_count;    // useful N*N MACs per FEED cycle

    localparam logic [63:0] MACS_PER_FEED = N * N;

    logic [31:0] a_mem [BUF_WORDS];
    logic [31:0] b_mem [BUF_WORDS];

    wire busy = (state != S_IDLE);

    // -------------------------------------------------------------------------
    // Write decode (combinational). Only lane 0 carries CTRL/STATUS bits.
    // -------------------------------------------------------------------------
    logic we_ctrl, we_status, we_len, we_a, we_b;

    // Keep this combinational decode compatible with older Icarus releases.
    always @* begin
        we_ctrl     = 1'b0;
        we_status   = 1'b0;
        we_len      = 1'b0;
        we_a        = 1'b0;
        we_b        = 1'b0;
        reg_wr_resp = RESP_OKAY;

        case (wr_win)
            WIN_REGS: begin
                if (wr_word == W_CTRL) begin
                    we_ctrl = reg_wr_en;
                end else if (wr_word == W_STATUS) begin
                    we_status = reg_wr_en;
                end else if (wr_word == W_LEN) begin
                    if (busy) reg_wr_resp = RESP_SLVERR;   // LEN is locked during a run
                    else      we_len      = reg_wr_en;
                end else if (wr_word == W_INFO || wr_word == W_CYCLES ||
                             wr_word == W_ACTIVE || wr_word == W_MAC_LO ||
                             wr_word == W_MAC_HI) begin
                    reg_wr_resp = RESP_SLVERR;             // read-only
                end else begin
                    reg_wr_resp = RESP_DECERR;
                end
            end
            WIN_A: begin
                if (!wr_in_buf)  reg_wr_resp = RESP_DECERR;
                else if (busy)   reg_wr_resp = RESP_SLVERR;  // buffer in use
                else             we_a        = reg_wr_en;
            end
            WIN_B: begin
                if (!wr_in_buf)  reg_wr_resp = RESP_DECERR;
                else if (busy)   reg_wr_resp = RESP_SLVERR;
                else             we_b        = reg_wr_en;
            end
            WIN_C: begin
                reg_wr_resp = wr_in_res ? RESP_SLVERR : RESP_DECERR;   // read-only
            end
        endcase
    end

    wire ctrl_lane    = we_ctrl && reg_wr_strb[0];
    wire req_start    = ctrl_lane && reg_wr_data[0];
    wire req_clr_acc  = ctrl_lane && reg_wr_data[1];
    wire req_soft_rst = ctrl_lane && reg_wr_data[2];
    wire status_lane  = we_status && reg_wr_strb[0];
    wire len_valid    = (len != 16'd0) && (len <= 16'(KMAX));

    // -------------------------------------------------------------------------
    // Control registers and FSM: the only process that writes any of these.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            irq_en    <= 1'b0;
            done      <= 1'b0;
            err       <= 1'b0;
            len       <= '0;
            feed_k    <= '0;
            feed_base <= '0;
            drain_cnt <= '0;
            cycles    <= '0;
            active_cycles <= '0;
            mac_count <= '0;
        end else begin
            // Configuration writes
            if (ctrl_lane) irq_en <= reg_wr_data[3];
            if (we_len && reg_wr_strb[0]) len[7:0]  <= reg_wr_data[7:0];
            if (we_len && reg_wr_strb[1]) len[15:8] <= reg_wr_data[15:8];

            // W1C status bits. Set events below are later in the block, so a
            // set in the same cycle as a clear wins (no lost event).
            if (status_lane && reg_wr_data[1]) done <= 1'b0;
            if (status_lane && reg_wr_data[2]) err  <= 1'b0;

            if (busy) cycles <= cycles + 32'd1;

            if (req_soft_rst) begin
                // Abort: back to IDLE, status cleared. The array is cleared
                // combinationally below. LEN, IRQ_EN and the buffers are kept.
                state <= S_IDLE;
                done  <= 1'b0;
                err   <= 1'b0;
            end else begin
                // Commands that are illegal while a run is in flight.
                if (busy && (req_start || req_clr_acc)) err <= 1'b1;

                case (state)
                    S_IDLE: begin
                        if (req_start) begin
                            if (len_valid) begin
                                state  <= S_CLEAR;
                                done   <= 1'b0;
                                cycles <= 32'd0;
                                active_cycles <= 32'd0;
                                mac_count <= 64'd0;
                            end else begin
                                err <= 1'b1;
                            end
                        end
                    end

                    S_CLEAR: begin
                        state     <= S_FEED;
                        feed_k    <= '0;
                        feed_base <= '0;
                    end

                    S_FEED: begin
                        active_cycles <= active_cycles + 32'd1;
                        mac_count <= mac_count + MACS_PER_FEED;
                        if (feed_k == len - 16'd1) begin
                            state     <= S_DRAIN;
                            drain_cnt <= '0;
                        end else begin
                            feed_k    <= feed_k + 16'd1;
                            feed_base <= feed_base + BUF_IDX_W'(WPR);
                        end
                    end

                    default: begin  // S_DRAIN
                        active_cycles <= active_cycles + 32'd1;
                        if (drain_cnt == DRAIN_W'(DRAIN_CYCLES - 1)) begin
                            state <= S_IDLE;
                            done  <= 1'b1;
                        end else begin
                            drain_cnt <= drain_cnt + 1'b1;
                        end
                    end
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // Operand buffers (no reset: contents are defined by software before use).
    // -------------------------------------------------------------------------
    wire [BUF_IDX_W-1:0] wr_buf_idx = wr_word[BUF_IDX_W-1:0];

    always_ff @(posedge clk) begin
        if (we_a) begin
            for (int i = 0; i < 4; i++)
                if (reg_wr_strb[i]) a_mem[wr_buf_idx][i*8 +: 8] <= reg_wr_data[i*8 +: 8];
        end
    end

    always_ff @(posedge clk) begin
        if (we_b) begin
            for (int i = 0; i < 4; i++)
                if (reg_wr_strb[i]) b_mem[wr_buf_idx][i*8 +: 8] <= reg_wr_data[i*8 +: 8];
        end
    end

    // -------------------------------------------------------------------------
    // Array drive
    // -------------------------------------------------------------------------
    generate
        for (genvar j = 0; j < WPR; j++) begin : g_feed
            wire [BUF_IDX_W-1:0] idx = feed_base + BUF_IDX_W'(j);
            assign arr_a_flat[j*32 +: 32] = (state == S_FEED) ? a_mem[idx] : 32'd0;
            assign arr_b_flat[j*32 +: 32] = (state == S_FEED) ? b_mem[idx] : 32'd0;
        end
    endgenerate

    assign arr_en      = (state == S_FEED) || (state == S_DRAIN);
    assign arr_flush   = (state == S_CLEAR) || req_soft_rst;
    assign arr_clr_acc = (state == S_CLEAR) || req_soft_rst || (req_clr_acc && !busy);

    assign irq = done && irq_en;

    // -------------------------------------------------------------------------
    // Read mux (combinational, no side effects)
    // -------------------------------------------------------------------------
    wire [BUF_IDX_W-1:0] rd_buf_idx = rd_word[BUF_IDX_W-1:0];
    wire [RES_IDX_W-1:0] rd_res_idx = rd_word[RES_IDX_W-1:0];

    // Read mux is purely combinational and uses the broad Verilog sensitivity form.
    always @* begin
        reg_rd_data = 32'd0;
        reg_rd_resp = RESP_OKAY;
        case (rd_win)
            WIN_REGS: begin
                if (rd_word == W_CTRL)        reg_rd_data = {28'd0, irq_en, 3'd0};
                else if (rd_word == W_STATUS) reg_rd_data = {29'd0, err, done, busy};
                else if (rd_word == W_LEN)    reg_rd_data = {16'd0, len};
                else if (rd_word == W_INFO)   reg_rd_data = {16'(KMAX), 8'(IN_W), 8'(N)};
                else if (rd_word == W_CYCLES) reg_rd_data = cycles;
                else if (rd_word == W_ACTIVE) reg_rd_data = active_cycles;
                else if (rd_word == W_MAC_LO) reg_rd_data = mac_count[31:0];
                else if (rd_word == W_MAC_HI) reg_rd_data = mac_count[63:32];
                else                          reg_rd_resp = RESP_DECERR;
            end
            WIN_A: begin
                if (rd_in_buf) reg_rd_data = a_mem[rd_buf_idx];
                else           reg_rd_resp = RESP_DECERR;
            end
            WIN_B: begin
                if (rd_in_buf) reg_rd_data = b_mem[rd_buf_idx];
                else           reg_rd_resp = RESP_DECERR;
            end
            WIN_C: begin
                if (rd_in_res) reg_rd_data = arr_acc_flat[rd_res_idx*ACC_W +: 32];
                else           reg_rd_resp = RESP_DECERR;
            end
        endcase
    end

endmodule

`default_nettype wire
