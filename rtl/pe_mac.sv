// -----------------------------------------------------------------------------
// pe_mac.sv - one output-stationary systolic processing element
//
// Timing contract (the array schedule depends on every line of this):
//   * act_in / wt_in are captured into act_reg / wt_reg on the clock edge.
//   * The product formed each cycle is of the REGISTERED operands, i.e. the
//     pair that is resident in this PE during that cycle.
//   * act_out / wt_out expose those same registers, so an operand takes exactly
//     ONE cycle per hop. The array adds no other pipeline stages.
//   * acc_out is acc_reg, unregistered: PE_LATENCY = 1 (the operand register).
//
//   en       gates all state (operands and accumulator).
//   clr_acc  clears the accumulator only.
//   flush    clears the operand registers only.
//   clr_acc / flush take priority over en.
// -----------------------------------------------------------------------------
`default_nettype none

module pe_mac #(
    parameter int IN_W  = 8,
    parameter int ACC_W = 32
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     en,
    input  wire                     clr_acc,
    input  wire                     flush,
    input  wire  signed [IN_W-1:0]  act_in,
    input  wire  signed [IN_W-1:0]  wt_in,
    output logic signed [IN_W-1:0]  act_out,   // -> east neighbour
    output logic signed [IN_W-1:0]  wt_out,    // -> south neighbour
    output logic signed [ACC_W-1:0] acc_out
);

    logic signed [IN_W-1:0]   act_reg;
    logic signed [IN_W-1:0]   wt_reg;
    logic signed [ACC_W-1:0]  acc_reg;

    // Both operands are signed, so the multiply is signed. The LHS is sized to
    // 2*IN_W so the full product is kept; do not shorten it.
    logic signed [2*IN_W-1:0] prod;
    logic signed [ACC_W-1:0]  prod_ext;

    always_comb begin
        prod     = act_reg * wt_reg;
        prod_ext = ACC_W'(prod);    // prod is signed, so this sign-extends
    end

    // Operand pipeline. Async reset comes from the synchronised reset; flush is
    // a separate synchronous clear (never merged into the async-reset term).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_reg <= '0;
            wt_reg  <= '0;
        end else if (flush) begin
            act_reg <= '0;
            wt_reg  <= '0;
        end else if (en) begin
            act_reg <= act_in;
            wt_reg  <= wt_in;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_reg <= '0;
        end else if (clr_acc) begin
            acc_reg <= '0;
        end else if (en) begin
            acc_reg <= acc_reg + prod_ext;
        end
    end

    assign act_out = act_reg;
    assign wt_out  = wt_reg;
    assign acc_out = acc_reg;

endmodule

`default_nettype wire
