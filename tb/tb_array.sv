// -----------------------------------------------------------------------------
// tb_array.sv - self-checking Verilator regression for systolic_array alone.
//
// Build/run: see scripts/run_checks.sh (Verilator --binary --timing, -GN/-GK).
// (A comment line must not START with the tool's name: it is parsed as a pragma.)
//
// Checks, per configuration:
//   * 4 corner cases (all -128 / all +127 combinations: worst-case accumulation)
//   * 200 random signed-INT8 matrices, element-by-element against a reference
//   * a back-to-back pair proving clr_acc isolates run k+1 from run k
//   * that the cycle at which results become correct equals K + 2N - 1
// Note: 'matches' and 'gen' are reserved words in SystemVerilog; avoid them.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_array;
    parameter int N = 4;
    parameter int K = 4;
    localparam int IN_W = 8;
    localparam int ACC_W = 32;
    localparam int N_RANDOM = 200;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic en = 1'b0;
    logic clr_acc = 1'b0;
    logic flush = 1'b0;
    logic [N*IN_W-1:0]    a_flat = '0;
    logic [N*IN_W-1:0]    b_flat = '0;
    wire  [N*N*ACC_W-1:0] acc_flat;

    always #5 clk = ~clk;

    systolic_array #(.N(N), .IN_W(IN_W), .ACC_W(ACC_W)) dut (
        .clk(clk), .rst_n(rst_n), .en(en), .clr_acc(clr_acc), .flush(flush),
        .a_flat(a_flat), .b_flat(b_flat), .acc_flat(acc_flat)
    );

    int a_m [N][K];
    int b_m [K][N];
    int c_ref [N][N];
    int errors = 0;
    int checks = 0;
    int worst_settle = -1;

    function automatic int unpack_acc(int r, int c);
        return $signed(acc_flat[(r*N + c)*ACC_W +: ACC_W]);
    endfunction

    function automatic bit acc_ok();
        for (int r = 0; r < N; r++)
            for (int c = 0; c < N; c++)
                if (unpack_acc(r, c) != c_ref[r][c]) return 1'b0;
        return 1'b1;
    endfunction

    // corner: 0 = random; otherwise mode bit0/bit1 pick -128 or +127 for A/B
    task automatic mk_vec(input bit corner, input int mode);
        for (int r = 0; r < N; r++)
            for (int k = 0; k < K; k++)
                a_m[r][k] = corner ? (mode[0] ? -128 : 127) : (int'($urandom_range(255)) - 128);
        for (int k = 0; k < K; k++)
            for (int c = 0; c < N; c++)
                b_m[k][c] = corner ? (mode[1] ? -128 : 127) : (int'($urandom_range(255)) - 128);
        for (int r = 0; r < N; r++)
            for (int c = 0; c < N; c++) begin
                c_ref[r][c] = 0;
                for (int k = 0; k < K; k++) c_ref[r][c] += a_m[r][k] * b_m[k][c];
            end
    endtask

    // Returns the first feed-relative cycle at which every C element is correct.
    task automatic run_gemm(output int settle);
        int cyc;
        settle = -1;
        en = 1'b0; clr_acc = 1'b1; flush = 1'b1;
        @(posedge clk); #1;
        clr_acc = 1'b0; flush = 1'b0; en = 1'b1;
        cyc = 0;
        for (int k = 0; k < K; k++) begin
            for (int r = 0; r < N; r++) a_flat[r*IN_W +: IN_W] = a_m[r][k][IN_W-1:0];
            for (int c = 0; c < N; c++) b_flat[c*IN_W +: IN_W] = b_m[k][c][IN_W-1:0];
            @(posedge clk); #1; cyc++;
            if (settle < 0 && acc_ok()) settle = cyc;
        end
        a_flat = '0; b_flat = '0;
        for (int d = 0; d < 4*N + 8; d++) begin
            @(posedge clk); #1; cyc++;
            if (settle < 0 && acc_ok()) settle = cyc;
        end
        en = 1'b0;
    endtask

    task automatic check(input string what);
        int s;
        run_gemm(s);
        checks++;
        if (!acc_ok()) begin
            errors++;
            $display("FAIL %s", what);
            for (int r = 0; r < N; r++)
                for (int c = 0; c < N; c++)
                    if (unpack_acc(r, c) != c_ref[r][c])
                        $display("  C[%0d][%0d] got %0d want %0d", r, c, unpack_acc(r, c), c_ref[r][c]);
        end else if (s != K + 2*N - 1) begin
            // Settling earlier than predicted would mean the schedule is not
            // what we think; later means results arrive too late for the FSM.
            // (Earlier is possible by coincidence only for degenerate data.)
            if (s > K + 2*N - 1) begin
                errors++;
                $display("FAIL %s: settled at %0d, predicted %0d", what, s, K + 2*N - 1);
            end
        end
        if (s > worst_settle) worst_settle = s;
    endtask

    initial begin
        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        @(posedge clk); #1;

        for (int m = 0; m < 4; m++) begin
            mk_vec(1'b1, m);
            check($sformatf("corner mode %0d", m));
        end

        for (int t = 0; t < N_RANDOM; t++) begin
            mk_vec(1'b0, 0);
            check($sformatf("random trial %0d", t));
        end

        // Back-to-back: the second run must not see the first run's sums.
        mk_vec(1'b0, 0); check("back-to-back run 1");
        mk_vec(1'b0, 0); check("back-to-back run 2");

        $display("====================================================");
        $display("tb_array N=%0d K=%0d  runs=%0d  errors=%0d", N, K, checks, errors);
        $display("results first correct at feed-relative cycle %0d", worst_settle);
        $display("predicted K + 2N - 1 = %0d", K + 2*N - 1);
        $display("%s", (errors == 0 && worst_settle == K + 2*N - 1) ? "PASS" : "FAIL");
        $display("====================================================");
        $finish;
    end
endmodule

`default_nettype wire
