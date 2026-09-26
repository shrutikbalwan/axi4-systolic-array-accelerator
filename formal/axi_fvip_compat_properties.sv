// Yosys-compatible ports of applicable rules from YosysHQ-GmbH/SVA-AXI4-FVIP
// commit 250f1ffd47fc1cdc4b4dd1670c6e1df58dec1b12 (ISC license).
// The upstream named/parameterized SVA properties are expressed as clocked
// immediate assertions because stock Yosys cannot lower those SVA constructs.
`default_nettype none

module axi_lite_destination_fvip_properties #(
    parameter int DATA_W = 32
) (
    input wire                 clk,
    input wire                 rst_n,
    input wire                 s_axi_bvalid,
    input wire [1:0]           s_axi_bresp,
    input wire                 s_axi_bready,
    input wire                 s_axi_rvalid,
    input wire [DATA_W-1:0]    s_axi_rdata,
    input wire [1:0]           s_axi_rresp,
    input wire                 s_axi_rready
);
    logic past_valid;

    initial past_valid = 1'b0;
    always @(posedge clk) begin
        past_valid <= 1'b1;

        // FVIP ap_B_EXIT_RESET / ap_R_EXIT_RESET, AXI4 A3.1.2.
        if (!rst_n) begin
            assert(!s_axi_bvalid);
            assert(!s_axi_rvalid);
        end

        if (past_valid && rst_n && $past(rst_n)) begin
            // FVIP ap_B_BVALID_until_BREADY and ap_B_STABLE_BRESP,
            // AXI4 A3.2.1: VALID and payload remain stable until handshake.
            if ($past(s_axi_bvalid && !s_axi_bready)) begin
                assert(s_axi_bvalid);
                assert(s_axi_bresp == $past(s_axi_bresp));
            end

            // FVIP ap_R_RVALID_until_RREADY, ap_R_STABLE_RDATA and
            // ap_R_STABLE_RRESP, AXI4 A3.2.1.
            if ($past(s_axi_rvalid && !s_axi_rready)) begin
                assert(s_axi_rvalid);
                assert(s_axi_rdata == $past(s_axi_rdata));
                assert(s_axi_rresp == $past(s_axi_rresp));
            end
        end
    end
endmodule

module axi4_read_source_fvip_properties #(
    parameter int ADDR_W = 32,
    parameter int DATA_W = 32,
    parameter int MAX_BURST = 16
) (
    input wire                 clk,
    input wire                 rst_n,
    input wire [ADDR_W-1:0]    m_axi_araddr,
    input wire [7:0]           m_axi_arlen,
    input wire [2:0]           m_axi_arsize,
    input wire [1:0]           m_axi_arburst,
    input wire                 m_axi_arvalid,
    input wire                 m_axi_arready
);
    logic past_valid;
    wire [ADDR_W-1:0] arlen_wide = {{(ADDR_W-8){1'b0}}, m_axi_arlen};
    wire [ADDR_W-1:0] ar_end_addr = m_axi_araddr + (arlen_wide << m_axi_arsize);

    initial past_valid = 1'b0;
    always @(posedge clk) begin
        past_valid <= 1'b1;

        // FVIP ap_AR_EXIT_RESET, AXI4 A3.1.2.
        if (!rst_n)
            assert(!m_axi_arvalid);

        if (rst_n && m_axi_arvalid) begin
            // FVIP ap_AR_ARADDR_BOUNDARY_4KB, AXI4 A3.4.1.
            assert(m_axi_araddr[ADDR_W-1:12] == ar_end_addr[ADDR_W-1:12]);
            // FVIP ap_AR_CORRECT_BURST_SIZE / ap_AR_BURST_TYPES.
            assert(m_axi_arsize <= $clog2(DATA_W/8));
            assert(m_axi_arburst != 2'b11);
            // FVIP ap_AR_ARLEN_MAX_RD_BURST_LEN.
            assert(m_axi_arlen < MAX_BURST);
        end

        // FVIP ap_AR_STABLE_* and ap_AR_ARVALID_until_ARREADY, AXI4 A3.2.1.
        if (past_valid && rst_n && $past(rst_n) &&
            $past(m_axi_arvalid && !m_axi_arready)) begin
            assert(m_axi_arvalid);
            assert(m_axi_araddr == $past(m_axi_araddr));
            assert(m_axi_arlen == $past(m_axi_arlen));
            assert(m_axi_arsize == $past(m_axi_arsize));
            assert(m_axi_arburst == $past(m_axi_arburst));
        end
    end
endmodule

module axi4_write_source_fvip_properties #(
    parameter int ADDR_W = 32,
    parameter int DATA_W = 32,
    parameter int MAX_BURST = 16
) (
    input wire                 clk,
    input wire                 rst_n,
    input wire [ADDR_W-1:0]    m_axi_awaddr,
    input wire [7:0]           m_axi_awlen,
    input wire [2:0]           m_axi_awsize,
    input wire [1:0]           m_axi_awburst,
    input wire                 m_axi_awvalid,
    input wire                 m_axi_awready,
    input wire [DATA_W-1:0]    m_axi_wdata,
    input wire [DATA_W/8-1:0]  m_axi_wstrb,
    input wire                 m_axi_wlast,
    input wire                 m_axi_wvalid,
    input wire                 m_axi_wready
);
    logic past_valid;
    logic [8:0] beats_left;
    wire [ADDR_W-1:0] awlen_wide = {{(ADDR_W-8){1'b0}}, m_axi_awlen};
    wire [ADDR_W-1:0] aw_end_addr = m_axi_awaddr + (awlen_wide << m_axi_awsize);

    initial begin
        past_valid = 1'b0;
        beats_left = '0;
    end

    always @(posedge clk) begin
        past_valid <= 1'b1;

        if (!rst_n) begin
            // FVIP ap_AW_EXIT_RESET / ap_W_EXIT_RESET, AXI4 A3.1.2.
            assert(!m_axi_awvalid);
            assert(!m_axi_wvalid);
            beats_left <= '0;
        end else begin
            if (m_axi_awvalid) begin
                // FVIP ap_AW_AWADDR_BOUNDARY_4KB, AXI4 A3.4.1.
                assert(m_axi_awaddr[ADDR_W-1:12] == aw_end_addr[ADDR_W-1:12]);
                // FVIP ap_AW_CORRECT_BURST_SIZE / ap_AW_BURST_TYPES.
                assert(m_axi_awsize <= $clog2(DATA_W/8));
                assert(m_axi_awburst != 2'b11);
                // FVIP ap_AW_AWLEN_MAX_WR_BURST_LEN.
                assert(m_axi_awlen < MAX_BURST);
            end

            if (m_axi_awvalid && m_axi_awready)
                beats_left <= {1'b0, m_axi_awlen} + 9'd1;

            if (m_axi_wvalid) begin
                assert(beats_left != 0);
                assert(m_axi_wlast == (beats_left == 1));
            end
            if (m_axi_wvalid && m_axi_wready)
                beats_left <= beats_left - 1'b1;
        end

        // FVIP ap_AW_STABLE_* and ap_AW_AWVALID_until_AWREADY.
        if (past_valid && rst_n && $past(rst_n) &&
            $past(m_axi_awvalid && !m_axi_awready)) begin
            assert(m_axi_awvalid);
            assert(m_axi_awaddr == $past(m_axi_awaddr));
            assert(m_axi_awlen == $past(m_axi_awlen));
            assert(m_axi_awsize == $past(m_axi_awsize));
            assert(m_axi_awburst == $past(m_axi_awburst));
        end

        // FVIP ap_W_STABLE_* and ap_W_WVALID_until_WREADY.
        if (past_valid && rst_n && $past(rst_n) &&
            $past(m_axi_wvalid && !m_axi_wready)) begin
            assert(m_axi_wvalid);
            assert(m_axi_wdata == $past(m_axi_wdata));
            assert(m_axi_wstrb == $past(m_axi_wstrb));
            assert(m_axi_wlast == $past(m_axi_wlast));
        end
    end
endmodule

`default_nettype wire
