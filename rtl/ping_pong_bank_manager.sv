// -----------------------------------------------------------------------------
// ping_pong_bank_manager.sv - ownership protocol for overlapped tile movement.
// -----------------------------------------------------------------------------
`default_nettype none

module ping_pong_bank_manager (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       fill_req,
    output logic      fill_gnt,
    output logic      fill_bank,
    input  wire       fill_done,
    output logic      consume_valid,
    input  wire       consume_ready,
    output logic      consume_bank,
    input  wire       consume_done,
    output logic      fill_active,
    output logic      consume_active,
    output logic      busy,
    output logic      error
);

    typedef enum logic [1:0] {FREE, FILL, READY, READ} bank_state_t;
    bank_state_t bank_state [0:1];
    logic fill_bank_q, consume_bank_q;
    logic free_present, ready_present;

    always_comb begin
        free_present = (bank_state[0] == FREE) || (bank_state[1] == FREE);
        ready_present = (bank_state[0] == READY) || (bank_state[1] == READY);
        fill_bank = (bank_state[0] == FREE) ? 1'b0 : 1'b1;
        consume_bank = (bank_state[0] == READY) ? 1'b0 : 1'b1;
        fill_gnt = fill_req && free_present;
        consume_valid = ready_present;
        fill_active = (bank_state[0] == FILL) || (bank_state[1] == FILL);
        consume_active = (bank_state[0] == READ) || (bank_state[1] == READ);
        busy = (bank_state[0] != FREE) || (bank_state[1] != FREE);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_state[0] <= FREE;
            bank_state[1] <= FREE;
            fill_bank_q <= 1'b0;
            consume_bank_q <= 1'b0;
            error <= 1'b0;
        end else begin
            if (fill_req && fill_gnt) begin
                fill_bank_q <= fill_bank;
                bank_state[fill_bank] <= FILL;
            end
            if (fill_done) begin
                if (bank_state[fill_bank_q] == FILL)
                    bank_state[fill_bank_q] <= READY;
                else
                    error <= 1'b1;
            end
            if (consume_valid && consume_ready) begin
                consume_bank_q <= consume_bank;
                bank_state[consume_bank] <= READ;
            end
            if (consume_done) begin
                if (bank_state[consume_bank_q] == READ)
                    bank_state[consume_bank_q] <= FREE;
                else
                    error <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
