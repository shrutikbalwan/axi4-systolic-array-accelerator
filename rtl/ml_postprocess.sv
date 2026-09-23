// -----------------------------------------------------------------------------
// ml_postprocess.sv - stream post-processing for quantized ML inference.
//
// y = (acc + bias) * scale_mult >>> scale_shift, followed by optional ReLU
// and saturation to signed INT8. The registered stage is intended to sit after
// an output tile and can later be driven by the DMA/tile controller.
// -----------------------------------------------------------------------------
`default_nettype none

module ml_postprocess #(
    parameter int ACC_W = 32,
    parameter int OUT_W = 8
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     valid_in,
    input  wire signed [ACC_W-1:0] acc_in,
    input  wire signed [ACC_W-1:0] bias_in,
    input  wire signed [ACC_W-1:0] scale_mult,
    input  wire        [5:0]        scale_shift,
    input  wire                     relu_en,
    output logic                    valid_out,
    output logic signed [OUT_W-1:0] data_out
);

    localparam logic signed [OUT_W-1:0] OUT_MIN = -(1 <<< (OUT_W - 1));
    localparam logic signed [OUT_W-1:0] OUT_MAX =  (1 <<< (OUT_W - 1)) - 1;

    logic signed [ACC_W-1:0] sum;
    logic signed [(2*ACC_W)-1:0] scaled;
    logic signed [ACC_W-1:0] shifted;

    always_comb begin
        sum     = acc_in + bias_in;
        scaled  = $signed({{ACC_W{sum[ACC_W-1]}}, sum}) *
                  $signed({{ACC_W{scale_mult[ACC_W-1]}}, scale_mult});
        shifted = scaled >>> scale_shift;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            data_out  <= '0;
        end else begin
            valid_out <= valid_in;
            if (valid_in) begin
                if (relu_en && (shifted < 0))
                    data_out <= '0;
                else if (shifted > OUT_MAX)
                    data_out <= OUT_MAX;
                else if (shifted < OUT_MIN)
                    data_out <= OUT_MIN;
                else
                    data_out <= shifted[OUT_W-1:0];
            end
        end
    end

endmodule

`default_nettype wire
