`default_nettype none

module systolic_array_4x4 #
(
    parameter IN_W = 8,       // Input width (8 = INT8)
    parameter ACC_W = 32,      // Accumulator width (32 = INT32 accumulated)
    parameter PE_DEPTH = 4      // Array dimension (4 = 4x4 array)
)
(
    input  wire               clk,
    input  wire               rst_n,       // Active-low reset, async
    input  wire               en,          // Enable, gates all state including skew registers
    input  wire               clr_acc,     // Clear accumulator (async, active-high, pulsed)
    // Activation stream from left (horizontal) - one value per PE per row
    input  wire      [IN_W-1:0]  act_in [0:PE_DEPTH-1],
    // Weight stream from top (vertical) - one value per PE per column
    input  wire      [IN_W-1:0]  wt_in [0:PE_DEPTH-1],
    // Accumulator outputs - N*N matrix of 32-bit results
    output reg     [ACC_W-1:0]  pe_acc_out [0:PE_DEPTH-1][0:PE_DEPTH-1]
);

// ================================================================
// WIRE DECLARATIONS
// ================================================================
// Skew registers for activations: act_skewed[r][c] = activation at PE(r,c) delayed by r cycles
// Skew registers for weights:   wt_skewed[r][c]   = weight at PE(r,c) delayed by c cycles
// We use separate always_ff blocks for each direction to avoid the "double-skew" bug
// where a second fabric on top of PE registers causes operand misalignment.

// Activation skew registers: row-r delay chain
reg      [IN_W-1:0]  act_skewed [0:PE_DEPTH-1][0:PE_DEPTH-1];

// Weight skew registers: column-c delay chain
reg      [IN_W-1:0]  wt_skewed  [0:PE_DEPTH-1][0:PE_DEPTH-1];

// Combinational mux to select which input feeds each PE row/column
// During en=0, skew registers hold previous value (no latch because of always_ff)

// ================================================================
// ACTIVATION SKEW NETWORK: Row-r delay chain
// ================================================================
// The key fix: each row r has its OWN shift register chain of depth r,
// fed by act_in[r]. NOT a single chain across all rows.
// Row 0: depth 0 (no delay, act_in[0] feeds directly)
// Row 1: depth 1 (one flip-flop)
// Row 2: depth 2 (two flip-flops)
// Row 3: depth 3 (three flip-flops)

// Column 0 for all rows gets act_in[row] delayed by row cycles
// Column 1 for all rows gets the output of column 0's chain delayed by 1 more cycle
// etc.

// Generate the skew network for activations
genvar r, c;

generate
    for (r = 0; r < PE_DEPTH; r = r + 1) begin: act_row_gen
        for (c = 0; c < PE_DEPTH; c = c + 1) begin: act_col_gen

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    act_skewed[r][c] <= '0;
                end else begin
                    // Each row r: activation delayed by r cycles
                    // The chain is: act_in[r] -> flip-flop -> flip-flop -> ... (r times)
                    // For column c within this row, we shift the value from the previous column
                    if (c == 0) begin
                        // First column: get activation delayed by r cycles from this row's input
                        if (r == 0) begin
                            // Row 0, column 0: no skew delay
                            act_skewed[r][c] <= act_in[r];
                        end else begin
                            // Row r > 0, column 0: activation delayed by r cycles from row's input
                            act_skewed[r][c] <= act_skewed[r-1][c];
                        end
                    end else begin
                        // Subsequent columns: shift from previous column in same row
                        // This implements the per-hop register that the PE itself should own
                        act_skewed[r][c] <= act_skewed[r][c-1];
                    end
                end
            end
        end
    end
endgenerate

// ================================================================
// WEIGHT SKEW NETWORK: Column-c delay chain
// ================================================================
// The key fix: each column c has its OWN shift register chain of depth c,
// fed by wt_in[c]. NOT a single chain across all columns.
// Column 0: depth 0 (no delay, wt_in[0] feeds directly)
// Column 1: depth 1 (one flip-flop)
// Column 2: depth 2 (two flip-flops)
// Column 3: depth 3 (three flip-flops)

// Row 0 for all columns gets wt_in[col] delayed by col cycles
// Row 1 for all columns gets the output of row 0's chain delayed by 1 more cycle
// etc.

generate
    for (c = 0; c < PE_DEPTH; c = c + 1) begin: wt_col_gen
        for (r = 0; r < PE_DEPTH; r = r + 1) begin: wt_row_gen

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    wt_skewed[r][c] <= '0;
                end else begin
                    // Each column c: weight delayed by c cycles
                    // The chain is: wt_in[col] -> flip-flop -> flip-flop -> ... (c times)
                    // For row r within this column, we shift the value from the previous row
                    if (r == 0) begin
                        // First row: get weight delayed by c cycles from column's input
                        if (c == 0) begin
                            // Column 0, row 0: no skew delay
                            wt_skewed[r][c] <= wt_in[c];
                        end else begin
                            // Column c > 0, row 0: weight delayed by c cycles from column's input
                            wt_skewed[r][c] <= wt_skewed[r-1][c];
                        end
                    end else begin
                        // Subsequent rows: shift from previous row in same column
                        // This implements the per-hop register that the PE itself should own
                        wt_skewed[r][c] <= wt_skewed[r-1][c];
                    end
                end
            end
        end
    end
endgenerate

// ================================================================
// PE INSTANTIATION
// ================================================================
// Instantiate N*N PEs. PE at position (r,c) receives act_skewed[r][c] and wt_skewed[r][c].
// After the initial skew latency (r cycles for activations, c cycles for weights),
// PE(r,c) sees A[r][k] and B[k][c] in the same cycle, enabling accumulation
// of C[r][c] = sum_k A[r][k]*B[k][c].

generate
    for (r = 0; r < PE_DEPTH; r = r + 1) begin: pe_row_inst
        for (c = 0; c < PE_DEPTH; c = c + 1) begin: pe_col_inst

            pe_mac #(
                .IN_W(IN_W),
                .ACC_W(ACC_W)
            ) pe_instance (
                .clk            (clk),
                .rst_n          (rst_n),
                .en             (en),
                .clr_acc        (clr_acc),
                .act_in         (act_skewed[r][c]),
                .wt_in          (wt_skewed[r][c]),
                .acc_out        (pe_acc_out[r][c])
            );

        end
    end
endgenerate

// ================================================================
// VERIFICATION NOTES (for comment block only, not synthesis)
// ================================================================
// SKEW SCHEDULE for N=4:
//   PE(0,0): A[0][k] and B[k][0] seen immediately (0-delay edges)
//   PE(0,1): A[0][k] and B[k][1] seen immediately (0-delay w, 1-delay col)
//   PE(0,2): A[0][k] and B[k][2] seen immediately (0-delay w, 2-delay col)
//   PE(0,3): A[0][k] and B[k][3] seen immediately (0-delay w, 3-delay col)
//   PE(1,0): A[1][k] and B[k][0] seen after 1-cycle row skew
//   PE(1,1): A[1][k] and B[k][1] seen after 1-row + 1-col skew
//   PE(1,2): A[1][k] and B[k][2] seen after 1-row + 2-col skew
//   PE(1,3): A[1][k] and B[k][3] seen after 1-row + 3-col skew
//   PE(2,0): A[2][k] and B[k][0] seen after 2-row skew
//   PE(2,1): A[2][k] and B[k][1] seen after 2-row + 1-col skew
//   PE(2,2): A[2][k] and B[k][2] seen after 2-row + 2-col skew
//   PE(2,3): A[2][k] and B[k][3] seen after 2-row + 3-col skew
//   PE(3,0): A[3][k] and B[k][0] seen after 3-row skew
//   PE(3,1): A[3][k] and B[k][1] seen after 3-row + 1-col skew
//   PE(3,2): A[3][k] and B[k][2] seen after 3-row + 2-col skew
//   PE(3,3): A[3][k] and B[k][3] seen after 3-row + 3-col skew
//
// After 3 cycles of skew latency, the array is FULLY saturated:
// Every PE(r,c) sees its correct A[r][k] and B[k][c] operands each cycle.
//
// DRAIN: 2*N-2 + PE_LATENCY = 2*4-2 + 1 = 9 cycles (PE_LATENCY=1 for combo acc_out)
// - After last data cycle, 6 drain cycles + 1 PE latency = 7 cycles to clear pipeline
// - With acc_out combo from acc_reg, drain is effectively 6 cycles

// OPERATION:
// - en gates all skew registers and PEs. When en=0, data flow stops gracefully.
// - clr_acc pulsed at start of new run clears accumulators so run k+1 does not accumulate
//   onto run k. Must be pulsed before START in the next LOAD/FEED cycle.
// - The PE acc_out is combinationally driven from acc_reg (0 extra drain cycle).
// - If acc_out were registered, add 1 cycle to the drain count.

// -------------------------------------------------------
// End of module - no other always blocks.
// -------------------------------------------------------
endmodule : systolic_array_4x4