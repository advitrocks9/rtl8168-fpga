# rtl8168-fpga

RTL8168H NIC emulation firmware for the EnigmaX1 board (Artix-7 XC7A75T). Built on the PCILeech v4.14 FPGA framework.

The FPGA presents as a genuine Realtek RTL8168H Gigabit Ethernet controller (VID `10EC`, DID `8168`, RevID `15`) over PCIe Gen2 x1.

## Building

Requires Xilinx Vivado WebPACK 2023.2 or later.

```
source vivado_generate_project.tcl -notrace
source vivado_build.tcl -notrace
```

Build takes ~1 hour. See [build.md](build.md) for customization (device IDs, DSN, config space, BAR regions).

## Flashing

Connect the EnigmaX1 update port via USB, then:

```
source vivado_flash.tcl -notrace
```

Flash memory part: `is25lp128f`.

## Implementation

See [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for the full spec — register maps, state machines, COE file contents, wiring details, and anti-detection hardening.

Device profile and driver analysis: [docs/RTL8168_DEVICE_PROFILE.md](docs/RTL8168_DEVICE_PROFILE.md).

## License

Published source code is licensed under the MIT License. Xilinx IP cores are generated locally under the Xilinx CORE LICENSE AGREEMENT via Vivado WebPACK.

Based on [ufrisk/pcileech-fpga](https://github.com/ufrisk/pcileech-fpga/).
