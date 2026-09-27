#!/usr/bin/env python3
"""VexRiscv RISC-V SoC with the tiled AXI4 systolic accelerator, in simulation.

    python3 soc/accel_soc.py                 # build SoC + firmware, run to completion
    python3 soc/accel_soc.py --array-n 8     # same, with an 8x8 array
    python3 soc/accel_soc.py --no-run        # build only
    python3 soc/accel_soc.py --mem-port bus  # DMA through the CPU interconnect (old path)

What gets built (LiteX, Verilator):

    VexRiscv (RV32IM, I/D caches) --wishbone--+-- ROM (LiteX BIOS)
                                              +-- SRAM
                                              +-- main RAM port 0 (dual-port RAM)
                                              +-- CSRs (UART, timer, sim_finish)
                                              +-- accel register port @ 0x8200_0000
    tiled_axi4_gemm_top  A-read  AXI4 --+
                         B-read  AXI4 --+-- axi_dma_mem_port --> main RAM port 1
                         C-write AXI4 --+   (--mem-port direct, default: bursts at
                                             one beat per cycle, off the CPU bus)

With --mem-port bus the three AXI4 masters are instead added to the SoC bus
and bridged AXI4 -> Wishbone by LiteX (one Wishbone transfer per beat).

The firmware in soc/firmware runs a GEMM self-test and the 64-32-10 INT8
digits MLP on 360 held-out images, entirely through the accelerator's DMA,
then repeats the network on the CPU alone and prints cycle counts. The
simulation stops itself through LiteX's SimFinish CSR.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys

from migen import Cat, ClockSignal, If, Instance, Memory, ResetSignal, Signal

from litex.build.generic_platform import Pins, Subsignal
from litex.build.sim import SimPlatform
from litex.build.sim.config import SimConfig
from litex.build.sim.platform import SimFinish
from litex.gen import LiteXModule
from litex.soc.integration.builder import Builder
from litex.soc.integration.common import get_mem_data
from litex.soc.integration.soc import SoCRegion
from litex.soc.integration.soc_core import SoCCore
from litex.soc.interconnect import axi, wishbone
from migen.genlib.io import CRG

ROOT = pathlib.Path(__file__).resolve().parent.parent
RTL = ROOT / "rtl"
ACCEL_BASE = 0x8200_0000
MAIN_RAM_SIZE = 0x40000

RTL_FILES = [
    "pe_mac.sv", "systolic_array.sv", "ml_postprocess.sv", "ml_int8_packer.sv",
    "tile_scheduler.sv", "tile_accumulator.sv", "axi4_read_dma.sv", "axi4_write_dma.sv",
    "dma_descriptor_ctrl.sv", "systolic_tile_adapter.sv", "tiled_compute_chain.sv",
    "tiled_gemm_controller.sv", "tiled_matrix_tile_buffer.sv", "tiled_gemm_engine.sv", "tiled_stream_gemm_top.sv",
    "tiled_dma_shell.sv", "tiled_axi4_gemm_top.sv", "axi_dma_mem_port.sv",
]

_io = [
    ("sys_clk", 0, Pins(1)),
    ("sys_rst", 0, Pins(1)),
    ("serial", 0,
        Subsignal("source_valid", Pins(1)), Subsignal("source_ready", Pins(1)),
        Subsignal("source_data", Pins(8)),
        Subsignal("sink_valid", Pins(1)), Subsignal("sink_ready", Pins(1)),
        Subsignal("sink_data", Pins(8))),
]


class Platform(SimPlatform):
    def __init__(self):
        SimPlatform.__init__(self, "SIM", _io)


class SystolicAccel(LiteXModule):
    """tiled_axi4_gemm_top with a Wishbone register port and three AXI4 masters."""

    def __init__(self, platform, array_n=4, max_dim=64, max_burst=16):
        self.bus = wishbone.Interface(data_width=32, address_width=32, addressing="word")
        self.axi_a = axi.AXIInterface(data_width=32, address_width=32, id_width=1)
        self.axi_b = axi.AXIInterface(data_width=32, address_width=32, id_width=1)
        self.axi_c = axi.AXIInterface(data_width=32, address_width=32, id_width=1)
        self.irq = Signal()

        # Wishbone -> simple register port (one-cycle ack, reads are combinational
        # in dma_descriptor_ctrl so the data is captured with the ack).
        reg_addr = Signal(12)
        reg_wr_en = Signal()
        reg_rd_data = Signal(32)
        self.comb += [
            reg_addr.eq(Cat(Signal(2), self.bus.adr[:10])),
            reg_wr_en.eq(self.bus.cyc & self.bus.stb & self.bus.we & ~self.bus.ack),
        ]
        self.sync += [
            self.bus.ack.eq(0),
            If(self.bus.cyc & self.bus.stb & ~self.bus.ack,
                self.bus.ack.eq(1),
                self.bus.dat_r.eq(reg_rd_data)),
        ]

        a, b, c = self.axi_a, self.axi_b, self.axi_c
        self.specials += Instance("tiled_axi4_gemm_top",
            p_ADDR_W=32, p_DATA_W=32, p_MAX_BURST=max_burst, p_ARRAY_N=array_n,
            p_MAX_M=max_dim, p_MAX_N=max_dim, p_MAX_K=max_dim,
            i_clk=ClockSignal("sys"), i_rst_n=~ResetSignal("sys"),
            i_reg_wr_en=reg_wr_en, i_reg_wr_addr=reg_addr, i_reg_wr_data=self.bus.dat_w,
            i_reg_wr_strb=self.bus.sel, o_reg_wr_resp=Signal(2),
            i_reg_rd_addr=reg_addr, o_reg_rd_data=reg_rd_data, o_reg_rd_resp=Signal(2),
            o_irq=self.irq,
            # A operand read master.
            o_a_axi_araddr=a.ar.addr, o_a_axi_arlen=a.ar.len, o_a_axi_arsize=a.ar.size,
            o_a_axi_arburst=a.ar.burst, o_a_axi_arvalid=a.ar.valid, i_a_axi_arready=a.ar.ready,
            i_a_axi_rdata=a.r.data, i_a_axi_rresp=a.r.resp, i_a_axi_rlast=a.r.last,
            i_a_axi_rvalid=a.r.valid, o_a_axi_rready=a.r.ready,
            # B operand read master.
            o_b_axi_araddr=b.ar.addr, o_b_axi_arlen=b.ar.len, o_b_axi_arsize=b.ar.size,
            o_b_axi_arburst=b.ar.burst, o_b_axi_arvalid=b.ar.valid, i_b_axi_arready=b.ar.ready,
            i_b_axi_rdata=b.r.data, i_b_axi_rresp=b.r.resp, i_b_axi_rlast=b.r.last,
            i_b_axi_rvalid=b.r.valid, o_b_axi_rready=b.r.ready,
            # C result write master.
            o_c_axi_awaddr=c.aw.addr, o_c_axi_awlen=c.aw.len, o_c_axi_awsize=c.aw.size,
            o_c_axi_awburst=c.aw.burst, o_c_axi_awvalid=c.aw.valid, i_c_axi_awready=c.aw.ready,
            o_c_axi_wdata=c.w.data, o_c_axi_wstrb=c.w.strb, o_c_axi_wlast=c.w.last,
            o_c_axi_wvalid=c.w.valid, i_c_axi_wready=c.w.ready,
            i_c_axi_bresp=c.b.resp, i_c_axi_bvalid=c.b.valid, o_c_axi_bready=c.b.ready,
        )
        # Unused directions: read masters never write, the write master never reads.
        for rd in (a, b):
            self.comb += [rd.aw.valid.eq(0), rd.w.valid.eq(0), rd.b.ready.eq(1)]
        self.comb += [c.ar.valid.eq(0), c.r.ready.eq(1)]
        self.comb += [m.ar.cache.eq(0b0011) for m in (a, b)] + [c.aw.cache.eq(0b0011)]

        for f in RTL_FILES:
            platform.add_source(str(RTL / f))


class AccelSoC(SoCCore):
    def __init__(self, array_n=4, main_ram_init=None, mem_port="direct", **kwargs):
        platform = Platform()
        self.crg = CRG(platform.request("sys_clk"))
        SoCCore.__init__(self, platform, clk_freq=int(1e6),
            ident="VexRiscv + tiled INT8 systolic accelerator",
            cpu_type="vexriscv", cpu_variant="standard",
            uart_name="sim",
            integrated_rom_size=0x20000,
            integrated_sram_size=0x4000,
            integrated_main_ram_size=MAIN_RAM_SIZE if mem_port == "bus" else 0,
            integrated_main_ram_init=(main_ram_init or []) if mem_port == "bus" else [],
            timer_uptime=True,
            **kwargs)
        self.sim_finish = SimFinish()

        self.accel = SystolicAccel(platform, array_n=array_n)
        self.bus.add_slave("accel", self.accel.bus,
                           SoCRegion(origin=ACCEL_BASE, size=0x1000, cached=False))
        main_ram_base = self.mem_map["main_ram"]
        if mem_port == "bus":
            for name in ("a", "b", "c"):
                self.bus.add_master(name=f"accel_{name}",
                                    master=getattr(self.accel, f"axi_{name}"))
        else:
            # Main RAM as one true-dual-port memory: port 0 is a Wishbone SRAM on
            # the CPU bus, port 1 belongs to the accelerator's DMA alone.
            words = MAIN_RAM_SIZE // 4
            init = list(main_ram_init or []) + [0] * (words - len(main_ram_init or []))
            mem = Memory(32, words, init=init, name="main_ram_mem")
            self.main_ram = wishbone.SRAM(mem)
            self.bus.add_slave("main_ram", self.main_ram.bus,
                               SoCRegion(origin=main_ram_base, size=MAIN_RAM_SIZE))
            dma_port = mem.get_port(write_capable=True, we_granularity=8)
            self.specials += dma_port
            a, b, c = self.accel.axi_a, self.accel.axi_b, self.accel.axi_c
            self.specials += Instance("axi_dma_mem_port",
                p_ADDR_W=32, p_BASE=main_ram_base, p_DEPTH=words,
                i_clk=ClockSignal("sys"), i_rst_n=~ResetSignal("sys"),
                i_a_araddr=a.ar.addr, i_a_arlen=a.ar.len, i_a_arsize=a.ar.size,
                i_a_arburst=a.ar.burst, i_a_arvalid=a.ar.valid, o_a_arready=a.ar.ready,
                o_a_rdata=a.r.data, o_a_rresp=a.r.resp, o_a_rlast=a.r.last,
                o_a_rvalid=a.r.valid, i_a_rready=a.r.ready,
                i_b_araddr=b.ar.addr, i_b_arlen=b.ar.len, i_b_arsize=b.ar.size,
                i_b_arburst=b.ar.burst, i_b_arvalid=b.ar.valid, o_b_arready=b.ar.ready,
                o_b_rdata=b.r.data, o_b_rresp=b.r.resp, o_b_rlast=b.r.last,
                o_b_rvalid=b.r.valid, i_b_rready=b.r.ready,
                i_c_awaddr=c.aw.addr, i_c_awlen=c.aw.len, i_c_awsize=c.aw.size,
                i_c_awburst=c.aw.burst, i_c_awvalid=c.aw.valid, o_c_awready=c.aw.ready,
                i_c_wdata=c.w.data, i_c_wstrb=c.w.strb, i_c_wlast=c.w.last,
                i_c_wvalid=c.w.valid, o_c_wready=c.w.ready,
                o_c_bresp=c.b.resp, o_c_bvalid=c.b.valid, i_c_bready=c.b.ready,
                o_mem_addr=dma_port.adr, o_mem_we=dma_port.we, o_mem_wdata=dma_port.dat_w,
                i_mem_rdata=dma_port.dat_r,
            )
        self.add_constant("ACCEL_ARRAY_N", array_n)
        self.add_constant("ACCEL_MEM_PORT_DIRECT", int(mem_port != "bus"))
        if main_ram_init:
            # BIOS: skip memtest/boot menu and jump straight to the firmware.
            self.add_constant("ROM_BOOT_ADDRESS", self.mem_map["main_ram"])
            if mem_port != "bus":
                # LiteX only sets this for its own integrated main RAM. Without it
                # the BIOS memtest overwrites the preloaded firmware.
                self.add_config("MAIN_RAM_INIT")


def sim_config():
    cfg = SimConfig()
    cfg.add_clocker("sys_clk", freq_hz=int(1e6))
    cfg.add_module("serial2console", "serial")
    return cfg


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--array-n", type=int, default=4, choices=(4, 8))
    ap.add_argument("--build-dir", default=str(ROOT / "build" / "soc"))
    ap.add_argument("--no-run", action="store_true")
    ap.add_argument("--mem-port", default="direct", choices=("direct", "bus"),
                    help="direct: dedicated DMA port into main RAM; bus: via the CPU interconnect")
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    args = ap.parse_args()

    suffix = "" if args.mem_port == "direct" else "_bus"
    build_dir = pathlib.Path(args.build_dir) / f"n{args.array_n}{suffix}"
    fw_dir = ROOT / "soc" / "firmware"

    # 1. Generate the software environment (headers, BIOS, libs) for this SoC.
    soc = AccelSoC(array_n=args.array_n, mem_port=args.mem_port)
    Builder(soc, output_dir=str(build_dir), compile_gateware=False).build(
        sim_config=sim_config(), run=False)

    # 2. Model header (trained digits MLP + golden predictions) and firmware.
    model_h = fw_dir / "model_data.h"
    if not model_h.exists():
        subprocess.run([sys.executable, str(ROOT / "soc" / "gen_model.py"), "--out", str(model_h)],
                       check=True)
    subprocess.run(["make", "-C", str(fw_dir), f"BUILD_DIR={build_dir}",
                    f"OUT={build_dir / 'firmware'}", "-j", str(args.jobs)], check=True)
    fw_bin = build_dir / "firmware" / "firmware.bin"

    # 3. Rebuild with the firmware preloaded in main RAM, compile the Verilator model, run.
    soc = AccelSoC(array_n=args.array_n, mem_port=args.mem_port,
                   main_ram_init=get_mem_data(str(fw_bin), endianness="little"))
    Builder(soc, output_dir=str(build_dir)).build(
        sim_config=sim_config(), run=not args.no_run, interactive=False,
        threads=1, opt_level="O3")


if __name__ == "__main__":
    main()
