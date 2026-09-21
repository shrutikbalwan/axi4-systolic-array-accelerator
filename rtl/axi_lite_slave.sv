`default_nettype none

module axi_lite_slave #
(
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_DATA_WIDTH = 32
)
(
    // AXI4-Lite Slave Interface
    input  wire               s_axi_aclk,
    input  wire               s_axi_aresetn,
    // Write Address Channel
    input  wire     [AXI_ADDR_WIDTH-1:0]  s_axi_awaddr,
    input  wire               s_axi_awvalid,
    output wire               s_axi_awready,
    // Write Data Channel
    input  wire     [AXI_DATA_WIDTH-1:0]  s_axi_wdata,
    input  wire     [(AXI_DATA_WIDTH/8)-1:0]  s_axi_wstrb,
    input  wire               s_axi_wvalid,
    output wire               s_axi_wready,
    // Write Response Channel
    output wire     [1:0]     s_axi_bresp,
    output wire               s_axi_bvalid,
    input  wire               s_axi_bready,
    // Read Address Channel
    input  wire     [AXI_ADDR_WIDTH-1:0]  s_axi_araddr,
    input  wire               s_axi_arvalid,
    output wire               s_axi_arready,
    // Read Data Channel
    output wire     [AXI_DATA_WIDTH-1:0]  s_axi_rdata,
    output wire     [1:0]     s_axi_rresp,
    output wire               s_axi_rvalid,
    input  wire               s_axi_rready
);

// ================================================================
// REGISTER MAP (word addresses = byte_addr / 4)
localparam CTRL     = 32'h00  // CTRL register
localparam STATUS   = 32'h04  // STATUS register
localparam LEN      = 32'h08  // FEED cycle count
localparam ACT_BUF  = 32'h10  // Activation buffer (N*N bytes, packed 4/word)
localparam WT_BUF   = 32'h50  // Weight buffer (N*N bytes, packed 4/word)
localparam RESULT   = 32'h100 // Result window (N*N x 32-bit, read-only)

// ================================================================
// INTERNAL REGISTER FILE
// ================================================================
// All registers are 32-bit. Written via AXI writes, read via AXI reads.

// CTRL register bits
// Bit 0: START (write-1-to-pulse, self-clearing)
// Bit 1: CLR_ACC (pulsed, clears accumulators)
// Bit 2: SOFT_RST (pulsed, resets all state)
// Bit 3: IRQ_EN (enables interrupt)
reg     [31:0]  ctrl_r;

// STATUS register bits
// Bit 0: BUSY (1 = FEED or DRAIN in progress, cleared 1 cycle after DONE)
// Bit 1: DONE (sticky, write-1-to-clear, 1 = computation complete)
// Bit 2: ERR (error flag, write-1-to-clear)
reg     [31:0]  status_r;

// LEN register: number of FEED cycles
reg     [31:0]  len_r;

// ACT_BUF register: activation buffer (N*N bytes packed 4/word)
reg     [31:0]  act_buf_r;

// WT_BUF register: weight buffer (N*N bytes packed 4/word)
reg     [31:0]  wt_buf_r;

// RESULT register window (C00..C33, 16 x 32-bit)
reg     [31:0]  result_r [0:15];

// ================================================================
// AXI4-LITE WRITE ADDRESS CHANNEL FSM
// ================================================================
always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn) begin
        s_axi_awready <= 1'b1;
    end else begin
        if (s_axi_awvalid && s_axi_awready) begin
            s_axi_awready <= 1'b0;
        end else if (!s_axi_awvalid) begin
            s_axi_awready <= 1'b1;
        end
    end
end

// ================================================================
// AXI4-LITE WRITE DATA CHANNEL FSM
// ================================================================
always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn) begin
        s_axi_wready <= 1'b1;
    end else begin
        if (s_axi_wvalid && s_axi_wready) begin
            s_axi_wready <= 1'b0;
        end else if (!s_axi_wvalid) begin
            s_axi_wready <= 1'b1;
        end
    end
end

// ================================================================
// AXI4-LITE WRITE RESPONSE CHANNEL
// ================================================================
always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn) begin
        s_axi_bvalid <= 1'b0;
    end else begin
        if (s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid && s_axi_bready) begin
            s_axi_bvalid <= 1'b1;
        end else if (s_axi_bvalid && s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
        end
    end
end
assign s_axi_bresp = 2'b00;  // OKAY

// ================================================================
// REGISTER WRITE LOGIC
// ================================================================
// Update registers when AXI write transaction completes (awvalid && wvalid)
always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn) begin
        ctrl_r     <= '0;
        status_r   <= '0;
        len_r      <= '0;
        act_buf_r  <= '0;
        wt_buf_r   <= '0;
    end else begin
        if (s_axi_awvalid && s_axi_wvalid) begin
            case (s_axi_awaddr[AXI_ADDR_WIDTH-1:2])  // Byte addr -> word index
                CTRL:   ctrl_r     <= s_axi_wdata;
                STATUS: status_r   <= s_axi_wdata;
                LEN:    len_r      <= s_axi_wdata;
                ACT_BUF: act_buf_r <= s_axi_wdata;
                WT_BUF:  wt_buf_r  <= s_axi_wdata;
                RESULT: begin
                            // Result registers are read-only via AXI read,
                            // but writing here allows soft reset to clear them
                            // We map to result_r[0] through result_r[15] sequentially
                            integer idx = (AWADDR_W - CTRL) / 4;
                            if (idx >= 0 && idx < 16) begin
                                result_r[idx] <= s_axi_wdata;
                            end
                        end
                default:  ; // Unknown address
            endcase
        end
    end
end

// ================================================================
// AXI4-LITE READ ADDRESS CHANNEL FSM
// ================================================================
always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn) begin
        s_axi_arready <= 1'b1;
    end else begin
        if (s_axi_arvalid && s_axi_arready) begin
            s_axi_arready <= 1'b0;
        end else if (!s_axi_arvalid) begin
            s_axi_arready <= 1'b1;
        end
    end
end

// ================================================================
// READ DATA MUX
// ================================================================
always_comb begin
    case (s_axi_araddr[AXI_ADDR_WIDTH-1:2])  // Byte address -> word index
        CTRL:   s_axi_rdata = ctrl_r;
        STATUS: s_axi_rdata = status_r;
        LEN:    s_axi_rdata = len_r;
        ACT_BUF: s_axi_rdata = act_buf_r;
        WT_BUF:  s_axi_rdata = wt_buf_r;
        RESULT: begin
            // Map word index to result register
            // 0x100 -> C00 (result_r[0]), 0x104 -> C01 (result_r[1]), ..., 0x13C -> C33 (result_r[15])
            integer idx = (AWADDR_W - RESULT) / 4;
            if (idx >= 0 && idx < 16) begin
                s_axi_rdata = result_r[idx];
            end else begin
                s_axi_rdata = '0;
            end
        end
        default:  s_axi_rdata = '0;
    endcase
    s_axi_rresp = 2'b00;  // OKAY
end

// ================================================================
// RVALID PULSE GENERATION
// ================================================================
always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn) begin
        s_axi_rvalid <= 1'b0;
    end else begin
        if (s_axi_arvalid && s_axi_arready) begin
            s_axi_rvalid <= 1'b1;
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end
end

// ================================================================
// OUTPUT ASSIGNMENTS
// ================================================================
assign s_axi_rdata = /* mux output */;  // Assigned in always_comb
assign s_axi_rresp = 2'b00;

// For the top-level, we expose the key registers as outputs that can be connected
// The full register file is accessible via AXI reads
endmodule : axi_lite_slave