// -----------------------------------------------------------------------------
// systolic_array.sv - N x N output-stationary systolic GEMM array
//
//   C[r][c] = sum_k A[r][k] * B[k][c]
//
// INPUT CONTRACT (unskewed - the caller does NOT pre-skew):
//   on feed cycle k (k = 0 .. K-1), with en = 1:
//       a_flat[r*IN_W +: IN_W] = A[r][k]   for every row r
//       b_flat[c*IN_W +: IN_W] = B[k][c]   for every column c
//   After the last feed cycle, drive zeros and hold en = 1 for 2N-1 cycles.
//
// SCHEDULE (see docs/dataflow.md for the full derivation):
//   Row r is delayed r cycles at the west edge, so A[r][k] enters at k + r.
//   Column c is delayed c cycles at the north edge, so B[k][c] enters at k + c.
//   Each PE hop costs one cycle, so PE(r,c) holds A[r][k] at k + r + c + 1 and
//   B[k][c] at k + c + r + 1 - the same cycle, for every r, c, k.
//   The last accumulation (PE(N-1,N-1), k = K-1) is on the edge ending cycle
//   K + 2N - 2, i.e. 2N - 1 cycles after the last feed cycle.
//
// Each row and each column owns an INDEPENDENT delay line fed by its OWN input.
// All intra-array movement is done by the PEs' pass-through registers.
//
// All internal buses are flat packed vectors: 2-D unpacked nets across generate
// boundaries are the thing that breaks tool portability (Yosys, Icarus).
// -----------------------------------------------------------------------------
`default_nettype none

module systolic_array #(
    parameter int N     = 4,
    parameter int IN_W  = 8,
    parameter int ACC_W = 32
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   en,
    input  wire                   clr_acc,   // clear accumulators only
    input  wire                   flush,     // clear operand pipeline only
    input  wire  [N*IN_W-1:0]     a_flat,
    input  wire  [N*IN_W-1:0]     b_flat,
    // acc_flat[(r*N + c)*ACC_W +: ACC_W] == C[r][c]
    output wire  [N*N*ACC_W-1:0]  acc_flat
);

    // Edge-skewed streams: a_skew[r*IN_W +: IN_W] enters row r from the west.
    wire [N*IN_W-1:0] a_skew;
    wire [N*IN_W-1:0] b_skew;

    // Horizontal operand bus: slot (r*(N+1) + c) is the input to PE(r,c);
    // slot (r*(N+1) + N) is the (unused) output of the last PE in the row.
    wire [N*(N+1)*IN_W-1:0] a_h;
    // Vertical operand bus: slot (r*N + c) is the input to PE(r,c);
    // row N holds the (unused) outputs of the bottom row.
    wire [(N+1)*N*IN_W-1:0] b_v;

    genvar gi, gr, gc;

    // -------------------------------------------------------------------------
    // Edge skew: line i has depth i, fed only by input i.
    // -------------------------------------------------------------------------
    generate
        for (gi = 0; gi < N; gi++) begin : g_skew
            if (gi == 0) begin : g_pass
                assign a_skew[0 +: IN_W] = a_flat[0 +: IN_W];
                assign b_skew[0 +: IN_W] = b_flat[0 +: IN_W];
            end else begin : g_delay
                localparam int W = gi * IN_W;
                logic [W-1:0] a_line;   // oldest sample in the top IN_W bits
                logic [W-1:0] b_line;
                wire  [W-1:0] a_next;   // line shifted up by one sample
                wire  [W-1:0] b_next;

                if (gi == 1) begin : g_one
                    assign a_next = a_flat[gi*IN_W +: IN_W];
                    assign b_next = b_flat[gi*IN_W +: IN_W];
                end else begin : g_many
                    assign a_next = {a_line[W-IN_W-1:0], a_flat[gi*IN_W +: IN_W]};
                    assign b_next = {b_line[W-IN_W-1:0], b_flat[gi*IN_W +: IN_W]};
                end

                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        a_line <= '0;
                        b_line <= '0;
                    end else if (flush) begin
                        a_line <= '0;
                        b_line <= '0;
                    end else if (en) begin
                        a_line <= a_next;
                        b_line <= b_next;
                    end
                end

                assign a_skew[gi*IN_W +: IN_W] = a_line[W-1 -: IN_W];
                assign b_skew[gi*IN_W +: IN_W] = b_line[W-1 -: IN_W];
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // PE grid
    // -------------------------------------------------------------------------
    generate
        for (gr = 0; gr < N; gr++) begin : g_west_edge
            assign a_h[(gr*(N+1))*IN_W +: IN_W] = a_skew[gr*IN_W +: IN_W];
        end
        for (gc = 0; gc < N; gc++) begin : g_north_edge
            assign b_v[gc*IN_W +: IN_W] = b_skew[gc*IN_W +: IN_W];
        end

        for (gr = 0; gr < N; gr++) begin : g_row
            for (gc = 0; gc < N; gc++) begin : g_col
                pe_mac #(
                    .IN_W  (IN_W),
                    .ACC_W (ACC_W)
                ) u_pe (
                    .clk     (clk),
                    .rst_n   (rst_n),
                    .en      (en),
                    .clr_acc (clr_acc),
                    .flush   (flush),
                    .act_in  (a_h[(gr*(N+1) + gc    )*IN_W +: IN_W]),
                    .wt_in   (b_v[(gr*N     + gc    )*IN_W +: IN_W]),
                    .act_out (a_h[(gr*(N+1) + gc + 1)*IN_W +: IN_W]),
                    .wt_out  (b_v[((gr+1)*N + gc    )*IN_W +: IN_W]),
                    .acc_out (acc_flat[(gr*N + gc)*ACC_W +: ACC_W])
                );
            end
        end
    endgenerate

    // The east-most operand outputs and the bottom row of b_v are legitimately
    // unconsumed (they are where a larger, tiled array would chain onward).
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_edges = ^{a_h, b_v};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
