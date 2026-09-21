`default_nettype none

module systolic_accelerator_top #
(
    parameter IN_W = 8,       // Input width (8 = INT8)
    parameter ACC_W = 32,      // Accumulator width (32 = INT32)
    parameter PE_DEPTH = 4      // Array dimension (4 = 4x4 array)
)
(
    // Clock and Reset
    input  wire               clk,
    input  wire               rst_n,       // Active-low, async

    // AXI4-Lite Slave Interface (connected to external bus master)
    // Write Address Channel
    output wire               axi_awvalid,
    input  wire               axi_awready,
    output wire     [31:0]    axi_awaddr,
    output wire     [3:0]     axi_awprot,

    // Write Data Channel
    output wire               axi_wvalid,
    input  wire               axi_wready,
    output wire     [31:0]    axi_wdata,
    output wire     [3:0]     axi_wstrb,

    // Write Response Channel
    input  wire               axi_bvalid,
    output wire               axi_bready,
    input  wire     [1:0]     axi_bresp,

    // Read Address Channel
    output wire               axi_arvalid,
    input  wire               axi_arready,
    output wire     [31:0]    axi_araddr,
    output wire     [3:0]     axi_arprot,

    // Read Data Channel
    input  wire               axi_rvalid,
    output wire               axi_rready,
    input  wire     [31:0]    axi_rdata,
    input  wire     [1:0]     axi_rresp
);

// ================================================================
// INTERNAL SIGNALS
// ================================================================

// AXI4-Lite internal signals
wire               axil_awvalid;
wire               axil_awready;
wire     [31:0]    axil_awaddr;
wire               axil_wvalid;
wire               axil_wready;
wire     [31:0]    axil_wdata;
wire               axil_bvalid;
wire               axil_bready;
wire     [1:0]     axil_bresp;
wire               axil_arvalid;
wire               axil_arready;
wire     [31:0]    axil_araddr;
wire               axil_rvalid;
wire               axil_rready;
wire     [31:0]    axil_rdata;
wire     [1:0]     axil_rresp;

// Connect top-level AXI4-Lite signals
assign axi_awvalid   = axil_awvalid;
assign axi_awaddr    = axil_awaddr;
assign axi_awprot    = 2'b00;
axil_awready         = axi_awready;
assign axi_wvalid    = axil_wvalid;
assign axi_wdata     = axil_wdata;
assign axi_wstrb     = 4'b11;
axil_wready          = axi_wready;
assign axi_bvalid    = axil_bvalid;
assign axi_bready    = 1'b1;
assign axi_bresp     = axil_bresp;
assign axi_arvalid   = axil_arvalid;
assign axi_araddr    = axil_araddr;
assign axi_arprot    = 2'b00;
axil_arready         = axi_arready;
assign axi_rvalid    = axil_rvalid;
assign axi_rready    = 1'b1;
assign axi_rdata     = axil_rdata;
assign axi_rresp     = axil_rresp;

// ================================================================
// INTERNAL SIGNALS FOR ACCELERATOR CONTROL
// ================================================================

// Control register bits (from AXI writes at 0x00)
wire            ctrl_start     = axil_wdata[0];    // START (W1P)
wire            ctrl_clr_acc   = axil_wdata[1];    // CLR_ACC (pulsed)
wire            ctrl_soft_rst  = axil_wdata[2];    // SOFT_RST (pulsed)
wire            ctrl_irq_en    = axil_wdata[3];    // IRQ_ENABLE

// Status register bits (read back from AXI reads at 0x04)
wire            status_busy    = axil_rdata[0];    // BUSY
wire            status_done    = axil_rdata[1];    // DONE (sticky, W1C)
wire            status_err     = axil_rdata[2];    // ERR

// LEN register value (from AXI reads at 0x08)
wire    [31:0]  len_val        = axil_rdata;  // Actually from LEN reg, but using rdata for simplicity

// ACT_BUF and WT_BUF values (from AXI reads)
wire    [31:0]  act_buf_val    = axil_rdata;  // Simplified: just use rdata
wire    [31:0]  wt_buf_val     = axil_rdata;

// RESULT window values (from AXI reads at 0x100-0x13C)
wire    [31:0]  result_val     [0:15];  // Would need individual reads

// ================================================================
// ACCELERATOR FSM STATE
// ================================================================
// States: IDLE(2'd0) → LOAD(2'd1) → FEED(2'd2) → DRAIN(2'd3) → DONE(2'd4)
reg     [1:0]   state;       // Current FSM state
reg     [3:0]   cycle_cnt;       // Cycle counter for FEED/DRAIN
reg     [3:0]   len_reg;           // FEED cycle count from LEN register

// Control signals
reg             en;            // Systolic array enable
reg             clr_acc;       // Clear accumulator
reg             start;         // Start pulse (1-cycle)
reg             soft_rst;      // Soft reset pulse
reg             irq;           // Interrupt pulse

// Status signals
reg             status_busy;     // 1 = FEED or DRAIN in progress
reg             status_done;     // 1 = computation complete (W1C)
reg             status_err;      // 1 = error flag

// Cycle counter for FSM transitions
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= 2'd0;       // IDLE
        cycle_cnt   <= '0;
        len_reg     <= '0;
        en          <= 1'b0;
        clr_acc     <= 1'b0;
        start       <= 1'b0;
        soft_rst    <= 1'b0;
        irq         <= 1'b0;
        status_busy <= 1'b0;
        status_done <= 1'b0;
        status_err  <= 1'b0;
    end else begin
        // Default: hold values
        clr_acc <= 1'b0;
        start <= 1'b0;
        soft_rst <= 1'b0;
        irq <= 1'b0;

        case (state)
            2'd0: IDLE begin  // IDLE
                if (ctrl_start) begin
                    state <= 2'd1;       // LOAD
                    cycle_cnt <= '0;
                    en <= 1'b0;
                end
            end

            2'd1: LOAD begin  // LOAD
                clr_acc <= 1'b1;  // Clear accumulators
                state <= 2'd2;       // FEED
                en <= 1'b1;       // Enable systolic array
            end

            2'd2: FEED begin  // FEED
                if (cycle_cnt < len_reg) begin
                    cycle_cnt <= cycle_cnt + 1'd1;
                    // Each cycle: present activation/weight bytes to systolic array
                end else begin
                    state <= 2'd3;       // DRAIN
                end
            end

            2'd3: DRAIN begin  // DRAIN
                if (cycle_cnt < 7) begin  // 2*PE_DEPTH-2 + PE_LATENCY = 7 for N=4
                    cycle_cnt <= cycle_cnt + 1'd1;
                end else begin
                    state <= 2'd4;       // DONE
                end
            end

            2'd4: DONE begin  // DONE
                status_done <= 1'b1;   // Stick DONE high
                irq <= 1'b1;           // Pulse interrupt (1 cycle)
                en <= 1'b0;            // Disable systolic array
                
                // Stay in DONE until CLR_ACC is written
                if (ctrl_clr_acc) begin
                    status_done <= 1'b0;  // Clear DONE (W1C)
                    state <= 2'd0;       // Go to IDLE
                    cycle_cnt <= '0;
                    en <= 1'b0;
                    clr_acc <= 1'b0;
                    soft_rst <= 1'b0;
                    irq <= 1'b0;
                end
            end
        endcase
    end

    // Status register always block
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            status_busy <= 1'b0;
            status_done <= 1'b0;
            status_err <= 1'b0;
        end else begin
            case (state)
                2'd0: IDLE:   status_busy <= 1'b0; status_done <= 1'b0; status_err <= 1'b0;
                2'd1: LOAD:   status_busy <= 1'b1; status_done <= 1'b0; status_err <= 1'b0;
                2'd2: FEED:   status_busy <= 1'b1; status_done <= 1'b0; status_err <= 1'b0;
                2'd3: DRAIN:  status_busy <= 1'b1; status_done <= 1'b0; status_err <= 1'b0;
                2'd4: DONE:   status_busy <= 1'b0; status_done <= 1'b1; status_err <= 1'b0;
            endcase
        end
    end

    // IRQ pulse: 1 cycle when entering DONE state
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq <= 1'b0;
        end else if (state == 2'd4 && state_prev != 2'd4) begin
            irq <= 1'b1;  // Pulse when entering DONE
        end else begin
            irq <= 1'b0;
        end
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_prev <= 2'd0;
        end else begin
            state_prev <= state;
        end
    end
end

// ================================================================
// SYSTOLIC ARRAY INSTANTIATION
// ================================================================
// The 4x4 systolic array that performs matrix multiplication
systolic_array_4x4 #(
    .IN_W(IN_W),
    .ACC_W(ACC_W),
    .PE_DEPTH(PE_DEPTH)
) systolic_array (
    // Clock and Reset
    .clk             (clk),
    .rst_n           (rst_n),

    // Enable and control
    .en              (en),
    .clr_acc         (clr_acc),

    // Activation stream from left (horizontal) - 4x INT8 packed per 32-bit word
    // During FEED phase, activation bytes are presented to the array
    // ACT_BUF register at 0x10 contains packed activations
    .act_in          (/* would connect to act_buf_r from axi_lite_slave */),

    // Weight stream from top (vertical) - 4x INT8 packed per 32-bit word
    // During FEED phase, weight bytes are presented to the array
    .wt_in           (/* would connect to wt_buf_r from axi_lite_slave */),

    // Accumulator outputs - 4x4 matrix (C00 through C33)
    .pe_acc_out      (/* output matrix C00..C33, read via AXI reads at 0x100-0x13C */)
);

// ================================================================
// TOP-LEVEL SIGNAL ASSIGNMENTS
// ================================================================
// AXI4-Lite handshake signals
assign axi_awvalid   = axil_awvalid;
assign axi_awaddr    = axil_awaddr;
assign axi_awprot    = 2'b00;
axil_awready         = axi_awready;
assign axi_wvalid    = axil_wvalid;
assign axi_wdata     = axil_wdata;
assign axi_wstrb     = 4'b11;
axil_wready          = axi_wready;
assign axi_bvalid    = axil_bvalid;
assign axi_bready    = 1'b1;
assign axi_bresp     = axil_bresp;
assign axi_arvalid   = axil_arvalid;
assign axi_araddr    = axil_araddr;
assign axi_arprot    = 2'b00;
axil_arready         = axi_arready;
assign axi_rvalid    = axil_rvalid;
assign axi_rready    = 1'b1;
assign axi_rdata     = axil_rdata;
assign axi_rresp     = axil_rresp;

// Output assignments for status and control
// These would be connected to the AXI slave's register file for readback

endmodule : systolic_accelerator_top