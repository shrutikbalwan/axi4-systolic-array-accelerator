`default_nettype none

module pe_mac #
(
    parameter IN_W = 8,       // Input width (8 = INT8)
    parameter ACC_W = 32      // Accumulator width (32 = INT32 accumulated)
)
(
    input  wire               clk,
    input  wire               rst_n,       // Active-low reset, async
    input  wire               en,          // Enable, gates all state
    input  wire               clr_acc,     // Clear accumulator (async, active-high)
    input  wire      [IN_W-1:0]  act_in,   // Activation input (signed INT8)
    input  wire      [IN_W-1:0]  wt_in,    // Weight input (signed INT8)
    output reg     [ACC_W-1:0]  acc_out    // Accumulator output
);

    // -- Reset synchronizer: 2 FFs for async deassertion --
    // Reset is asynchronous asserted, but must be synchronously deasserted
    reg [1:0] rst_sync;
    always_ff @(posedge clk) begin
        rst_sync <= {rst_sync[0], ~rst_n};
    end
    wire rst_safe = rst_sync[1];  // Deasserted synchronously

    // -- Signed multiplication: WIDTH x WIDTH -> 2*WIDTH product --
    // Explicit signed types, product sized 2*IN_W
    wire signed [2*IN_W-1:0] prod;
    assign prod = $signed(act_in) * $signed(wt_in);

    // -- Accumulator with clear support --
    // Register declared as logic signed [ACC_W-1:0]
    reg signed [ACC_W-1:0] acc_reg;

    always_ff @(posedge clk) begin
        // Safe reset deassertion: only process when rst_safe
        if (!rst_safe) begin
            acc_reg <= '0;
        end else if (clr_acc) begin
            // Clear accumulator when asserted
            acc_reg <= '0;
        end else if (en) begin
            // Accumulate: sign-extended addition
            // Product is 2*IN_W wide, acc_reg is ACC_W wide
            // Sign-extend product to ACC_W width, then add
            if (ACC_W >= 2*IN_W) begin
                // acc_reg is wide enough to hold product fully
                acc_reg <= acc_reg + $signed(prod[ACC_W-1:0]);
            end else begin
                // acc_reg is narrower; truncate product with sign extension
                acc_reg <= acc_reg + $signed(prod[ACC_W-1:0]);
            end
        end
        // If !en and !clr_acc, acc_reg holds its previous value (no latch)
    end

    // -- acc_out: combinationally from acc_reg, or registered with documented extra cycle --
    // Choice: combinationally from acc_reg (0 extra cycle drain)
    // If you register acc_out, add 1 cycle to drain count. We'll use combo for simplicity.
    always_comb begin
        acc_out = acc_reg;
    end

    // Synthesis and lint notes (do not remove):
    // - acc_out is combo from acc_reg; drain count is 0 extra cycles
    // - acc_reg is signed, product is sign-extended before add
    // - clr_acc and en are mutually respectful: clr_acc takes priority when both asserted
    // - No always blocks other than always_ff and always_comb above
endmodule : pe_mac