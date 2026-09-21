# AXI4 Systolic Array MAC Accelerator

Open-source 4x4 INT8 Systolic Array MAC Accelerator with AXI4-Lite control interface.

## 🏗️ Architecture Overview

```
                      +----------------------------+
                      |      AXI4-Lite Master      |
                      +-------------+--------------+
                                    |
                                    v
                      +-------------+--------------+
                      |   AXI4-Lite Control Regs   |
                      |  (Control, Status, Config) |
                      +-------------+--------------+
                                    |
            +-----------------------+-----------------------+
            |                                               |
            v                                               v
+-----------+-----------+                       +-----------+-----------+
|  Input Weight Buffer  |                       |  Input Feature Buffer |
|   (Ping-Pong SRAM)    |                       |   (Ping-Pong SRAM)    |
+-----------+-----------+                       +-----------+-----------+
            |                                               |
            +-----------------------+-----------------------+
                                    |
                                    v
                    +---------------+---------------+
                    |  4x4 INT8 Systolic Array MAC  |
                    |  +----+  +----+  +----+  +----+  |
                    |  |PE00|->|PE01|->|PE02|->|PE03|  |
                    |  +----+  +----+  +----+  +----+  |
                    |    |        |        |        |   |
                    |    v        v        v        v   |
                    |  +----+  +----+  +----+  +----+  |
                    |  |PE10|->|PE11|->|PE12|->|PE13|  |
                    |  +----+  +----+  +----+  +----+  |
                    |    |        |        |        |   |
                    |    v        v        v        v   |
                    |  +----+  +----+  +----+  +----+  |
                    |  |PE20|->|PE21|->|PE22|->|PE23|  |
                    |  +----+  +----+  +----+  +----+  |
                    |    |        |        |        |   |
                    |    v        v        v        v   |
                    |  +----+  +----+  +----+  +----+  |
                    |  |PE30|->|PE31|->|PE32|->|PE33|  |
                    |  +----+  +----+  +----+  +----+  |
                    +---------------+---------------+
                                    |
                                    v
                      +-------------+--------------+
                      |    Output Accumulator /    |
                      |    Result Buffer (SRAM)    |
                      +-------------+--------------+
```

## 📊 Specifications

| Feature | Specification |
| :--- | :--- |
| **Array Dimensions** | 4 x 4 Processing Elements (PEs) |
| **Data Precision** | INT8 (Inputs/Weights), INT32 Accumulation |
| **Interface** | AXI4-Lite Slave Register Interface |
| **Buffering** | Dual Ping-Pong SRAM for overlapping compute & load |
| **Target PDK** | SkyWater 130nm (Sky130) OpenLane ASIC Flow |
| **Verification** | Cocotb Python-based testbench environment |

## 📁 Repository Structure

```
.
├── .github/workflows/   # CI/CD workflows for automated build and verification
├── docs/                # Architecture diagrams, specifications, and documentation
├── openlane/            # OpenLane ASIC implementation scripts and configurations
├── rtl/                 # Verilog / SystemVerilog RTL source code
└── sim/                 # Cocotb verification testbenches and simulation run scripts
```
