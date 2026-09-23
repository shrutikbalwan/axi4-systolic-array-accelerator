// -----------------------------------------------------------------------------
// axi_lite_slave.sv - AXI4-Lite slave -> simple register port.
//
// Pure bus adapter: no accelerator state lives here. The register side is a
// single-cycle request with a same-cycle (combinational) response:
//
//   write:  reg_wr_en pulses for one cycle with addr/data/strb; the register
//           block returns reg_wr_resp in that same cycle.
//   read:   reg_rd_addr is valid while the AR handshake happens; the register
//           block returns reg_rd_data/reg_rd_resp combinationally, and they are
//           registered here into RDATA/RRESP. Reads must have no side effects.
//
// Protocol notes (AMBA AXI IHI0022, AXI4-Lite):
//   * AW and W are accepted independently, in either order, one of each held.
//   * VALID outputs never wait on the master's READY (A3.2.1): BVALID is set by
//     the write itself; RVALID by the AR handshake.
//   * RDATA is registered from the address sampled AT the AR handshake, so the
//     master may change ARADDR afterwards without corrupting the response.
//   * AWPROT/ARPROT are accepted and ignored: this slave has no protection
//     domains. The ports exist because AXI4-Lite requires them.
//   * One write and one read may be outstanding at a time (AXI4-Lite has no
//     IDs, so responses are trivially in order).
// -----------------------------------------------------------------------------
`default_nettype none

module axi_lite_slave #(
    parameter int ADDR_W = 14,
    parameter int DATA_W = 32
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // AXI4-Lite slave
    input  wire  [ADDR_W-1:0]     s_axi_awaddr,
    input  wire  [2:0]            s_axi_awprot,
    input  wire                   s_axi_awvalid,
    output logic                  s_axi_awready,
    input  wire  [DATA_W-1:0]     s_axi_wdata,
    input  wire  [DATA_W/8-1:0]   s_axi_wstrb,
    input  wire                   s_axi_wvalid,
    output logic                  s_axi_wready,
    output logic [1:0]            s_axi_bresp,
    output logic                  s_axi_bvalid,
    input  wire                   s_axi_bready,
    input  wire  [ADDR_W-1:0]     s_axi_araddr,
    input  wire  [2:0]            s_axi_arprot,
    input  wire                   s_axi_arvalid,
    output logic                  s_axi_arready,
    output logic [DATA_W-1:0]     s_axi_rdata,
    output logic [1:0]            s_axi_rresp,
    output logic                  s_axi_rvalid,
    input  wire                   s_axi_rready,

    // Register port
    output logic                  reg_wr_en,
    output logic [ADDR_W-1:0]     reg_wr_addr,
    output logic [DATA_W-1:0]     reg_wr_data,
    output logic [DATA_W/8-1:0]   reg_wr_strb,
    input  wire  [1:0]            reg_wr_resp,
    output logic [ADDR_W-1:0]     reg_rd_addr,
    input  wire  [DATA_W-1:0]     reg_rd_data,
    input  wire  [1:0]            reg_rd_resp
);

    // -------------------------------------------------------------------------
    // Write path: hold one AW and one W; perform the register write when both
    // are present and no response is still waiting for BREADY.
    // -------------------------------------------------------------------------
    logic                 aw_full;
    logic                 w_full;
    logic [ADDR_W-1:0]    aw_addr_q;
    logic [DATA_W-1:0]    w_data_q;
    logic [DATA_W/8-1:0]  w_strb_q;
    logic                 do_write;

    assign s_axi_awready = !aw_full;
    assign s_axi_wready  = !w_full;
    assign do_write      = aw_full && w_full && !s_axi_bvalid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_full   <= 1'b0;
            aw_addr_q <= '0;
        end else if (s_axi_awvalid && s_axi_awready) begin
            aw_full   <= 1'b1;
            aw_addr_q <= s_axi_awaddr;
        end else if (do_write) begin
            aw_full   <= 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_full   <= 1'b0;
            w_data_q <= '0;
            w_strb_q <= '0;
        end else if (s_axi_wvalid && s_axi_wready) begin
            w_full   <= 1'b1;
            w_data_q <= s_axi_wdata;
            w_strb_q <= s_axi_wstrb;
        end else if (do_write) begin
            w_full   <= 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
        end else if (do_write) begin
            s_axi_bvalid <= 1'b1;
            s_axi_bresp  <= reg_wr_resp;
        end else if (s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
        end
    end

    assign reg_wr_en   = do_write;
    assign reg_wr_addr = aw_addr_q;
    assign reg_wr_data = w_data_q;
    assign reg_wr_strb = w_strb_q;

    // -------------------------------------------------------------------------
    // Read path: accept an address whenever no read response is pending.
    // -------------------------------------------------------------------------
    logic do_read;

    assign s_axi_arready = !s_axi_rvalid;
    assign do_read       = s_axi_arvalid && s_axi_arready;
    assign reg_rd_addr   = s_axi_araddr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= '0;
            s_axi_rresp  <= 2'b00;
        end else if (do_read) begin
            s_axi_rvalid <= 1'b1;
            s_axi_rdata  <= reg_rd_data;
            s_axi_rresp  <= reg_rd_resp;
        end else if (s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

    // AxPROT carry no meaning for this slave (see header).
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_prot = ^{s_axi_awprot, s_axi_arprot};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
