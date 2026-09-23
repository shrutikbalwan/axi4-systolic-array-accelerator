// -----------------------------------------------------------------------------
// ml_int8_packer.sv - integer ML post-process plus four-lane output packing.
//
// Converts the tiled GEMM INT32 stream into bias/requantized/ReLU INT8 values
// and packs four values into each 32-bit write-DMA beat. The final beat is
// zero-padded above the valid lanes and marked with out_last.
// -----------------------------------------------------------------------------
`default_nettype none

module ml_int8_packer (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire signed [31:0]      bias,
    input  wire signed [31:0]      scale_mult,
    input  wire                    relu_en,
    input  wire [5:0]              scale_shift,
    input  wire                    in_valid,
    output logic                   in_ready,
    input  wire signed [31:0]      in_data,
    input  wire                    in_last,
    output logic                   out_valid,
    input  wire                    out_ready,
    output logic [31:0]            out_data,
    output logic                   out_last
);

    logic [31:0] pack_q;
    logic [1:0] lane_q;
    logic out_valid_q, out_last_q;
    logic signed [7:0] quantized_value;
    logic signed [63:0] scaled_value;
    logic signed [31:0] shifted_value;
    logic signed [31:0] sum_value;

    always_comb begin
        sum_value = $signed(in_data) + $signed(bias);
        scaled_value = $signed({{32{sum_value[31]}}, sum_value}) *
                       $signed({{32{scale_mult[31]}}, scale_mult});
        shifted_value = scaled_value >>> scale_shift;
        if (relu_en && (shifted_value < 0))
            quantized_value = 8'sd0;
        else if (shifted_value > 127)
            quantized_value = 8'sd127;
        else if (shifted_value < -128)
            quantized_value = -8'sd128;
        else
            quantized_value = shifted_value[7:0];

        in_ready = !out_valid_q || out_ready;
        out_valid = out_valid_q;
        out_data = pack_q;
        out_last = out_valid_q && out_last_q;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pack_q <= 0;
            lane_q <= 0;
            out_valid_q <= 1'b0;
            out_last_q <= 1'b0;
        end else begin
            if (out_valid_q && out_ready)
                out_valid_q <= 1'b0;

            if (in_valid && in_ready) begin
                out_last_q <= in_last;
                if (lane_q == 2'd0) begin
                    if (in_last || (lane_q == 2'd3)) begin
                        pack_q <= {24'd0, quantized_value};
                        out_valid_q <= 1'b1;
                        lane_q <= 0;
                    end else begin
                        pack_q[7:0] <= quantized_value;
                        lane_q <= 1;
                    end
                end else if (lane_q == 2'd1) begin
                    if (in_last) begin
                        pack_q <= {16'd0, quantized_value, pack_q[7:0]};
                        out_valid_q <= 1'b1;
                        lane_q <= 0;
                    end else begin
                        pack_q[15:8] <= quantized_value;
                        lane_q <= 2;
                    end
                end else if (lane_q == 2'd2) begin
                    if (in_last) begin
                        pack_q <= {8'd0, quantized_value, pack_q[15:0]};
                        out_valid_q <= 1'b1;
                        lane_q <= 0;
                    end else begin
                        pack_q[23:16] <= quantized_value;
                        lane_q <= 3;
                    end
                end else begin
                    pack_q <= {quantized_value, pack_q[23:0]};
                    out_valid_q <= 1'b1;
                    lane_q <= 0;
                end
            end
        end
    end

endmodule

`default_nettype wire
