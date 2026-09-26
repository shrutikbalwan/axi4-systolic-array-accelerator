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
}

MUTANT_TB = {
    "M01": "accel", "M02": "accel", "M03": "accel", "M04": "accel",
    "M05": "array", "M06": "accel", "M07": "accel", "M08": "accel",
    "M09": "accel", "M10": "accel", "M11": "array", "M12": "array",
    "M13": "accel", "M14": "accel", "M15": "accel", "M16": "accel",
    "M17": "accel", "M18": "accel", "M19": "accel", "M20": "accel",
    "M21": "ml_packer", "M22": "ml_core",
    "M23": "formal_read_dma", "M24": "formal_write_dma",
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
