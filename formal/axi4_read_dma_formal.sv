`default_nettype none

module axi4_read_dma_formal;
    (* gclk *) logic clk;
    logic past_valid;
    logic [8:0] response_beats;
    logic seen_ar;
    (* anyseq *) logic rst_n;
    (* anyseq *) logic start;
    (* anyseq *) logic [31:0] base_addr;
    (* anyseq *) logic [31:0] word_count;
    (* anyseq *) logic m_axi_arready;
    (* anyseq *) logic [31:0] m_axi_rdata;
    (* anyseq *) logic [1:0] m_axi_rresp;
    (* anyseq *) logic m_axi_rlast;
    (* anyseq *) logic m_axi_rvalid;
    (* anyseq *) logic stream_ready;

    wire busy, done, error;
    wire [31:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arvalid, m_axi_rready;
    wire [31:0] stream_data;
    wire stream_valid, stream_last;

    axi4_read_dma dut (.*);
    axi4_read_source_fvip_properties fvip_checker (
        .clk(clk), .rst_n(rst_n),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready)
    );

    initial begin
        past_valid = 1'b0;
        response_beats = '0;
        seen_ar = 1'b0;
        assume(!rst_n);
    end

    always @(posedge clk) begin
        past_valid <= 1'b1;
        if (past_valid)
            assume(rst_n);

        // This word-oriented DMA accepts only naturally aligned descriptors.
        if (start)
            assume(base_addr[1:0] == 2'b00);

        if (!rst_n) begin
            response_beats <= '0;
            seen_ar <= 1'b0;
        end else begin
            // Model a legal, single-outstanding AXI read destination.
            if (m_axi_arvalid && m_axi_arready) begin
                assume(response_beats == 0);
                response_beats <= {1'b0, m_axi_arlen} + 9'd1;
                if (seen_ar)
                    cover(1'b1); // A second burst is reachable within depth 40.
                seen_ar <= 1'b1;
            end

            if (response_beats != 0) begin
                assume(m_axi_rvalid);
                assume(m_axi_rresp == 2'b00);
                assume(m_axi_rlast == (response_beats == 1));
                if (m_axi_rvalid && m_axi_rready)
                    response_beats <= response_beats - 1'b1;
            end else begin
                assume(!m_axi_rvalid);
                assume(!m_axi_rlast);
            end

            if (past_valid && $past(rst_n && m_axi_rvalid && !m_axi_rready)) begin
                assume(m_axi_rvalid);
                assume(m_axi_rdata == $past(m_axi_rdata));
                assume(m_axi_rresp == $past(m_axi_rresp));
                assume(m_axi_rlast == $past(m_axi_rlast));
            end
        end
    end
endmodule

`default_nettype wire
