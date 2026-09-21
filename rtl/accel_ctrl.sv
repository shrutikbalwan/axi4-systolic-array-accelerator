`default_nettype none

module accel_ctrl #
(
    parameter IN_W = 8,       // Input width (8 = INT8)
    parameter ACC_W = 32,      // Accumulator width (32 = INT32)
    parameter PE_DEPTH = 4      // Array dimension (4 = 4x4 array)
)
(
    // Clock and Reset
    input  wire               clk,
    input  wire               rst_n,       // Active-low, async

    // Interface to AXI4-Lite slave (register memory-mapped)
    input  wire     [31:0]    axi_ctrl_data,   // Data bus from AXI slave writes
    input  wire               axi_ctrl_write,  // Write strobe from AXI slave
    input  wire     [31:0]    axi_addr,        // Address from AXI slave

    // Interface to systolic array
    output reg                en,          // Enable systolic array (1 = active)
    output reg                clr_acc,     // Clear accumulators (pulsed)
    output reg                start,       // Start pulse (1-cycle, self-clearing)
    output reg                soft_rst,    // Soft reset (pulsed, resets all state)
    output reg                irq,         // Interrupt pulse (1-cycle, asserted with DONE, W1C)

    // Status and control outputs
    output reg    [31:0]      status,      // Status register value (BUSY/DONE/ERR)
    output reg    [31:0]                  // Result registers from systolic array
);

    // ================================================================
    // PARAMETERS
    // ================================================================
    localparam IDLE   = 2'd0;
    localparam LOAD   = 2'd1;
    localparam FEED   = 2'd2;
    localparam DRAIN  = 2'd3;
    localparam DONE   = 2'd4;

    // ================================================================
    // INTERNAL STATE
    // ================================================================
    reg     [1:0]     state;       // Current FSM state
    reg     [3:0]     cycle_cnt;       // Cycle counter for FEED phase
    reg     [3:0]     len_reg;           // LEN register value (from AXI)

    // Control register bits
    wire            ctrl_start;      // Write-1-to-pulse from CTRL register
    wire            ctrl_clr_acc;    // Clear accumulators
    wire            ctrl_soft_rst;   // Soft reset
    wire            ctrl_irq_en;     // IRQ enable

    // Status register bits
    wire            status_busy;     // 1 = FEED or DRAIN in progress
    wire            status_done;     // 1 = computation complete (W1C)

    // ================================================================
    // AXI4-LITE ADDRESS DECODING
    // ================================================================
    // Decode addresses to control registers
    always_comb begin
        case (axi_addr[31:2])  // Byte address -> word index
            32'h00:   ctrl_start    = axi_ctrl_data[0];
            32'h00+1: ctrl_clr_acc    = axi_ctrl_data[1];
            32'h00+2: ctrl_soft_rst   = axi_ctrl_data[2];
            32'h00+3: ctrl_irq_en     = axi_ctrl_data[3];
            default:  ; // Unknown sub-offset
        endcase
    end

    // LEN register at offset 0x08
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            len_reg <= '0;
        end else if (axi_ctrl_write && (axi_addr == 32'h08)) begin
            len_reg <= axi_ctrl_data[31:0];
        end
    end

    // ================================================================
    // ACCELERATOR FSM
    // ================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state      <= IDLE;
            cycle_cnt  <= '0;
            status     <= '0;
            en         <= 1'b0;
            clr_acc    <= 1'b0;
            start      <= 1'b0;
            soft_rst   <= 1'b0;
            irq        <= 1'b0;
        end else begin
            // Default assignments (hold values)
            clr_acc    <= 1'b0;
            start      <= 1'b0;
            soft_rst   <= 1'b0;
            irq        <= 1'b0;

            case (state)
                IDLE: begin
                    // Wait for START pulse
                    if (ctrl_start) begin
                        state <= LOAD;
                        cycle_cnt <= '0;
                    end
                end

                LOAD: begin
                    // Load phase: assert clr_acc to clear accumulators from previous run
                    // Then transition to FEED
                    clr_acc <= 1'b1;
                    state <= FEED;
                    en <= 1'b1;  // Enable systolic array
                end

                FEED: begin
                    // FEED phase: run for len_reg cycles
                    // Drive activation/weight buffers via AXI slave
                    if (cycle_cnt < len_reg) begin
                        cycle_cnt <= cycle_cnt + 1'd1;
                        // Data is presented to systolic array each cycle
                    end else begin
                        // Transition to DRAIN when cycle count reached
                        state <= DRAIN;
                    end
                end

                DRAIN: begin
                    // DRAIN phase: allow pipeline to propagate
                    // 2*N-2 + PE_LATENCY cycles for N=4 = 6+1 = 7 cycles
                    // After this, results are valid in PE accumulators
                    if (cycle_cnt < 7) begin
                        cycle_cnt <= cycle_cnt + 1'd1;
                    end else begin
                        // Transition to DONE
                        state <= DONE;
                    end
                end

                DONE: begin
                    // DONE phase: stick high status, pulse irq
                    status     <= 32'h02;  // DONE bit set
                    irq        <= 1'b1;    // Pulse interrupt (1 cycle)
                    en         <= 1'b0;    // Disable systolic array
                    
                    // Stay in DONE until CLR_ACC or SOFT_RST is written
                    if (ctrl_clr_acc) begin
                        state <= IDLE;
                        status <= '0;
                        cycle_cnt <= '0;
                    end
                end
            endcase
        end
    end

    // ================================================================
    // STATUS REGISTER LOGIC
    // ================================================================
    // Status is sticky: DONE stays high until CLR_ACC is written
    // BUSY is cleared one cycle after DONE is asserted
    
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            status <= '0;
        end else begin
            case (state)
                IDLE:   status <= 32'h00;  // BUSY low, DONE low
                LOAD:   status <= 32'h01;  // BUSY high (clr_acc asserted)
                FEED:   status <= 32'h03;  // BUSY high, DONE low
                DRAIN:  status <= 32'h03;  // BUSY high, DONE low
                DONE:   status <= 32'h02;  // BUSY low, DONE high (sticky)
                default: status <= '0;
            endcase
        end
    end

    // DONE is write-1-to-clear: writing 1 to CTRL_CLR_ACC clears it
    // Actually, DONE stays until explicit clear. The FSM enters IDLE on CLR_ACC.
    // For software readability: DONE bit in STATUS register is W1C (write-1-to-clear).
    // Software must write 1 to CTRL_CLR_ACC bit to clear the DONE status.

    // ================================================================
    // IRQ OUTPUT
    // ================================================================
    // IRQ is pulsed high for exactly 1 cycle when DONE is entered
    // It stays high for one cycle, then low. Software clears by reading STATUS
    // and writing CTRL_CLR_ACC (or the DONE bit naturally clears on next IDLE transition).
    
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            irq <= 1'b0;
        end else if (state == DONE && state_prev != DONE) begin
            // Pulse irq for one cycle when entering DONE state
            irq <= 1'b1;
        end else begin
            irq <= 1'b0;
        end
    end
    
    // Store previous state for edge detection
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_prev <= IDLE;
        end else begin
            state_prev <= state;
        end
    end

    // ================================================================
    // PUBLIC INTERFACE ASSIGNMENTS
    // ================================================================
    assign en          = (state == FEED || state == DRAIN) ? 1'b1 : 1'b0;
    assign clr_acc     = (state == LOAD)     ? 1'b1 : 1'b0;  // Pulsed during LOAD phase
    assign start       = (state == IDLE && ctrl_start) ? 1'b1 : 1'b0;  // 1-cycle pulse
    assign soft_rst    = ctrl_soft_rst;     // Direct from AXI write

    // The full result register file would be populated from the systolic array
    // For this ctrl module, we just provide the control/status interface
    // The result_regs are read from the AXI4-Lite slave's result_r array
endmodule : accel_ctrl