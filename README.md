# rtl8168-fpga

RTL8168H NIC emulation on the EnigmaX1 (Artix-7 XC7A75T). Fork of [pcileech-fpga](https://github.com/ufrisk/pcileech-fpga/) v4.14.

Presents as a Realtek RTL8168H Gigabit Ethernet controller over PCIe Gen2 x1. Passes the Linux r8169 driver probe and handles config-space / BAR-level interrogation.

## Features

### PCIe identity & config space
- Full RTL8168H identity in the PCIe hard block (VID `10EC`, DID `8168`, RevID `0x15`, class `020000`)
- 4 KB shadow config space BRAM with correct reset values for every register
- Complete PCI capability chain: PM (0x40) > MSI (0x50) > PCIe (0x70) > MSI-X (0xB0) > VPD (0xD0)
- Complete extended capability chain: AER (0x100) > VC (0x140) > DSN (0x160) > LTR (0x170) > L1 PM Substates (0x178)
- Per-bit writemask ROM so host writes can't touch read-only fields
- W1C (write-1-to-clear) mask ROM for AER status, PCIe DevSta, PMCSR PME_Status
- Configurable SVID/SSID (default: Gigabyte `1458:E000`)
- Per-unit Device Serial Number derived from MAC via EUI-64

### BAR register emulation
- BAR0 (I/O 256 B) and BAR2 (MMIO 4 KB) backed by a shared 1024x32 dual-port BRAM with COE-initialised reset values
- Read-modify-write pipeline gated by a writemask ROM, protects read-only fields (TxConfig XID bits, PHYstatus, RxMissed, etc.)
- Cfg9346 lock/unlock: MAC address and Config1-5 registers are write-protected until the host writes `0xC0` to Cfg9346
- TxConfig returns `0x54100780` (XID `0x541` = MAC_VER_46); upper identity bits are write-protected
- TxPoll (0x38) always reads `0xFF`, writes are silently accepted

### MSI / MSI-X interrupts
- BAR4 (MMIO 16 KB) implemented as a 4096x32 BRAM for the MSI-X table (4 vectors) and PBA
- MSI-X capability at config offset 0xB0 with table BIR=BAR4, PBA offset 0x800
- 64-bit MSI capability at config offset 0x50
- Interrupt mask/status registers (0x3C/0x3E) with W1C semantics on IntrStatus
- `msi_request` signal threaded through the module hierarchy to the Xilinx `cfg_interrupt` port
- Edge-detected MSI pulse with proper clear on `cfg_interrupt_rdy` acknowledge

### PHY & MDIO emulation
- PHYAR (0x60) state machine with 32x16-bit PHY register file (BMCR, BMSR, PHYID1/2, ANAR, GBCR, etc.)
- Correct PHY IDs: `001C:C912`
- Flag-polling protocol with 1200-1300 cycle completion delay (~20 us) plus LFSR jitter
- Read-only enforcement on BMSR, PHYID1/2, ANLPAR, ANER, GBSR, GBESR
- GPHY_OCP (0xB8) state machine for RTL8168G+ OCP-style PHY access, shares the same register file as PHYAR

### ERI register access
- ERIAR (0x74) / ERIDR (0x70) state machine with internal 64x32-bit ERI register file
- Byte-enable masked writes via ERIAR[15:12]
- 200-263 cycle completion delay with LFSR jitter
- Handles the extensive ERIAR sequences issued by `rtl_hw_start_8168h_1`

### Chip command & reset
- ChipCmd (0x37) with writable bits 7, 4, 3, 2; bit 0 (RxBufEmpty) always reads 1
- CmdReset (bit 4) triggers a 625-cycle self-clear (~10 us), then returns `0x01`
- r8169 driver polls this during probe, clears well within the 100 ms timeout

### Timing & anti-detection
- Free-running 32-bit timer at BAR 0x48, increments by 2 per 62.5 MHz clock (125 MHz equivalent)
- 16-bit Galois LFSR (x^16 + x^15 + x^13 + x^4 + 1) providing per-cycle pseudo-random values
- LFSR-derived jitter on PHYAR, ERIAR, and GPHY_OCP completion delays to defeat poll-loop profiling
- BAR read latency: 2-cycle base (matching upstream `zerowrite4k` contract)
- VPD capability present in shadow; Flag bit never asserted so VPD reads timeout gracefully
- PHYstatus = 0x00 (no link), consistent with a NIC that has no cable connected
- Correct BAR sizing via the PCIe hard block: BAR0 returns `0xFFFFFF01`, BAR2 `0xFFFFF004`, BAR4 `0xFFFFC004`
- ASPM L0s + L1 declared in LnkCap; handled at PHY level by the Xilinx IP core
- Single-function device, no unexpected extra functions during enumeration

### Power management
- D1 and D2 power states supported in PM capability
- PMCSR writes accepted into shadow BRAM; PME_Status is W1C
- D3hot writes accepted (device continues to respond to config space, consistent with spec)

## Project layout

```
src/
  pcileech_bar_impl_rtl8168.sv   BAR0/BAR2 register emulation (instantiates all sub-state-machines)
  pcileech_bar_impl_msix.sv      BAR4 MSI-X table / PBA
  rtl8168_phyar_emu.sv           PHYAR - MDIO PHY register access
  rtl8168_eriar_emu.sv           ERIAR/ERIDR - ERI register access
  rtl8168_gphy_ocp_emu.sv        GPHY_OCP - OCP PHY access (shared register file with PHYAR)
  rtl8168_chipcmd_emu.sv         ChipCmd with RST self-clear
  rtl8168_cfg9346_emu.sv         Cfg9346 config lock/unlock
  rtl8168_intr_emu.sv            Interrupt mask/status + MSI trigger
  rtl8168_timer_emu.sv           Free-running 125 MHz timer counter
  rtl8168_lfsr.sv                16-bit Galois LFSR for timing jitter
ip/
  pcileech_cfgspace.coe          4 KB config space with full capability chain
  pcileech_cfgspace_writemask.coe  per-bit write mask
  pcileech_cfgspace_rw1c.coe     W1C bit mask (AER, PCIe DevSta, PMCSR)
  pcileech_bar_rtl8168.coe       BAR register reset values
  pcileech_bar_writemask.coe     BAR per-bit write mask
```

Everything else (`pcileech_fifo.sv`, TLP engines, FT601 bridge, cfgspace shadow, etc.) is upstream PCILeech with minor wiring changes for the MSI path and default IDs.

## Quick start

Vivado 2023.2+ WebPACK. From the Tcl Shell:

```tcl
source vivado_generate_project.tcl -notrace
source vivado_build.tcl -notrace
```

Takes about an hour. Flash via `vivado_flash.tcl` over the USB update port (IS25LP128F).

See [BUILD.md](BUILD.md) for per-unit customisation (MAC, DSN, subsystem IDs).

## Key values

| Field | Value |
|---|---|
| VID / DID | `10EC` / `8168` |
| RevID | `0x15` |
| SVID / SSID | `1458` / `E000` (Gigabyte) |
| XID | `0x541` = MAC_VER_46 |
| TxConfig | `0x54100780` |
| PHY ID | `001C:C912` |
| BARs | 0: I/O 256 B, 2: Mem64 4 KB, 4: Mem64 16 KB |
| MSI-X | 4 vectors, table at BAR4+0x000, PBA at BAR4+0x800 |
| Cap chain | PM > MSI > PCIe > MSI-X > VPD |
| Ext caps | AER > VC > DSN > LTR > L1SS |

## Docs

- [BUILD.md](BUILD.md) - build instructions, per-unit customisation

## Resource usage (XC7A75T)

| Resource | Used | Available | % |
|---|---|---|---|
| LUT | ~12,500 | 47,200 | 26 |
| FF | ~9,500 | 94,400 | 10 |
| BRAM 36Kb | ~25 | 105 | 24 |
| GTP | 1 | 4 | 25 |

## Acknowledgements

Based on [ufrisk/pcileech-fpga](https://github.com/ufrisk/pcileech-fpga/) by Ulf Frisk.

## License

Source code: MIT. Xilinx IP cores generated locally under the Vivado WebPACK license.
