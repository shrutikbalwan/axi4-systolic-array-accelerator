"""Regression for INT32 -> quantized INT8 -> packed write-DMA beats."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge


@cocotb.test()
async def test_relu_saturation_and_partial_pack(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.in_valid.value = 0
    dut.out_ready.value = 1
    dut.bias.value = 0
    dut.scale_mult.value = 1
    dut.scale_shift.value = 0
    dut.relu_en.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    values = [-200, -1, 2, 200, 3]
    index = 0
    outputs = []
    while index < len(values) or dut.out_valid.value:
        active = index < len(values)
        dut.in_valid.value = int(active)
        if active:
            dut.in_data.value = values[index]
            dut.in_last.value = int(index == len(values) - 1)
        await RisingEdge(dut.clk)
        await ReadOnly()
        if active and dut.in_ready.value:
            index += 1
        if dut.out_valid.value and dut.out_ready.value:
            outputs.append((int(dut.out_data.value), int(dut.out_last.value)))

    assert outputs == [(0x7F020000, 0), (0x00000003, 1)]
