# Build Customization

## Building

1. Install Xilinx Vivado WebPACK 2023.2 or later.
2. Open Vivado Tcl Shell.
3. `cd` into this project directory.
4. Run `source vivado_generate_project.tcl -notrace`
5. Run `source vivado_build.tcl -notrace`

Build takes ~1 hour. If it fails due to long path, move the repo to a shorter path (e.g., `C:\Temp`).

## Customizing PCIe Identity

To change device/vendor IDs via the Vivado GUI:

1. Generate the project (steps 1-4 above).
2. Open `pcileech_enigma_x1.xpr` in the generated project subfolder.
3. In PROJECT MANAGER, expand: Design Sources > pcileech_enigma_x1_top > i_pcileech_pcie_a7.
4. Double-click `i_pcie_7x_0` to open the PCIe core designer.
5. Navigate to the IDs tab and modify values.
6. Optionally adjust BARs (minimum 4KB recommended).
7. Click OK, then Generate. Resume from step 5 of the build.

## Device Serial Number (DSN)

Edit `src/pcileech_pcie_cfg_a7.sv`:
```verilog
rw[127:64]  <= 64'h0000000101000A35;    // cfg_dsn
```

## Configuration Space

Custom config space is controlled by `rw[203]` in `src/pcileech_fifo.sv`:
- `1'b1` = returns all zeros (default upstream behavior)
- `1'b0` = uses custom config space from `ip/pcileech_cfgspace.coe`

The config space writemask is defined in `ip/pcileech_cfgspace_writemask.coe`.

## BAR PIO Memory Regions

Custom BAR implementations are plugged into `src/pcileech_tlps128_bar_controller.sv`. See `IMPLEMENTATION_PLAN.md` for the RTL8168 BAR implementation details.
