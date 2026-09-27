#!/usr/bin/env python3
"""Seed known defects into a copy of rtl/ and check the regression catches them.

    python3 scripts/mutants.py list
    python3 scripts/mutants.py make <ID> <out_dir>    # writes <out_dir>/rtl/*.sv

Each mutant is a list of exact (file, old, new) replacements; every `old` must
occur exactly once, so a mutant can never silently become a no-op when the RTL
is edited. scripts/run_mutants.sh runs the regression against each one.
"""

import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

MUTANTS = {
    "M01": ("drain one cycle short (2N-2 instead of 2N-1)", [
        ("accel_ctrl.sv", "DRAIN_CYCLES = 2*N - 2 + PE_LATENCY;",
                          "DRAIN_CYCLES = 2*N - 3 + PE_LATENCY;")]),
    "M02": ("BVALID gated on BREADY (original deadlock)", [
        ("axi_lite_slave.sv", "end else if (do_write) begin\n            s_axi_bvalid <= 1'b1;",
                              "end else if (do_write && s_axi_bready) begin\n            s_axi_bvalid <= 1'b1;")]),
    "M03": ("RVALID gated on RREADY", [
        ("axi_lite_slave.sv", "end else if (do_read) begin",
                              "end else if (do_read && s_axi_rready) begin")]),
    "M04": ("RDATA muxed from live ARADDR (not captured at handshake)", [
        ("axi_lite_slave.sv", "            s_axi_rdata  <= '0;\n", ""),
        ("axi_lite_slave.sv", "            s_axi_rdata  <= reg_rd_data;\n", ""),
        ("axi_lite_slave.sv", "    assign reg_rd_addr   = s_axi_araddr;",
                              "    assign reg_rd_addr   = s_axi_araddr;\n    assign s_axi_rdata   = reg_rd_data;")]),
    "M05": ("every row fed from row 0 (original root bug)", [
        ("systolic_array.sv", "assign a_next = a_flat[gi*IN_W +: IN_W];",
                              "assign a_next = a_flat[0 +: IN_W];"),
        ("systolic_array.sv", "assign a_next = {a_line[W-IN_W-1:0], a_flat[gi*IN_W +: IN_W]};",
                              "assign a_next = {a_line[W-IN_W-1:0], a_flat[0 +: IN_W]};")]),
    "M06": ("WSTRB ignored on operand buffers", [
        ("accel_ctrl.sv", "if (reg_wr_strb[i]) a_mem", "a_mem"),
        ("accel_ctrl.sv", "if (reg_wr_strb[i]) b_mem", "b_mem")]),
    "M07": ("START while BUSY not flagged", [
        ("accel_ctrl.sv", "if (busy && (req_start || req_clr_acc)) err <= 1'b1;",
                          "if (1'b0) err <= 1'b1;")]),
    "M08": ("accumulators not cleared between runs", [
        ("accel_ctrl.sv", "assign arr_clr_acc = (state == S_CLEAR) ||",
                          "assign arr_clr_acc = 1'b0 ||")]),
    "M09": ("DONE not sticky (self-clears after one cycle)", [
        ("accel_ctrl.sv", "if (status_lane && reg_wr_data[1]) done <= 1'b0;",
                          "if (done) done <= 1'b0;")]),
    "M10": ("operand pipeline never flushed", [
        ("accel_ctrl.sv", "assign arr_flush   = (state == S_CLEAR) || req_soft_rst;",
                          "assign arr_flush   = 1'b0;")]),
    "M11": ("product zero-extended instead of sign-extended", [
        ("pe_mac.sv", "prod_ext = ACC_W'(prod);", "prod_ext = ACC_W'($unsigned(prod));")]),
    "M12": ("west skew one stage too deep", [
        ("systolic_array.sv", "assign a_skew[gi*IN_W +: IN_W] = a_line[W-1 -: IN_W];",
                              "assign a_skew[gi*IN_W +: IN_W] = (gi == N-1) ? '0 : a_line[W-1 -: IN_W];")]),
    "M13": ("LEN writable while BUSY", [
        ("accel_ctrl.sv", "if (busy) reg_wr_resp = RESP_SLVERR;   // LEN is locked during a run\n                    else      we_len      = reg_wr_en;",
                          "we_len      = reg_wr_en;")]),
    "M14": ("unmapped register reads return OKAY", [
        ("accel_ctrl.sv", "else                          reg_rd_resp = RESP_DECERR;",
                          "else                          reg_rd_resp = RESP_OKAY;")]),
    "M15": ("LEN not validated on START", [
        ("accel_ctrl.sv", "wire len_valid    = (len != 16'd0) && (len <= 16'(KMAX));",
                          "wire len_valid    = 1'b1;")]),
    "M16": ("irq ignores IRQ_EN", [
        ("accel_ctrl.sv", "assign irq = done && irq_en;", "assign irq = done;")]),
    "M17": ("any STATUS write clears DONE (not W1C)", [
        ("accel_ctrl.sv", "if (status_lane && reg_wr_data[1]) done <= 1'b0;",
                          "if (status_lane) done <= 1'b0;")]),
    "M18": ("feed pointer advances one word per vector regardless of N", [
        ("accel_ctrl.sv", "feed_base <= feed_base + BUF_IDX_W'(WPR);",
                          "feed_base <= feed_base + BUF_IDX_W'(1);")]),
    "M19": ("write response taken before AW arrives (W-only write)", [
        ("axi_lite_slave.sv", "assign do_write      = aw_full && w_full && !s_axi_bvalid;",
                              "assign do_write      = w_full && !s_axi_bvalid;")]),
    "M20": ("soft reset leaves DONE set", [
        ("accel_ctrl.sv", "                state <= S_IDLE;\n                done  <= 1'b0;\n                err   <= 1'b0;",
                          "                state <= S_IDLE;\n                err   <= 1'b0;")]),
    "M21": ("INT8 packer truncates the scaled product before clamping", [
        ("ml_int8_packer.sv", "wire signed [63:0] shifted_value",
                               "wire signed [31:0] shifted_value")]),
    "M22": ("ML post-process truncates the scaled product before clamping", [
        ("ml_postprocess.sv", "logic signed [(2*ACC_W)-1:0] shifted",
                               "logic signed [ACC_W-1:0] shifted")]),
    "M23": ("read DMA omits the AXI 4KB page clamp", [
        ("axi4_read_dma.sv",
         "        if (burst_limit_wide > {21'b0, beats_to_page_end})\n"
         "            burst_limit_wide = {21'b0, beats_to_page_end};\n",
         "        // Mutant: omit the AXI 4KB page clamp.\n")]),
    "M24": ("write DMA omits the AXI 4KB page clamp", [
        ("axi4_write_dma.sv",
         "        if (burst_limit_wide > {21'b0, beats_to_page_end})\n"
         "            burst_limit_wide = {21'b0, beats_to_page_end};\n",
         "        // Mutant: omit the AXI 4KB page clamp.\n")]),
    "M25": ("read DMA descriptor length is one word too long", [
        ("axi4_read_dma.sv", "remaining_q <= word_count;",
                             "remaining_q <= word_count + 1'b1;")]),
    "M26": ("write DMA descriptor length is one word too long", [
        ("axi4_write_dma.sv", "remaining_q <= word_count;",
                              "remaining_q <= word_count + 1'b1;")]),
    "M27": ("scheduler advances K one element too far", [
        ("tile_scheduler.sv", "k_q <= k_q + tile_k_len;",
                              "k_q <= k_q + tile_k_len + 1'b1;")]),
    "M28": ("tile accumulator ignores first-K reset", [
        ("tile_accumulator.sv", "prior_value = first_q ? '0 : acc_mem[in_count];",
                                "prior_value = acc_mem[in_count];")]),
    "M29": ("tile adapter asserts result LAST one word early", [
        ("systolic_tile_adapter.sv",
         "assign c_stream_last = c_stream_valid && (c_count == RES_WORDS - 1);",
         "assign c_stream_last = c_stream_valid && (c_count == RES_WORDS - 2);")]),
    "M30": ("matrix tile buffer asserts output LAST one word early", [
        ("tiled_matrix_tile_buffer.sv",
         "c_out_last = c_out_valid && (c_out_count == c_total_words - 1);",
         "c_out_last = c_out_valid && (c_out_count == c_total_words - 2);")]),
    "M31": ("shell reports completion as a level (DONE/IRQ cannot be cleared)", [
        ("tiled_dma_shell.sv",
         "assign dma_done  = all_complete && !done_reported_q && !dma_start;",
         "assign dma_done  = all_complete;")]),
    "M32": ("illegal descriptor reaches the movers (core wedges BUSY)", [
        ("tiled_dma_shell.sv",
         "assign job_accept = dma_start && desc_legal;",
         "assign job_accept = dma_start;")]),
    "M33": ("descriptor base-address alignment not checked", [
        ("tiled_dma_shell.sv",
         "wire desc_legal = tile_mn_ok && tile_k_ok && dims_ok && align_ok;",
         "wire desc_legal = tile_mn_ok && tile_k_ok && dims_ok;")]),
    "M34": ("rejected START still reports a stale DONE", [
        ("tiled_dma_shell.sv",
         "done_reported_q  <= !desc_legal;",
         "done_reported_q  <= 1'b0;")]),
    "M35": ("per-channel bias column counter never wraps at N", [
        ("tiled_axi4_gemm_top.sv",
         "out_col_q <= (32'(out_col_q) + 1 >= shell_n) ? '0 : out_col_q + 1'b1;",
         "out_col_q <= out_col_q + 1'b1;")]),
    "M36": ("bias vector writable while a job is running", [
        ("tiled_axi4_gemm_top.sv",
         "end else if (reg_wr_en && bias_wr_hit && !shell_job_busy) begin",
         "end else if (reg_wr_en && bias_wr_hit) begin")]),
    "M37": ("pipelined engine drains one cycle short (2N-2)", [
        ("tiled_gemm_engine.sv",
         "if (drain_count == DRAIN_W'(DRAIN_CYCLES - 1))",
         "if (drain_count == DRAIN_W'(DRAIN_CYCLES - 2))")]),
    "M38": ("pipelined engine releases C rows before their last N block", [
        ("tiled_gemm_engine.sv",
         "                    feed_k <= 0;\n                    if (last_n_block) begin\n                        rows_ready <= m0_q + tm_len;",
         "                    feed_k <= 0;\n                    rows_ready <= m0_q + tm_len;\n                    if (last_n_block) begin")]),
    "M39": ("pipelined engine does not restart K for the next tile", [
        ("tiled_gemm_engine.sv",
         "                    feed_k <= 0;\n                    if (last_n_block) begin",
         "                    if (last_n_block) begin")]),
    "M40": ("pipelined engine skips clearing accumulators between tiles", [
        ("tiled_gemm_engine.sv",
         "wire arr_clear = (state == S_CLEAR) || (state == S_CAPTURE);",
         "wire arr_clear = (state == S_CLEAR);")]),
    "M41": ("pipelined engine output ignores row readiness", [
        ("tiled_gemm_engine.sv",
         "(out_count < c_total) && (out_row < rows_ready);",
         "(out_count < c_total);")]),
    "M42": ("DMA memory port ignores write strobes", [
        ("axi_dma_mem_port.sv",
         "if (w_fire && !w_err) mem_we = c_wstrb;",
         "if (w_fire && !w_err) mem_we = 4'hF;")]),
    "M43": ("DMA memory port range check lets a burst run one word past RAM", [
        ("axi_dma_mem_port.sv",
         "localparam logic [ADDR_W:0] WIN_HI = (ADDR_W+1)'(BASE) + (ADDR_W+1)'(DEPTH) * 4;",
         "localparam logic [ADDR_W:0] WIN_HI = (ADDR_W+1)'(BASE) + (ADDR_W+1)'(DEPTH) * 4 + 4;")]),
    "M44": ("DMA memory port skid buffer ignores same-cycle pops (half throughput)", [
        ("axi_dma_mem_port.sv",
         "wire [2:0] f_occupancy = {1'b0, f_count} + {2'b00, r_pending} - {2'b00, out_pop};",
         "wire [2:0] f_occupancy = {1'b0, f_count} + {2'b00, r_pending};")]),
    "M45": ("DMA memory port read arbiter always prefers A", [
        ("axi_dma_mem_port.sv",
         "wire pick_a = a_arvalid && (!b_arvalid || !rr_prefer_b);",
         "wire pick_a = a_arvalid;")]),
    "M46": ("DMA memory port writes RAM on an erroring burst", [
        ("axi_dma_mem_port.sv",
         "if (w_fire && !w_err) mem_we = c_wstrb;",
         "if (w_fire) mem_we = c_wstrb;")]),
}

