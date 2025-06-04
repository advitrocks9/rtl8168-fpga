# Build & Customisation

## Requirements

- Xilinx Vivado WebPACK 2023.2 or later
- EnigmaX1 board (Artix-7 XC7A75T-FGG484-2)

## Building

From the Vivado Tcl Shell:

```tcl
source vivado_generate_project.tcl -notrace
source vivado_build.tcl -notrace
```

Takes roughly an hour depending on your machine. If it fails with a path-length error on Windows, move the repo somewhere short like `C:\w\`.

## Flashing

Connect the EnigmaX1 update port via USB, then:

```tcl
source vivado_flash.tcl -notrace
```

Flash part is `IS25LP128F`.

## Per-device customisation

Each unit needs a unique MAC and DSN. The default values in this repo are placeholders.

### 1. Generate a MAC

Use the Realtek OUI with device byte `0x68`:

```
MAC = 00:E0:4C:68:XX:YY
```

Pick `XX:YY` randomly. Don't reuse across units.

### 2. Derive the DSN

The RTL8168 convention uses EUI-64:

```
MAC:    00:E0:4C : 68:XX:YY
EUI-64: 00:E0:4C : FF:FE : 68:XX:YY
```

In config space (little-endian DWORDs):

```
DWORD at 0x164 (low):  0xFF4CE000
DWORD at 0x168 (high): 0xYYXX68FE
```

### 3. Update these files

| File | Location | What to change |
|---|---|---|
| `ip/pcileech_bar_rtl8168.coe` | DW 0x000, 0x001 | MAC bytes (little-endian) |
| `ip/pcileech_cfgspace.coe` | DW 0x059, 0x05A | DSN low/high |
| `src/pcileech_pcie_cfg_a7.sv` | line ~215 | `rw[127:64]` DSN value |
| `vivado_generate_project.tcl` | `CONFIG.DSN_Value` | `{HIGH32_LOW32}` |

### 4. Subsystem IDs

Default is `SVID=1458` (Gigabyte), `SSID=E000`. To change, update:

- `vivado_generate_project.tcl` - `CONFIG.Subsystem_Vendor_ID`, `CONFIG.Subsystem_ID`
- `ip/pcileech_cfgspace.coe` - DW `0x00B`
- `src/pcileech_fifo.sv` - `rw[143:128]` (SVID), `rw[159:144]` (SSID), and `_pcie_core_config`

### 5. Changing VID/DID via the GUI

If you'd rather use the Vivado GUI:

1. Generate the project (`vivado_generate_project.tcl`).
2. Open the `.xpr` file.
3. In the Design Sources hierarchy, find `i_pcie_7x_0` under `i_pcileech_pcie_a7`.
4. Double-click > IDs tab > edit > OK > Generate.
5. Re-run synthesis and implementation.

## Config space

Custom config space lives in `ip/pcileech_cfgspace.coe` (1024 DWORDs). The writemask in `ip/pcileech_cfgspace_writemask.coe` controls which bits the host can modify. W1C bits (AER status, PCIe DevSta, PMCSR PME_Status) are defined in `ip/pcileech_cfgspace_rw1c.coe`.

The flag `rw[203]` in `pcileech_fifo.sv` enables the shadow config space. It's set to `0` in this repo (enabled). Setting it to `1` falls back to the upstream all-zeros behaviour.

## Resource usage

Rough numbers post-implementation on XC7A75T:

| Resource | Used | Available | % |
|---|---|---|---|
| LUT | ~12,500 | 47,200 | 26 |
| FF | ~9,500 | 94,400 | 10 |
| BRAM 36Kb | ~25 | 105 | 24 |
| GTP | 1 | 4 | 25 |
| PCIE_2_1 | 1 | 1 | 100 |
