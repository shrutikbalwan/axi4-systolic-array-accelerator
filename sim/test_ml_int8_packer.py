"""Regression for INT32 -> quantized INT8 -> packed write-DMA beats."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import NextTimeStep, ReadOnly, RisingEdge


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
        # The previous iteration ends in ReadOnly after sampling outputs.
        # Move to a new simulator timestep before driving the next input beat.
        await NextTimeStep()
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


@cocotb.test()
async def test_wide_scaled_product_does_not_wrap(dut):
    """Clamp the 64-bit product before narrowing it to INT8."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.in_valid.value = 0
    dut.out_ready.value = 1
    dut.bias.value = 0
    dut.scale_mult.value = 1 << 30
    dut.scale_shift.value = 0
    dut.relu_en.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    dut.in_data.value = 3
    dut.in_last.value = 1
    dut.in_valid.value = 1
    await RisingEdge(dut.clk)
    dut.in_valid.value = 0
    await ReadOnly()

    assert dut.out_valid.value == 1
    assert int(dut.out_data.value) == 0x0000007F
    assert dut.out_last.value == 1