MUTANT_TB = {
    "M01": "accel", "M02": "accel", "M03": "accel", "M04": "accel",
    "M05": "array", "M06": "accel", "M07": "accel", "M08": "accel",
    "M09": "accel", "M10": "accel", "M11": "array", "M12": "array",
    "M13": "accel", "M14": "accel", "M15": "accel", "M16": "accel",
    "M17": "accel", "M18": "accel", "M19": "accel", "M20": "accel",
    "M21": "ml_packer", "M22": "ml_core",
    "M23": "formal_read_dma", "M24": "formal_write_dma",
    "M25": "read_dma", "M26": "write_dma", "M27": "scheduler",
    "M28": "chain", "M29": "tile", "M30": "stream_gemm:P0",
    "M31": "axi4_gemm", "M32": "axi4_gemm", "M33": "axi4_gemm", "M34": "axi4_gemm",
    "M35": "axi4_gemm", "M36": "axi4_gemm",
    "M37": "stream_gemm", "M38": "axi4_gemm", "M39": "stream_gemm", "M40": "stream_gemm",
    "M41": "axi4_gemm",
    "M42": "mem_port", "M43": "mem_port", "M44": "mem_port", "M45": "mem_port",
    "M46": "mem_port",
}


def make(mid, out):
    out = pathlib.Path(out)
    rtl = out / "rtl"
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(ROOT / "rtl", rtl)
    for fname, old, new in MUTANTS[mid][1]:
        path = rtl / fname
        text = path.read_text()
        count = text.count(old)
        if count != 1:
            sys.exit(f"{mid}: pattern occurs {count}x in {fname} (must be 1): {old!r}")
        path.write_text(text.replace(old, new))


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "list":
        for mid, (desc, _) in MUTANTS.items():
            print(f"{mid}\t{MUTANT_TB[mid]}\t{desc}")
    elif len(sys.argv) == 4 and sys.argv[1] == "make":
        make(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
