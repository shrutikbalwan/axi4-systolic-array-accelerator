`default_nettype none

module axi4_write_dma_formal;
    (* gclk *) logic clk;
    logic past_valid;
    logic response_pending;
    logic seen_aw;
    (* anyseq *) logic rst_n;
    (* anyseq *) logic start;
    (* anyseq *) logic [31:0] base_addr;
    (* anyseq *) logic [31:0] word_count;
    (* anyseq *) logic m_axi_awready;
    (* anyseq *) logic m_axi_wready;
    (* anyseq *) logic [1:0] m_axi_bresp;
    (* anyseq *) logic m_axi_bvalid;
    (* anyseq *) logic [31:0] stream_data;
    (* anyseq *) logic stream_valid;
    (* anyseq *) logic stream_last;

    wire busy, done, error;
    wire [31:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire m_axi_awvalid;
    wire [31:0] m_axi_wdata;
    wire [3:0] m_axi_wstrb;
    wire m_axi_wlast, m_axi_wvalid, m_axi_bready, stream_ready;

    axi4_write_dma dut (.*);
    axi4_write_source_fvip_properties fvip_checker (
        .clk(clk), .rst_n(rst_n),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready)
    );

    initial begin
        past_valid = 1'b0;
        response_pending = 1'b0;
        seen_aw = 1'b0;
        assume(!rst_n);
    end

    always @(posedge clk) begin
        past_valid <= 1'b1;
        if (past_valid)
            assume(rst_n);

        // This word-oriented DMA accepts only naturally aligned descriptors.
        if (start)
            assume(base_addr[1:0] == 2'b00);

        // The upstream ready/valid stream must hold its payload under stall.
        if (past_valid && $past(rst_n && stream_valid && !stream_ready)) begin
            assume(stream_valid);
            assume(stream_data == $past(stream_data));
            assume(stream_last == $past(stream_last));
        end

        if (!rst_n) begin
            response_pending <= 1'b0;
            seen_aw <= 1'b0;
        end else begin
            if (m_axi_awvalid && m_axi_awready) begin
                if (seen_aw)
                    cover(1'b1); // A second burst is reachable within depth 40.
                seen_aw <= 1'b1;
            end

            // Model a legal write destination: a response follows the final
            // accepted W beat and remains stable until BREADY.
            if (m_axi_wvalid && m_axi_wready && m_axi_wlast)
                response_pending <= 1'b1;
            if (m_axi_bvalid && m_axi_bready)
                response_pending <= 1'b0;

            assume(m_axi_bvalid == response_pending);
            assume(m_axi_bresp == 2'b00);
            if (past_valid && $past(rst_n && m_axi_bvalid && !m_axi_bready)) begin
                assume(m_axi_bvalid);
                assume(m_axi_bresp == $past(m_axi_bresp));
            end
        end
    end
endmodule

`default_nettype wire
