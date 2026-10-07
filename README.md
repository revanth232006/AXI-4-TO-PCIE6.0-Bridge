# AXI-4 Stream to PCIe 6.0 Bridge

A hardware design implementing an AMBA AXI4-Stream interconnect layer with a central crossbar and dynamic arbiters. This project handles AXI4-Stream protocol signals and performs flit packetization targeted for PCIe 6.0 data transmission.

## Key Features
* **AMBA AXI4-Stream Interconnect:** Manages high-throughput data streams and protocol control signals.
* **Central Crossbar & Dynamic Arbitration:** Routes traffic and resolves contention between multiple data sources.
* **PCIe 6.0 Flit Packetization:** Formats incoming AXI4-Stream data into standardized flits for PCIe 6.0 downstream layers.
* **Automated Project Setup:** Includes a Tcl script to instantly rebuild the Vivado project environment without requiring bloated `.xpr` files.

## Project Structure
* `src/` - Verilog RTL source files for the interconnect, arbiters, and crossbar.
* `tb/` - Testbenches for verifying arbitration logic and packetization.
* `recreate_project.tcl` - Vivado Tcl script to generate the project workspace.

## How to Build
To reconstruct the Vivado project:
1. Open Vivado.
2. In the Tcl Console at the bottom, use `cd` to navigate to this repository's folder.
3. Run the following command:
   ```tcl
   source recreate_project.tcl
