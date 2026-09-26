// -----------------------------------------------------------------------------
// axi4_write_dma.sv - simple contiguous AXI4 INCR burst writer.
//
// One request at a time, 32-bit data, ready/valid stream input, and bursts of
// up to MAX_BURST words. The source is back-pressured until AW is accepted and
// remains back-pressured while a burst response is outstanding.
// -----------------------------------------------------------------------------
`default_nettype none

module axi4_write_dma #(
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

    output logic [ADDR_W-1:0]     m_axi_awaddr,
    output logic [7:0]             m_axi_awlen,
    output logic [2:0]             m_axi_awsize,
    output logic [1:0]             m_axi_awburst,
    output logic                   m_axi_awvalid,
    input  wire                    m_axi_awready,
    output logic [DATA_W-1:0]      m_axi_wdata,
    output logic [DATA_W/8-1:0]    m_axi_wstrb,
    output logic                   m_axi_wlast,
    output logic                   m_axi_wvalid,
    input  wire                    m_axi_wready,
    input  wire [1:0]              m_axi_bresp,
    input  wire                    m_axi_bvalid,
    output logic                   m_axi_bready,

    input  wire [DATA_W-1:0]       stream_data,
    input  wire                    stream_valid,
    output logic                   stream_ready,
    input  wire                    stream_last
);

    localparam int BURST_W = (MAX_BURST > 1) ? $clog2(MAX_BURST + 1) : 1;

    typedef enum logic [1:0] {S_IDLE, S_AW, S_W, S_B} state_t;
    state_t state;
    logic [ADDR_W-1:0] addr_q;
    logic [31:0] remaining_q;
    logic [BURST_W-1:0] burst_q;
    logic [BURST_W-1:0] beats_q;
    logic [BURST_W-1:0] next_burst;
    logic [31:0] burst_limit_wide;

    // AXI4 (IHI 0022, A3.4.1): a burst must not cross a 4KB address boundary.
    // addr_q[11:2] is the word index within the page (0..1023), so beats left
    // in the page is 1024 - that, ranging 1..1024. Needs 11 bits of its own.
    wire [10:0] beats_to_page_end = 11'd1024 - {1'b0, addr_q[11:2]};

    always_comb begin
        if (remaining_q > MAX_BURST)
            burst_limit_wide = MAX_BURST;
        else
            burst_limit_wide = remaining_q;
        if (burst_limit_wide > {21'b0, beats_to_page_end})
            burst_limit_wide = {21'b0, beats_to_page_end};

        // The three-way minimum is at most MAX_BURST, which fits BURST_W by construction.
        /* verilator lint_off WIDTHTRUNC */
        next_burst = burst_limit_wide;
        /* verilator lint_on WIDTHTRUNC */

        busy          = (state != S_IDLE);
        m_axi_awaddr  = addr_q;
        m_axi_awlen   = next_burst - 1'b1;
        m_axi_awsize  = 3'b010;
        m_axi_awburst = 2'b01;
        m_axi_awvalid = (state == S_AW);

        m_axi_wdata  = stream_data;
        m_axi_wstrb  = {(DATA_W / 8){1'b1}};
        m_axi_wlast  = (state == S_W) && (beats_q == 1);
        m_axi_wvalid = (state == S_W) && stream_valid;
        stream_ready = (state == S_W) && m_axi_wready;
        m_axi_bready = (state == S_B);
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
                            state <= S_AW;
                        end
                    end
                end

                S_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        burst_q <= next_burst;
                        beats_q <= next_burst;
                        state   <= S_W;
                    end
                end

                S_W: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        if (stream_last != ((remaining_q == burst_q) && (beats_q == 1)))
                            error <= 1'b1;
                        if (beats_q == 1)
                            state <= S_B;
                        else
                            beats_q <= beats_q - 1'b1;
                    end
                end

                S_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        if (m_axi_bresp != 2'b00)
                            error <= 1'b1;
                        if (remaining_q == burst_q) begin
                            remaining_q <= 0;
                            state       <= S_IDLE;
                            done        <= 1'b1;
                        end else begin
                            remaining_q <= remaining_q - burst_q;
                            addr_q      <= addr_q + (burst_q * (DATA_W / 8));
                            state       <= S_AW;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
