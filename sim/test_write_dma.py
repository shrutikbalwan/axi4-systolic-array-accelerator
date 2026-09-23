"""AXI4 write-DMA burst and response-handshake regression."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge


async def write_memory_slave(dut, bursts, memory):
    dut.m_axi_awready.value = 1
    dut.m_axi_wready.value = 1
    dut.m_axi_bvalid.value = 0
    current = None
    while True:
        await FallingEdge(dut.clk)
        if dut.m_axi_awvalid.value and dut.m_axi_awready.value:
            current = {
                "addr": int(dut.m_axi_awaddr.value),
                "beats": int(dut.m_axi_awlen.value) + 1,
                "data": [],
            }
            bursts.append(current)
        if dut.m_axi_wvalid.value and dut.m_axi_wready.value:
            assert current is not None
            current["data"].append(int(dut.m_axi_wdata.value))
            if dut.m_axi_wlast.value:
                assert len(current["data"]) == current["beats"]
                base = (current["addr"] - 0x2000) // 4
                memory[base : base + len(current["data"])] = current["data"]
                dut.m_axi_bvalid.value = 1
        if dut.m_axi_bvalid.value and dut.m_axi_bready.value:
            # Keep BVALID asserted through the rising-edge response
            # handshake; clearing it on the preceding falling edge races the
            # DUT's synchronous state machine.
            await RisingEdge(dut.clk)
            dut.m_axi_bvalid.value = 0


@cocotb.test()
async def test_write_dma_splits_bursts_and_honors_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.stream_valid.value = 0
    dut.m_axi_bresp.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    words = [0x5A000000 + i for i in range(9)]
    memory = [0] * 16
    bursts = []
    slave = cocotb.start_soon(write_memory_slave(dut, bursts, memory))
    dut.base_addr.value = 0x2000
    dut.word_count.value = len(words)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    dut.stream_valid.value = 1
    for index, word in enumerate(words):
        dut.stream_data.value = word
        dut.stream_last.value = int(index == len(words) - 1)
        while True:
            await FallingEdge(dut.clk)
            await ReadOnly()
            ready = bool(dut.stream_ready.value)
            await RisingEdge(dut.clk)
            if ready:
                break
    dut.stream_valid.value = 0
    dut.stream_last.value = 0

    for _ in range(20):
        if dut.done.value:
            break
        await RisingEdge(dut.clk)
    assert dut.done.value == 1
    assert dut.error.value == 0
    assert [(b["addr"], b["beats"]) for b in bursts] == [
        (0x2000, 4), (0x2010, 4), (0x2020, 1)
    ]
    assert memory[:9] == words
    slave.kill()
