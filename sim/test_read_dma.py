"""AXI4 read-DMA burst and stream-handshake regression."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge


async def read_memory_slave(dut, memory, bursts):
    dut.m_axi_arready.value = 1
    dut.m_axi_rvalid.value = 0
    dut.m_axi_rlast.value = 0
    while True:
        # Drive and sample the AXI source on the falling edge.  The following
        # rising edge is then the unambiguous protocol handshake edge.
        await FallingEdge(dut.clk)
        if dut.m_axi_arvalid.value and dut.m_axi_arready.value:
            addr = int(dut.m_axi_araddr.value)
            beats = int(dut.m_axi_arlen.value) + 1
            bursts.append((addr, beats))
            for beat in range(beats):
                dut.m_axi_rdata.value = memory[(addr - 0x1000) // 4 + beat]
                dut.m_axi_rlast.value = int(beat == beats - 1)
                dut.m_axi_rvalid.value = 1
                while True:
                    await RisingEdge(dut.clk)
                    if dut.m_axi_rready.value:
                        break
            # The final beat has now been consumed and the DUT may issue the
            # next AR request on the following cycle.
            dut.m_axi_rvalid.value = 0
            dut.m_axi_rlast.value = 0


@cocotb.test()
async def test_read_dma_splits_bursts_and_honors_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.stream_ready.value = 0
    dut.m_axi_rresp.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    memory = [0xA5000000 + i for i in range(16)]
    bursts = []
    slave = cocotb.start_soon(read_memory_slave(dut, memory, bursts))
    dut.base_addr.value = 0x1000
    dut.word_count.value = 9
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    got = []
    for cycle in range(200):
        await FallingEdge(dut.clk)
        dut.stream_ready.value = int(cycle >= 4)
        await ReadOnly()
        if dut.stream_valid.value and dut.stream_ready.value:
            got.append(int(dut.stream_data.value))
            if dut.stream_last.value:
                break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError(f"DMA did not produce a final stream word: got={got}, bursts={bursts}")

    await RisingEdge(dut.clk)
    await ReadOnly()

    assert got == memory[:9]
    assert bursts == [(0x1000, 4), (0x1010, 4), (0x1020, 1)]
    assert dut.done.value == 1
    assert dut.error.value == 0
    slave.kill()
