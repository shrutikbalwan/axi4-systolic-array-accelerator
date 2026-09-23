// -----------------------------------------------------------------------------
// dual_bank_buffer.sv - synthesizable two-bank tile storage.
//
// Separate write/read bank selectors let DMA fill one bank while the compute
// side drains the other. The memory is intentionally exposed as simple ports;
// a board-specific wrapper can map it to BRAM, SRAM, or a registered array.
// The read port is synchronous, matching common FPGA block-RAM inference.
// -----------------------------------------------------------------------------
`default_nettype none

module dual_bank_buffer #(
    parameter int DATA_W = 32,
    parameter int DEPTH  = 1024,
    parameter int ADDR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  wire                  clk,
    input  wire                  wr_en,
    input  wire                  wr_bank,
    input  wire [ADDR_W-1:0]     wr_addr,
    input  wire [DATA_W-1:0]     wr_data,
    input  wire                  rd_en,
    input  wire                  rd_bank,
    input  wire [ADDR_W-1:0]     rd_addr,
    output logic [DATA_W-1:0]    rd_data,
    output logic                 rd_valid
);

    logic [DATA_W-1:0] mem [0:1][0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (wr_en)
            mem[wr_bank][wr_addr] <= wr_data;
        rd_valid <= rd_en;
        if (rd_en)
            rd_data <= mem[rd_bank][rd_addr];
    end

endmodule

`default_nettype wire
