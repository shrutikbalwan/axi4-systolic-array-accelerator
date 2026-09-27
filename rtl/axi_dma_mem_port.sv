// -----------------------------------------------------------------------------
// axi_dma_mem_port.sv - direct burst port from the accelerator DMA into RAM.
//
// Connects tiled_axi4_gemm_top's three AXI4 masters (A read, B read, C write)
// to ONE port of a synchronous single-cycle RAM (typically the second port of
// a true-dual-port main RAM whose other port serves the CPU). This is the
// "accelerator gets its own port to memory" arrangement of SoC FPGAs' high-
// performance AXI ports: DMA traffic no longer crosses the CPU interconnect.
//
//   * INCR bursts stream at one beat per cycle (reads are pipelined through a
//     two-entry skid buffer, so RREADY back-pressure never loses data).
//   * A and B reads are arbitrated round-robin per burst; reads and writes are
//     mutually exclusive per burst (the engine never overlaps them anyway).
//   * Addresses outside [BASE, BASE + 4*DEPTH) get SLVERR and never touch RAM,
//     so a bad descriptor surfaces as a DMA error instead of corrupting memory.
//   * Only 32-bit INCR beats are supported (all the DMA engines issue);
//     anything else is answered with SLVERR.
//
// RAM port contract: mem_addr/mem_we/mem_wdata are sampled on the clock edge;
// mem_rdata is the word at the previous cycle's mem_addr (1-cycle latency).
// -----------------------------------------------------------------------------
`default_nettype none

module axi_dma_mem_port #(
    parameter int          ADDR_W = 32,
    parameter logic [31:0] BASE   = 32'h4000_0000,
    parameter int          DEPTH  = 65536            // RAM depth in 32-bit words
) (
    input  wire              clk,
    input  wire              rst_n,

    // A read master
    input  wire [ADDR_W-1:0] a_araddr,  input  wire [7:0] a_arlen,
    input  wire [2:0]        a_arsize,  input  wire [1:0] a_arburst,
    input  wire              a_arvalid, output logic      a_arready,
    output logic [31:0]      a_rdata,   output logic [1:0] a_rresp,
    output logic             a_rlast,   output logic      a_rvalid,
    input  wire              a_rready,
    // B read master
    input  wire [ADDR_W-1:0] b_araddr,  input  wire [7:0] b_arlen,
    input  wire [2:0]        b_arsize,  input  wire [1:0] b_arburst,
    input  wire              b_arvalid, output logic      b_arready,
    output logic [31:0]      b_rdata,   output logic [1:0] b_rresp,
    output logic             b_rlast,   output logic      b_rvalid,
    input  wire              b_rready,
    // C write master
    input  wire [ADDR_W-1:0] c_awaddr,  input  wire [7:0] c_awlen,
    input  wire [2:0]        c_awsize,  input  wire [1:0] c_awburst,
    input  wire              c_awvalid, output logic      c_awready,
    input  wire [31:0]       c_wdata,   input  wire [3:0] c_wstrb,
    input  wire              c_wlast,   input  wire       c_wvalid,
    output logic             c_wready,
    output logic [1:0]       c_bresp,   output logic      c_bvalid,
    input  wire              c_bready,

    // Synchronous RAM port
    output logic [$clog2(DEPTH)-1:0] mem_addr,
    output logic [3:0]               mem_we,
    output logic [31:0]              mem_wdata,
    input  wire  [31:0]              mem_rdata
);

    localparam int AW = $clog2(DEPTH);
    localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10;

    // Burst [addr, addr + 4*(len+1)) must lie inside the RAM window and be
    // word aligned. Computed with one extra bit so the end cannot wrap.
    localparam logic [ADDR_W:0] WIN_LO = (ADDR_W+1)'(BASE);
    localparam logic [ADDR_W:0] WIN_HI = (ADDR_W+1)'(BASE) + (ADDR_W+1)'(DEPTH) * 4;

    // ------------------------------------------------------------ read side
    typedef enum logic [1:0] {R_IDLE, R_BURST, R_ERROR} rstate_t;
    rstate_t rstate;
    logic        rsel_b;          // 0: A owns the read burst, 1: B
    logic        rr_prefer_b;     // round-robin pointer
    logic [AW-1:0] r_word;        // next word to issue
    logic [8:0]  r_issue_left;    // beats still to issue
    logic [8:0]  r_pop_left;      // beats still to hand to the master
    logic        r_pending;       // a RAM read issued last cycle
    logic        r_pending_last;
    // two-entry skid FIFO (data + last)
    logic [31:0] f_data [2];
    logic        f_last [2];
    logic [1:0]  f_count;
    logic        f_head;

    wire         sel_rready  = rsel_b ? b_rready : a_rready;
    wire         out_valid   = (rstate == R_BURST) && (f_count != 0);
    wire         out_pop     = out_valid && sel_rready;
    wire         err_valid   = (rstate == R_ERROR);
    wire         err_pop     = err_valid && sel_rready;

    // ----------------------------------------------------------- write side
    typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
    wstate_t wstate;
    logic [AW-1:0] w_word;
    logic [8:0]  w_left;
    logic        w_err;

    // Read/write exclusivity at burst granularity.
    wire read_busy  = (rstate != R_IDLE);
    wire write_busy = (wstate != W_IDLE);
    wire pick_a = a_arvalid && (!b_arvalid || !rr_prefer_b);
    wire pick_b = b_arvalid && !pick_a;
    wire start_read  = (rstate == R_IDLE) && !write_busy && (a_arvalid || b_arvalid);
    wire start_write = (wstate == W_IDLE) && !read_busy && !start_read && c_awvalid;

    wire [ADDR_W-1:0] ar_addr  = pick_b ? b_araddr  : a_araddr;
    wire [7:0]        ar_len   = pick_b ? b_arlen   : a_arlen;
    wire [2:0]        ar_size  = pick_b ? b_arsize  : a_arsize;
    wire [1:0]        ar_burst = pick_b ? b_arburst : a_arburst;
    wire [ADDR_W:0] ar_first = {1'b0, ar_addr};
    wire [ADDR_W:0] ar_last  = {1'b0, ar_addr} + ({{(ADDR_W-7){1'b0}}, ar_len} << 2) + 3;
    wire [ADDR_W:0] aw_first = {1'b0, c_awaddr};
    wire [ADDR_W:0] aw_last  = {1'b0, c_awaddr} + ({{(ADDR_W-7){1'b0}}, c_awlen} << 2) + 3;
    wire ar_ok = (ar_first >= WIN_LO) && (ar_last < WIN_HI) && (ar_addr[1:0] == 2'b00) &&
                 (ar_size == 3'd2) && (ar_burst == 2'b01);
    wire aw_ok = (aw_first >= WIN_LO) && (aw_last < WIN_HI) && (c_awaddr[1:0] == 2'b00) &&
                 (c_awsize == 3'd2) && (c_awburst == 2'b01);

    // Issue a RAM read when the skid FIFO can still absorb it.
    wire [2:0] f_occupancy = {1'b0, f_count} + {2'b00, r_pending} - {2'b00, out_pop};
    wire r_issue = (rstate == R_BURST) && (r_issue_left != 0) && (f_occupancy < 3'd2);

    // Skid FIFO next state: pop at the head, push (last cycle's RAM read) at the tail.
    wire       f_head_after_pop = out_pop ? ~f_head : f_head;
    wire [1:0] f_count_after_pop = f_count - {1'b0, out_pop};
    wire       f_push_slot = f_head_after_pop ^ f_count_after_pop[0];
    wire w_fire  = (wstate == W_DATA) && c_wvalid;   // c_wready is 1 in W_DATA

    // ------------------------------------------------------------ RAM port
    always_comb begin
        mem_addr  = r_word;
        mem_we    = 4'b0000;
        mem_wdata = c_wdata;
        if (wstate == W_DATA) begin
            mem_addr = w_word;
            if (w_fire && !w_err) mem_we = c_wstrb;
        end
    end

    // ------------------------------------------------------- master outputs
    always_comb begin
        a_arready = start_read && pick_a;
        b_arready = start_read && pick_b;
        a_rvalid = 1'b0; b_rvalid = 1'b0;
        a_rdata  = f_data[f_head]; b_rdata = f_data[f_head];
        a_rlast  = 1'b0; b_rlast = 1'b0;
        a_rresp  = OKAY; b_rresp = OKAY;
        if (out_valid || err_valid) begin
            if (rsel_b) begin
                b_rvalid = 1'b1;
                b_rlast  = err_valid ? (r_pop_left == 1) : f_last[f_head];
                b_rresp  = err_valid ? SLVERR : OKAY;
            end else begin
                a_rvalid = 1'b1;
                a_rlast  = err_valid ? (r_pop_left == 1) : f_last[f_head];
                a_rresp  = err_valid ? SLVERR : OKAY;
            end
        end
        c_awready = start_write;
        c_wready  = (wstate == W_DATA);
        c_bvalid  = (wstate == W_RESP);
        c_bresp   = w_err ? SLVERR : OKAY;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate <= R_IDLE; rsel_b <= 1'b0; rr_prefer_b <= 1'b0;
            r_word <= '0; r_issue_left <= '0; r_pop_left <= '0;
            r_pending <= 1'b0; r_pending_last <= 1'b0;
            f_count <= '0; f_head <= 1'b0;
            f_data[0] <= '0; f_data[1] <= '0; f_last[0] <= 1'b0; f_last[1] <= 1'b0;
            wstate <= W_IDLE; w_word <= '0; w_left <= '0; w_err <= 1'b0;
        end else begin
            // ---------------- read engine
            r_pending <= r_issue;
            r_pending_last <= r_issue && (r_issue_left == 1);
            if (r_issue) begin
                r_word <= r_word + 1'b1;
                r_issue_left <= r_issue_left - 1'b1;
            end
            // FIFO push (data from last cycle's issue) and pop.
            if (r_pending) begin
                f_data[f_push_slot] <= mem_rdata;
                f_last[f_push_slot] <= r_pending_last;
            end
            f_count <= f_count_after_pop + {1'b0, r_pending};
            f_head  <= f_head_after_pop;

            case (rstate)
                R_IDLE: if (start_read) begin
                    rsel_b      <= pick_b;
                    rr_prefer_b <= !pick_b;
                    r_word      <= AW'((ar_addr - BASE) >> 2);
                    r_issue_left <= {1'b0, ar_len} + 9'd1;
                    r_pop_left  <= {1'b0, ar_len} + 9'd1;
                    if (ar_ok) rstate <= R_BURST;
                    else       rstate <= R_ERROR;
                end
                R_BURST: if (out_pop) begin
                    r_pop_left <= r_pop_left - 1'b1;
                    if (r_pop_left == 1) rstate <= R_IDLE;
                end
                R_ERROR: if (err_pop) begin
                    r_pop_left <= r_pop_left - 1'b1;
                    if (r_pop_left == 1) rstate <= R_IDLE;
                end
                default: rstate <= R_IDLE;
            endcase

            // ---------------- write engine
            case (wstate)
                W_IDLE: if (start_write) begin
                    w_word <= AW'((c_awaddr - BASE) >> 2);
                    w_left <= {1'b0, c_awlen} + 9'd1;
                    w_err  <= !aw_ok;
                    wstate <= W_DATA;
                end
                W_DATA: if (w_fire) begin
                    w_word <= w_word + 1'b1;
                    w_left <= w_left - 1'b1;
                    if (c_wlast || (w_left == 1)) begin
                        // A WLAST that disagrees with AWLEN is a protocol error.
                        if (c_wlast != (w_left == 1)) w_err <= 1'b1;
                        wstate <= W_RESP;
                    end
                end
                W_RESP: if (c_bready) wstate <= W_IDLE;
                default: wstate <= W_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
