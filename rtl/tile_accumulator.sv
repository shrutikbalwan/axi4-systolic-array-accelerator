// -----------------------------------------------------------------------------
// tile_accumulator.sv - INT32 accumulation across K tiles.
//
// Each start_tile begins one partial C tile. first_k selects overwrite versus
// accumulate; last_k selects whether the completed tile is streamed out. The
// fixed N*N word count is authoritative, so upstream burst boundaries do not
// need to align with tile boundaries.
// -----------------------------------------------------------------------------
`default_nettype none

module tile_accumulator #(
    parameter int N     = 4,
    parameter int ACC_W = 32
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start_tile,
    input  wire                    first_k,
    input  wire                    last_k,
    output logic                    busy,
    output logic                    done,
    output logic                    tile_done,
    output logic                    error,

    input  wire signed [ACC_W-1:0] in_data,
    input  wire                    in_valid,
    output logic                    in_ready,
    input  wire                    in_last,

    output logic signed [ACC_W-1:0] out_data,
    output logic                    out_valid,
    input  wire                     out_ready,
    output logic                    out_last
);

    localparam int WORDS = N * N;
    localparam int IDX_W = (WORDS > 1) ? $clog2(WORDS) : 1;

    typedef enum logic [1:0] {S_IDLE, S_CONSUME, S_OUTPUT} state_t;
    state_t state;
    logic [IDX_W-1:0] in_count, out_count;
    logic first_q, last_q;
    logic signed [ACC_W-1:0] acc_mem [0:WORDS-1];
    logic signed [ACC_W-1:0] prior_value;
    logic signed [ACC_W-1:0] next_value;

    always_comb begin
        busy       = (state != S_IDLE);
        in_ready   = (state == S_CONSUME);
        out_valid  = (state == S_OUTPUT);
        out_data   = acc_mem[out_count];
        out_last   = out_valid && (out_count == WORDS - 1);
        prior_value = first_q ? '0 : acc_mem[in_count];
        next_value  = prior_value + in_data;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            in_count  <= '0;
            out_count <= '0;
            first_q   <= 1'b0;
            last_q    <= 1'b0;
            done      <= 1'b0;
            tile_done <= 1'b0;
            error     <= 1'b0;
        end else begin
            done <= 1'b0;
            tile_done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start_tile) begin
                        first_q  <= first_k;
                        last_q   <= last_k;
                        in_count <= '0;
                        state    <= S_CONSUME;
                        error    <= 1'b0;
                    end
                end

                S_CONSUME: begin
                    if (in_valid && in_ready) begin
                        acc_mem[in_count] <= next_value;
                        if (in_count == WORDS - 1) begin
                            in_count <= '0;
                            if (last_q) begin
                                out_count <= '0;
                                state <= S_OUTPUT;
                            end else begin
                                state <= S_IDLE;
                                tile_done <= 1'b1;
                            end
                        end else begin
                            in_count <= in_count + 1'b1;
                        end
                    end
                end

                S_OUTPUT: begin
                    if (out_valid && out_ready) begin
                        if (out_count == WORDS - 1) begin
                            out_count <= '0;
                            state <= S_IDLE;
                            done  <= 1'b1;
                            tile_done <= 1'b1;
                        end else begin
                            out_count <= out_count + 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // LAST is advisory; the fixed N*N word contract is authoritative.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_last = in_last;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
