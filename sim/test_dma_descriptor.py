"""Register-port regression for the tiled DMA/ML descriptor block."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge


async def write_reg(dut, addr, data, strobe=0xF):
    dut.reg_wr_addr.value = addr
    dut.reg_wr_data.value = data
    dut.reg_wr_strb.value = strobe
    dut.reg_wr_en.value = 1
    await ReadOnly()
    response = int(dut.reg_wr_resp.value)
    await RisingEdge(dut.clk)
    dut.reg_wr_en.value = 0
    return response


async def read_reg(dut, addr):
    dut.reg_rd_addr.value = addr
    await ReadOnly()
    return int(dut.reg_rd_data.value), int(dut.reg_rd_resp.value)


@cocotb.test()
async def test_descriptor_ml_registers_and_locking(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.reg_wr_en.value = 0
    dut.reg_wr_strb.value = 0
    dut.dma_busy.value = 0
    dut.dma_done.value = 0
    dut.dma_error.value = 0
    dut.perf_active_cycles.value = 123
    dut.perf_mac_count.value = 0x0000000200000040
    dut.perf_tile_count.value = 8
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    assert await write_reg(dut, 0x2C, 0xFFFFFFF0) == 0
    assert await write_reg(dut, 0x30, 0x00012345) == 0
    assert await write_reg(dut, 0x34, (7 << 2) | 3) == 0
    bias, resp = await read_reg(dut, 0x2C)
    assert resp == 0 and bias == 0xFFFFFFF0
    scale, resp = await read_reg(dut, 0x30)
    assert resp == 0 and scale == 0x00012345
    cfg, resp = await read_reg(dut, 0x34)
    assert resp == 0 and cfg == ((7 << 2) | 3)
    active, resp = await read_reg(dut, 0x38)
    assert resp == 0 and active == 123
    mac_lo, resp = await read_reg(dut, 0x3C)
    assert resp == 0 and mac_lo == 0x40
    mac_hi, resp = await read_reg(dut, 0x40)
    assert resp == 0 and mac_hi == 2
    tiles, resp = await read_reg(dut, 0x44)
    assert resp == 0 and tiles == 8

    # START is a pulse from the control write; once the engine is busy all
    # descriptor fields, including ML parameters, are protected.
    assert await write_reg(dut, 0x00, 1) == 0
    dut.dma_busy.value = 1
    assert await write_reg(dut, 0x2C, 0) == 2

    dut.dma_done.value = 1
    await RisingEdge(dut.clk)
    dut.dma_done.value = 0
    status, resp = await read_reg(dut, 0x04)
    assert resp == 0 and (status & 0x2) != 0

    dut.dma_busy.value = 0
    assert await write_reg(dut, 0x04, 0x2) == 0
    status, _ = await read_reg(dut, 0x04)
    assert (status & 0x2) == 0
