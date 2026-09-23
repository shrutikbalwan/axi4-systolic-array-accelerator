// -----------------------------------------------------------------------------
// tile_scheduler.sv - arbitrary-size GEMM tile sequencer.
//
// The scheduler does not own memories or the systolic array. It presents one
// tile at a time, waits for tile_done, and walks K first so partial sums for an
// M/N output tile can be accumulated across multiple K tiles.
//
// Tile coordinates are element offsets. Lengths are clipped at matrix edges,
// which lets a DMA/buffer adapter zero-pad the edge tile without special cases
// in the array. A tile is accepted when tile_valid && tile_ready.
// -----------------------------------------------------------------------------
`default_nettype none

module tile_scheduler #(
    parameter int TILE_M = 4,
    parameter int TILE_N = 4,
    parameter int TILE_K = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [31:0] matrix_m,
    input  wire [31:0] matrix_n,
    input  wire [31:0] matrix_k,
    input  wire [31:0] tile_m_cfg,
    input  wire [31:0] tile_n_cfg,
    input  wire [31:0] tile_k_cfg,
    output logic       busy,
    output logic       error,
    output logic       tile_valid,
    input  wire        tile_ready,
    input  wire        tile_done,
    output logic [31:0] tile_m_base,
    output logic [31:0] tile_n_base,
    output logic [31:0] tile_k_base,
    output logic [31:0] tile_m_len,
    output logic [31:0] tile_n_len,
    output logic [31:0] tile_k_len,
    output logic        tile_first_k,
    output logic        tile_last_k,
    output logic        done
);

    logic [31:0] m_q, n_q, k_q;
    logic [31:0] m_dim_q, n_dim_q, k_dim_q;
    logic [31:0] tm_q, tn_q, tk_q;
    logic        in_flight;

    always_comb begin
        busy       = (m_dim_q != 0) && (n_dim_q != 0) && (k_dim_q != 0);
        tile_valid = busy && !in_flight;

        tile_m_base = m_q;
        tile_n_base = n_q;
        tile_k_base = k_q;
        tile_m_len  = ((m_dim_q - m_q) < tm_q) ? (m_dim_q - m_q) : tm_q;
        tile_n_len  = ((n_dim_q - n_q) < tn_q) ? (n_dim_q - n_q) : tn_q;
        tile_k_len  = ((k_dim_q - k_q) < tk_q) ? (k_dim_q - k_q) : tk_q;
        tile_first_k = (k_q == 0);
        tile_last_k  = (k_q + tile_k_len >= k_dim_q);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_q        <= 0;
            n_q        <= 0;
            k_q        <= 0;
            m_dim_q    <= 0;
            n_dim_q    <= 0;
            k_dim_q    <= 0;
            tm_q       <= 0;
            tn_q       <= 0;
            tk_q       <= 0;
            in_flight  <= 1'b0;
            done       <= 1'b0;
            error      <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                if ((matrix_m == 0) || (matrix_n == 0) || (matrix_k == 0) ||
                    (tile_m_cfg == 0) || (tile_n_cfg == 0) || (tile_k_cfg == 0)) begin
                    error <= 1'b1;
                end else begin
                    m_dim_q   <= matrix_m;
                    n_dim_q   <= matrix_n;
                    k_dim_q   <= matrix_k;
                    tm_q      <= tile_m_cfg;
                    tn_q      <= tile_n_cfg;
                    tk_q      <= tile_k_cfg;
                    m_q       <= 0;
                    n_q       <= 0;
                    k_q       <= 0;
                    in_flight <= 1'b0;
                    error     <= 1'b0;
                end
            end else if (tile_valid && tile_ready) begin
                in_flight <= 1'b1;
            end else if (in_flight && tile_done) begin
                in_flight <= 1'b0;
                if (tile_last_k) begin
                    k_q <= 0;
                    if (n_q + tile_n_len >= n_dim_q) begin
                        n_q <= 0;
                        if (m_q + tile_m_len >= m_dim_q) begin
                            m_q       <= 0;
                            m_dim_q   <= 0;
                            n_dim_q   <= 0;
                            k_dim_q   <= 0;
                            done      <= 1'b1;
                        end else begin
                            m_q <= m_q + tile_m_len;
                        end
                    end else begin
                        n_q <= n_q + tile_n_len;
                    end
                end else begin
                    k_q <= k_q + tile_k_len;
                end
            end
        end
    end

endmodule

`default_nettype wire
