# Formal verification

The AXI protocol checks in `axi_fvip_compat_properties.sv` are
Yosys-compatible ports of the applicable source/destination rules from
[YosysHQ-GmbH/SVA-AXI4-FVIP](https://github.com/YosysHQ-GmbH/SVA-AXI4-FVIP),
pinned at commit `250f1ffd47fc1cdc4b4dd1670c6e1df58dec1b12`. The upstream
ISC terms are preserved in `LICENSE.SVA-AXI4-FVIP`.

The upstream suite uses named, parameterized SVA constructs that the stock
Yosys frontend cannot lower. The ports retain the upstream rule names and AXI
spec references but express them as clocked immediate assertions. Likewise,
the harnesses instantiate the checkers directly because this frontend does
not support `bind`; the synthesizable RTL remains free of formal code.

The executable harnesses prove:

- `axi_lite_slave.sby`: B and R VALID reset behavior, persistence, and payload
  stability under arbitrary backpressure.
- `axi4_read_dma.sby`: AR reset behavior, 4KB boundary, size, burst type,
  maximum length, and address-channel stability.
- `axi4_write_dma.sby`: AW/W reset behavior, 4KB boundary, size, burst type,
  maximum length, WLAST beat accounting, and AW/W stability.
- `ping_pong_bank_manager.sby`: DMA/compute ownership invariants and sticky
  error behavior.

The DMA harnesses assume naturally aligned word descriptors and legal AXI
destinations. The write harness also assumes the source stream holds its
payload under backpressure. Both use depth 40 cover tasks, which reach a
second burst (read step 4, write step 5), so the exercised trace includes a
multi-burst transfer rather than only its first address request. The safety
properties themselves are unbounded proofs (`smtbmc` k-induction for read and
ABC PDR for write).

The former hand-written BVALID/BRESP and RVALID/RDATA/RRESP stability checks
were removed only after the FVIP-derived suite passed: each was an exact
duplicate of the corresponding FVIP rule. No unique assertion was dropped.

Run all proofs through `scripts/run_checks.sh`, or run an individual target
from this directory with, for example, `sby -f axi4_read_dma.sby`.
