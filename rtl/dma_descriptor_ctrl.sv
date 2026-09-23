// -----------------------------------------------------------------------------
// dma_descriptor_ctrl.sv - control/status block for the tiled DMA datapath.
//
// This block uses the same simple register-port convention as accel_ctrl. It
// owns descriptors and sticky completion/error state, but not the DMA engines.
// The host can therefore program descriptors while the proven AXI4-Lite GEMM
// control path remains unchanged.
// -----------------------------------------------------------------------------
`default_nettype none

module dma_descriptor_ctrl (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        reg_wr_en,
    input  wire [11:0] reg_wr_addr,
    input  wire [31:0] reg_wr_data,
    input  wire [3:0]  reg_wr_strb,
    output logic [1:0] reg_wr_resp,
    input  wire [11:0] reg_rd_addr,
    output logic [31:0] reg_rd_data,
    output logic [1:0] reg_rd_resp,

    output wire        dma_start,
    output wire        dma_abort,
    output logic       irq_en,
    output logic [31:0] a_base,
    output logic [31:0] b_base,
    output logic [31:0] c_base,
    output logic [31:0] matrix_m,
    output logic [31:0] matrix_n,
    output logic [31:0] matrix_k,
    output logic [31:0] tile_m,
    output logic [31:0] tile_n,
    output logic [31:0] tile_k,
    output logic signed [31:0] post_bias,
    output logic signed [31:0] post_scale_mult,
    output logic        post_relu,
    output logic [5:0]  post_scale_shift,
    output logic        post_output_int8,
    input  wire        dma_busy,
    input  wire        dma_done,
    input  wire        dma_error,
    input  wire [31:0] perf_active_cycles,
    input  wire [63:0] perf_mac_count,
    input  wire [31:0] perf_tile_count,
    output wire        irq
);

    localparam logic [9:0] W_CTRL   = 10'h000;
    localparam logic [9:0] W_STATUS = 10'h001;
    localparam logic [9:0] W_A_BASE = 10'h002;
    localparam logic [9:0] W_B_BASE = 10'h003;
    localparam logic [9:0] W_C_BASE = 10'h004;
    localparam logic [9:0] W_M      = 10'h005;
    localparam logic [9:0] W_N      = 10'h006;
    localparam logic [9:0] W_K      = 10'h007;
    localparam logic [9:0] W_TILE_M = 10'h008;
    localparam logic [9:0] W_TILE_N = 10'h009;
    localparam logic [9:0] W_TILE_K = 10'h00A;
    localparam logic [9:0] W_POST_BIAS = 10'h00B;
    localparam logic [9:0] W_POST_SCALE = 10'h00C;
    localparam logic [9:0] W_POST_CFG = 10'h00D;
    localparam logic [9:0] W_PERF_ACTIVE = 10'h00E;
    localparam logic [9:0] W_PERF_MAC_LO = 10'h00F;
    localparam logic [9:0] W_PERF_MAC_HI = 10'h010;
    localparam logic [9:0] W_PERF_TILES = 10'h011;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    wire [9:0] wr_word = reg_wr_addr[11:2];
    wire [9:0] rd_word = reg_rd_addr[11:2];
    wire ctrl_wr       = reg_wr_en && (wr_word == W_CTRL);
    wire status_wr     = reg_wr_en && (wr_word == W_STATUS);
    wire cfg_wr        = reg_wr_en && (wr_word >= W_A_BASE) && (wr_word <= W_POST_CFG);
    wire cfg_locked    = dma_busy && cfg_wr;

    assign dma_start = ctrl_wr && reg_wr_strb[0] && reg_wr_data[0] && !dma_busy;
    assign dma_abort = ctrl_wr && reg_wr_strb[0] && reg_wr_data[1];
    assign irq       = irq_en && (done_q || error_q);

    logic done_q;
    logic error_q;

    always_comb begin
        reg_wr_resp = RESP_OKAY;
        if (cfg_locked)
            reg_wr_resp = RESP_SLVERR;
        else if (reg_wr_en && !((wr_word == W_CTRL) || (wr_word == W_STATUS) ||
                                ((wr_word >= W_A_BASE) && (wr_word <= W_POST_CFG))))
            reg_wr_resp = RESP_DECERR;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_en  <= 1'b0;
            done_q  <= 1'b0;
            error_q <= 1'b0;
            a_base  <= 0;
            b_base  <= 0;
            c_base  <= 0;
            matrix_m <= 0;
            matrix_n <= 0;
            matrix_k <= 0;
            tile_m <= 0;
            tile_n <= 0;
            tile_k <= 0;
            post_bias <= 0;
            post_scale_mult <= 0;
            post_relu <= 1'b0;
            post_scale_shift <= 0;
            post_output_int8 <= 1'b0;
        end else begin
            if (ctrl_wr && reg_wr_strb[0])
                irq_en <= reg_wr_data[2];
            if (status_wr && reg_wr_strb[0] && reg_wr_data[1])
                done_q <= 1'b0;
            if (status_wr && reg_wr_strb[0] && reg_wr_data[2])
                error_q <= 1'b0;

            if (dma_done)
                done_q <= 1'b1;
            if (dma_error)
                error_q <= 1'b1;
            // A new accepted descriptor starts a fresh completion epoch.
            // This assignment is intentionally after event capture so a stale
            // aggregate-done level cannot immediately reassert DONE.
            if (dma_start) begin
                done_q  <= 1'b0;
                error_q <= 1'b0;
            end

            if (cfg_wr && !dma_busy) begin
                case (wr_word)
                    W_A_BASE: begin
                        for (int i = 0; i < 4; i++) if (reg_wr_strb[i]) a_base[i*8 +: 8] <= reg_wr_data[i*8 +: 8];
                    end
                    W_B_BASE: begin
                        for (int i = 0; i < 4; i++) if (reg_wr_strb[i]) b_base[i*8 +: 8] <= reg_wr_data[i*8 +: 8];
                    end
                    W_C_BASE: begin
                        for (int i = 0; i < 4; i++) if (reg_wr_strb[i]) c_base[i*8 +: 8] <= reg_wr_data[i*8 +: 8];
                    end
                    W_M: begin
                        for (int i = 0; i < 4; i++) if (reg_wr_strb[i]) matrix_m[i*8 +: 8] <= reg_wr_data[i*8 +: 8];
                    end
                    W_N: begin
                        for (int i = 0; i < 4; i++) if (reg_wr_strb[i]) matrix_n[i*8 +: 8] <= reg_wr_data[i*8 +: 8];
                    end
                    W_K: begin
                        for (int i = 0; i < 4; i++) if (reg_wr_strb[i]) matrix_k[i*8 +: 8] <= reg_wr_data[i*8 +: 8];
                    end
                    W_TILE_M: begin
                        for (int i = 0; i < 4; i++) if (reg_wr_strb[i]) tile_m[i*8 +: 8] <= reg_wr_data[i*8 +: 8];
                    end
                    W_TILE_N: begin
                        for (int i = 0; i < 4; i++) if (reg_wr_strb[i]) tile_n[i*8 +: 8] <= reg_wr_data[i*8 +: 8];
                    end
                    W_TILE_K: begin
                        for (int i = 0; i < 4; i++) if (reg_wr_strb[i]) tile_k[i*8 +: 8] <= reg_wr_data[i*8 +: 8];
                    end
                    W_POST_BIAS: begin
                        for (int i = 0; i < 4; i++) if (reg_wr_strb[i]) post_bias[i*8 +: 8] <= reg_wr_data[i*8 +: 8];
                    end
                    W_POST_SCALE: begin
                        for (int i = 0; i < 4; i++) if (reg_wr_strb[i]) post_scale_mult[i*8 +: 8] <= reg_wr_data[i*8 +: 8];
                    end
                    W_POST_CFG: begin
                        if (reg_wr_strb[0]) begin
                            post_relu <= reg_wr_data[0];
                            post_output_int8 <= reg_wr_data[1];
                            post_scale_shift <= reg_wr_data[7:2];
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

    always_comb begin
        reg_rd_data = 32'd0;
        reg_rd_resp = RESP_OKAY;
        case (rd_word)
            W_CTRL:   reg_rd_data = {29'd0, irq_en, 2'd0};
            W_STATUS: reg_rd_data = {29'd0, error_q, done_q, dma_busy};
            W_A_BASE: reg_rd_data = a_base;
            W_B_BASE: reg_rd_data = b_base;
            W_C_BASE: reg_rd_data = c_base;
            W_M:      reg_rd_data = matrix_m;
            W_N:      reg_rd_data = matrix_n;
            W_K:      reg_rd_data = matrix_k;
            W_TILE_M: reg_rd_data = tile_m;
            W_TILE_N: reg_rd_data = tile_n;
            W_TILE_K: reg_rd_data = tile_k;
            W_POST_BIAS: reg_rd_data = post_bias;
            W_POST_SCALE: reg_rd_data = post_scale_mult;
            W_POST_CFG: reg_rd_data = {24'd0, post_scale_shift, post_output_int8, post_relu};
            W_PERF_ACTIVE: reg_rd_data = perf_active_cycles;
            W_PERF_MAC_LO: reg_rd_data = perf_mac_count[31:0];
            W_PERF_MAC_HI: reg_rd_data = perf_mac_count[63:32];
            W_PERF_TILES: reg_rd_data = perf_tile_count;
            default:  reg_rd_resp = RESP_DECERR;
        endcase
    end

endmodule

`default_nettype wire
