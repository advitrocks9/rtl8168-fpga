# Build and per-unit customisation

## Requirements

- Xilinx Vivado WebPACK 2023.2 or later
- EnigmaX1 board (Artix-7 XC7A75T-FGG484-2)

## Build

From the Vivado Tcl Shell:

```tcl
source vivado_generate_project.tcl -notrace
source vivado_build.tcl -notrace
```

`vivado_generate_project.tcl` creates the project and generates the COE-backed
BRAM/ROM IP (`bram_bar_rtl8168` and `drom_bar_writemask` from the BAR COEs,
`bram_bar4_msix` for the MSI-X region, and the config-space cores), so the
`.xci` files are not committed. Build is roughly an hour. On Windows, if it
fails with a path-length error, move the repo somewhere short like `C:\w\`.

## Flash

Connect the EnigmaX1 update port over USB, then:

```tcl
source vivado_flash.tcl -notrace
```

Flash part is `IS25LP128F`.

## Per-unit MAC and DSN

The MAC and Device Serial Number in this repo use placeholder values; set them
per unit before deploying. Give each card a unique pair; don't reuse them.

The default committed DSN is derived from MAC `00:E0:4C:68:00:01` and is
consistent across all three locations (COE, SV, Tcl).

### 1. MAC

Use the Realtek OUI with device byte `0x68`:

```
MAC = 00:E0:4C:68:XX:YY      (pick XX:YY at random, unique per unit)
```

### 2. DSN (EUI-64 from the MAC)

```
MAC:    00:E0:4C : 68:XX:YY
EUI-64: 00:E0:4C : FF:FE : 68:XX:YY
```

In config space, little-endian DWORDs:

```
DWORD at 0x164 (low):  0xFF4CE000
DWORD at 0x168 (high): 0xYYXX68FE
```

### 3. Files to edit

| File | Location | Change |
|---|---|---|
| `ip/pcileech_bar_rtl8168.coe` | DW 0x000, 0x001 | MAC bytes (little-endian) |
| `ip/pcileech_cfgspace.coe` | DW 0x059, 0x05A | DSN low / high |
| `src/pcileech_pcie_cfg_a7.sv` | `rw[127:64]` (~line 215) | DSN value |
| `vivado_generate_project.tcl` | `CONFIG.DSN_Value` | `{HIGH32_LOW32}` |

The DSN appears in three places (cfgspace COE, the runtime `rw[]` default, and
the PCIe IP config); all three must match. The committed defaults are already
consistent, but must be changed per unit.

## Subsystem IDs

Default is `SVID=1458` (Gigabyte), `SSID=E000`. To change:

- `vivado_generate_project.tcl`: `CONFIG.Subsystem_Vendor_ID`, `CONFIG.Subsystem_ID`
- `ip/pcileech_cfgspace.coe`: DW `0x00B`
- `src/pcileech_fifo.sv`: `rw[143:128]` (SVID), `rw[159:144]` (SSID), and `_pcie_core_config`

### VID/DID via the GUI

If you'd rather edit IDs in the GUI: generate the project, open the `.xpr`,
find `i_pcie_7x_0` under `i_pcileech_pcie_a7` in Design Sources, double-click →
IDs tab → edit → Generate, then re-run synthesis and implementation.

## Config space

The presented config space lives in `ip/pcileech_cfgspace.coe` (1024 DWORDs).
`ip/pcileech_cfgspace_writemask.coe` controls which bits the host can modify;
W1C bits (AER status, PCIe DevSta, PMCSR PME_Status) are in
`ip/pcileech_cfgspace_rw1c.coe`. The shadow space is enabled by `rw[203]=0` in
`pcileech_fifo.sv` (set it to `1` to fall back to the upstream all-zeros
behaviour). The decoded layout is in [docs/REGISTERS.md](docs/REGISTERS.md).

## Resource usage

Pre-bring-up estimate on XC7A75T; no utilisation/timing report is committed.

| Resource | Used | Available | % |
|---|---|---|---|
| LUT | ~12,500 | 47,200 | 26 |
| FF | ~9,500 | 94,400 | 10 |
| BRAM 36Kb | ~25 | 105 | 24 |
| GTP | 1 | 4 | 25 |
| PCIE_2_1 | 1 | 1 | 100 |
