// -----------------------------------------------------------------------------
// axi4_read_dma.sv - simple contiguous AXI4 INCR burst reader.
//
// The engine is intentionally a small integration block: one request at a
// time, read-only, 32-bit data, and a ready/valid stream output. It issues
// bursts of up to MAX_BURST words and never loses stream backpressure. A tile
// buffer or the tile_scheduler can sit behind the stream without knowing AXI.
// -----------------------------------------------------------------------------
`default_nettype none

module axi4_read_dma #(
    parameter int ADDR_W    = 32,
    parameter int DATA_W    = 32,
    parameter int MAX_BURST = 16
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   start,
    input  wire [ADDR_W-1:0]      base_addr,
    input  wire [31:0]            word_count,
    output logic                   busy,
    output logic                   done,
    output logic                   error,

    output logic [ADDR_W-1:0]     m_axi_araddr,
    output logic [7:0]             m_axi_arlen,
    output logic [2:0]             m_axi_arsize,
    output logic [1:0]             m_axi_arburst,
    output logic                   m_axi_arvalid,
    input  wire                    m_axi_arready,
    input  wire [DATA_W-1:0]       m_axi_rdata,
    input  wire [1:0]              m_axi_rresp,
    input  wire                    m_axi_rlast,
    input  wire                    m_axi_rvalid,
    output logic                   m_axi_rready,

    output logic [DATA_W-1:0]      stream_data,
    output logic                   stream_valid,
    input  wire                    stream_ready,
    output logic                   stream_last
);

    localparam int BURST_W = (MAX_BURST > 1) ? $clog2(MAX_BURST + 1) : 1;

    typedef enum logic [1:0] {S_IDLE, S_AR, S_R, S_ERROR} state_t;
    state_t state;
    logic [ADDR_W-1:0] addr_q;
    logic [31:0] remaining_q;
    logic [BURST_W-1:0] burst_q;
    logic [BURST_W-1:0] beats_q;
    logic [BURST_W-1:0] next_burst;

    always_comb begin
        if (remaining_q > MAX_BURST)
            next_burst = MAX_BURST[BURST_W-1:0];
        else
            next_burst = remaining_q[BURST_W-1:0];

        busy          = (state != S_IDLE);
        m_axi_araddr  = addr_q;
        // The first AR is issued before burst_q is latched; advertise the
        // combinationally selected length for that request.
        m_axi_arlen   = next_burst - 1'b1;
        m_axi_arsize  = 3'b010;       // 4-byte beats
        m_axi_arburst = 2'b01;        // INCR
        m_axi_arvalid = (state == S_AR);
        m_axi_rready  = (state == S_R) ? stream_ready : (state == S_ERROR);

        stream_data  = m_axi_rdata;
        stream_valid = (state == S_R) && m_axi_rvalid;
        stream_last  = stream_valid && (remaining_q == burst_q) &&
                       (beats_q == 1);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            addr_q      <= '0;
            remaining_q <= '0;
            burst_q     <= '0;
            beats_q     <= '0;
            done        <= 1'b0;
            error       <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        addr_q      <= base_addr;
                        remaining_q <= word_count;
                        error       <= 1'b0;
                        if (word_count == 0) begin
                            done <= 1'b1;
                        end else begin
                            state <= S_AR;
                        end
                    end
                end

                S_AR: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        burst_q <= next_burst;
                        beats_q <= next_burst;
                        state   <= S_R;
                    end
                end

                S_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        if (m_axi_rresp != 2'b00 || m_axi_rlast != (beats_q == 1)) begin
                            error <= 1'b1;
                            if (m_axi_rlast) begin
                                state <= S_IDLE;
                                done  <= 1'b1;
                            end else begin
                                state <= S_ERROR;
                            end
                        end else if (beats_q == 1) begin
                            if (remaining_q == burst_q) begin
                                remaining_q <= 0;
                                state       <= S_IDLE;
                                done        <= 1'b1;
                            end else begin
                                remaining_q <= remaining_q - burst_q;
                                addr_q      <= addr_q + (burst_q * (DATA_W / 8));
                                state       <= S_AR;
                            end
                        end else begin
                            beats_q <= beats_q - 1'b1;
                        end
                    end
                end

                S_ERROR: begin
                    // Drain the rest of the AXI burst before returning idle.
                    if (m_axi_rvalid && m_axi_rready && m_axi_rlast) begin
                        state <= S_IDLE;
                        done  <= 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
