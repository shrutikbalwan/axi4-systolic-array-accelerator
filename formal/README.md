# Formal verification foundation

Dynamic tests cover AXI backpressure and the accelerator schedule. The next
verification milestone is to add SymbiYosys properties for the protocol
adapter and controller. The intended properties are:

- `BVALID` and `BRESP` remain stable until `BREADY`.
- `RVALID`, `RDATA` and `RRESP` remain stable until `RREADY`.
- No register write is issued until both AW and W have handshaken.
- Every accepted AR produces exactly one read response.
- A valid `START` eventually reaches `DONE` when the clock continues.
- `BUSY` excludes operand and LEN writes.
- A new run clears previous accumulators before feeding data.
- At completion, `MAC_COUNT = N*N*K` and `ACTIVE_CYCLES = K+2*N-1`.

Assertions should be kept in bind modules so the synthesizable RTL remains
unchanged. The formal target should use the same parameter matrix as the
simulation and mutation regressions.

[`axi_lite_slave_properties.sv`](axi_lite_slave_properties.sv) contains the
first reusable AXI response-stability assertions and backpressure covers. It
is intentionally excluded from synthesis and should be bound to
`axi_lite_slave` by the future `.sby` harness.

[`axi_lite_slave.sby`](axi_lite_slave.sby) and
[`axi_lite_slave_formal.sv`](axi_lite_slave_formal.sv) provide the first
standalone SymbiYosys harness. They prove response persistence and payload
stability under arbitrary AXI backpressure once `sby` is available.

[`ping_pong_bank_manager_properties.sv`](ping_pong_bank_manager_properties.sv)
adds ownership invariants for the DMA/compute overlap protocol: completion
events require an active owner, grants require requests, and error state is
sticky. It is a bind-style property module and is not part of the synthesis
source list.

`ping_pong_bank_manager.sby` and its harness make those properties executable
with SymbiYosys. Invalid completion events are modeled as arbitrary inputs and
must produce sticky error state; valid ownership transitions must preserve the
bank protocol.

`scripts/run_checks.sh` invokes this proof automatically when `sby` is on
`PATH`; otherwise it reports the proof as skipped while still running the
simulation and synthesis gates.
