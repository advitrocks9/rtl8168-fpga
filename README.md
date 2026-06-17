# rtl8168-fpga

Make a PCILeech DMA card enumerate as a Realtek RTL8168H Gigabit-Ethernet
controller, convincingly enough to satisfy the Linux `r8169` driver's probe at
the config-space and BAR level.

This is a fork of [ufrisk/pcileech-fpga](https://github.com/ufrisk/pcileech-fpga/)
v4.14 targeting the EnigmaX1 board (Artix-7 XC7A75T). PCILeech is a DMA
read/write framework used for memory forensics and hardware red-teaming. A
stock PCILeech card is trivially fingerprinted because it presents a generic,
known device identity. The work here replaces that identity with a specific,
real NIC's: every register the driver touches during enumeration is backed by
emulation that reproduces what a genuine RTL8168H returns.

I built it while studying how host software and kernel-level anti-cheat detect
DMA hardware by its PCIe footprint, namely which config-space fields, capability
layouts, and register-access timings give a counterfeit endpoint away. It is a
device-identity-emulation project, not a networking project. No packets are
ever sent or received.

## The problem

A PCIe endpoint is identified long before any driver-specific traffic. During
enumeration the host reads the configuration space (vendor/device IDs, BARs,
capability chains), and the matching driver then walks the device's register
file over the BARs. To pass as an RTL8168H you have to get three things right:

1. **Identity.** The 4 KB configuration space a real card exposes: IDs, class
   code, BAR sizing, and the full PCI + PCI-Express capability chains.
2. **Register file.** The BAR-mapped registers the `r8169` driver reads and
   writes during `probe`/`hw_start`, including the ones gated behind
   flag-polling handshakes (PHY/MDIO, ERI, OCP).
3. **Behaviour over time.** Registers that self-clear, lock/unlock, count, or
   complete after a delay, with timing inside the driver's poll budgets.

None of this is in upstream PCILeech. Stock builds answer BAR reads with zeros.

## Architecture

```
host  --USB3--> FT601 --> PCILeech FIFO/COM --> PCIe Gen2 x1 hard block
(DMA tooling)                                         |
                                          +-----------+-----------+
                                   config-space shadow       BAR controller
                                   (4 KB COE BRAM)        +-------+-------+
                                                      BAR0/BAR2        BAR4
                                                  RTL8168 register    MSI-X
                                                  file + state machines table
```

The PCILeech base (FT601 USB3 bridge, FIFO/COM, the Xilinx 7-series PCIe core,
TLP engines) is unchanged. Three things were added or rewired:

- **A shadow configuration space.** `pcileech_fifo.sv` flips the upstream
  `CFGTLP ZERO DATA` flag (`rw[203]`, line 290) so config-TLP reads are served
  from a 4 KB BRAM initialised by `ip/pcileech_cfgspace.coe` instead of
  returning zeros. The IDs in the PCIe hard block and `_pcie_core_config` were
  set to `10EC:8168`, rev `0x15`, subsystem `1458:E000` (Gigabyte).
- **A BAR0/BAR2 register file.** `pcileech_bar_impl_rtl8168.sv` serves both
  BARs from one 1024x32 dual-port BRAM (COE-initialised reset values) behind a
  writemask ROM, with eight state machines intercepting the registers that
  aren't plain storage.
- **A BAR4 MSI-X region** (`pcileech_bar_impl_msix.sv`) and an MSI request path
  threaded up to the PCIe core's `cfg_interrupt` (`pcileech_pcie_cfg_a7.sv`).

`pcileech_tlps128_bar_controller.sv` was rewired to share one instance across
BAR0/BAR2 and demux the response with a 2-cycle pipeline matching the register
file's read latency. Everything runs in the single `clk_pcie` domain, so the
MSI path needs no clock-domain crossing.

## Reverse-engineering the register map

The reset values, register offsets, and handshake protocols were lifted from
the Linux `r8169` driver source (`drivers/net/ethernet/realtek/r8169_main.c`),
not from a datasheet. The driver is the thing that has to be satisfied, so it
is the authority on what the chip must look like.

- **Chip version.** The driver identifies the MAC by reading `TxConfig` (0x40)
  and computing `xid = (txconfig >> 20) & 0xfcf`, then matching a table. The
  emulated `TxConfig` of `0x54100780` yields `xid = 0x541`, which matches
  `{ 0x7cf, 0x541, RTL_GIGA_MAC_VER_46, "RTL8168h/8111h" }`, so the driver
  binds the 8168H path and runs `rtl_hw_start_8168h_1`. The XID bits are held
  read-only by the writemask so the host can't perturb the identity.
- **Flag-polling handshakes.** PHYAR (0x60), ERIAR/ERIDR (0x74/0x70), and
  GPHY_OCP (0xB8) are not registers; they are request/complete protocols. The
  driver writes a command with bit 31 set and spins until the hardware clears
  (write) or sets (read) bit 31. Each is a small FSM (`rtl8168_phyar_emu.sv`,
  `rtl8168_eriar_emu.sv`, `rtl8168_gphy_ocp_emu.sv`) that mirrors the command,
  waits a completion delay, then flips the flag. PHYAR/OCP take ~20 us, ERI
  ~3-4 us, all well inside the driver's poll budgets.
- **Locks and self-clears.** `Cfg9346` (0x50) unlocks the MAC and Config
  registers only after the host writes `0xC0`, exactly as
  `rtl_unlock_config_regs` expects (`rtl8168_cfg9346_emu.sv`). `ChipCmd` (0x37)
  reset (bit 4) self-clears after 625 cycles (`rtl8168_chipcmd_emu.sv`), which
  the driver polls with a 100 ms timeout.
- **Shared PHY state.** PHYAR and GPHY_OCP address the same 32x16 PHY register
  file (BMCR/BMSR/PHYID/ANAR and the rest), since the 8168H driver reaches the
  PHY through both paths.

The per-register breakdown (offset, reset value, writemask, completion delay,
protocol) is in [docs/REGISTERS.md](docs/REGISTERS.md).

## What's emulated

| Area | Detail |
|---|---|
| Identity | VID `10EC`, DID `8168`, Rev `0x15`, class `020000`, subsystem `1458:E000` |
| Config space | 4 KB shadow BRAM; std caps PM (D1/D2+), MSI, PCIe (Gen1/x1, MPS 128B), MSI-X, VPD; ext caps AER, VC, DSN, LTR, L1SS (all version 1); per-bit writemask + W1C masks |
| BAR0 / BAR2 | I/O 256 B / MMIO 4 KB, shared register file, RMW behind writemask with skid buffer, Cfg9346-gated MAC/Config writes |
| BAR4 | 16 KB MSI-X table (4 vectors) + PBA backing store |
| State machines | PHYAR, GPHY_OCP, ERIAR/ERIDR, ChipCmd (reset self-clear), Cfg9346 (lock), IntrMask/Status (W1C + LinkChg), free-running timer |
| Timing | LFSR-jittered completion delays on the polling handshakes |

## Verification

- **Cross-checked against primary sources.** Every config-space DWORD,
  register offset, and handshake protocol was checked against the
  `r8169_main.c` source and against real `lspci -nnvvxxx` dumps of
  `10ec:8168` cards: identity, BAR sizing, capability offsets/order, MSI and
  MSI-X fields, and the PHYAR/ERIAR/GPHY_OCP/Cfg9346/ChipCmd protocols.
- **Brought up on hardware.** On the EnigmaX1 the `r8169` driver binds against
  the card and completes config-space and BAR-level interrogation.

## Key values

| Field | Value |
|---|---|
| VID / DID | `10EC` / `8168` |
| RevID | `0x15` |
| SVID / SSID | `1458` / `E000` (Gigabyte) |
| XID | `0x541`, maps to `RTL_GIGA_MAC_VER_46` (RTL8168h/8111h) |
| TxConfig | `0x54100780` |
| PHY ID | `001C:C800` (RTL8168H internal PHY) |
| DSN | `00:E0:4C:FF:FE:68:00:01` (EUI-64 from MAC, per-unit) |
| BARs | 0: I/O 256 B, 2: Mem64 4 KB, 4: Mem64 16 KB |
| MSI-X | 4 vectors, table BAR4+0x000, PBA BAR4+0x800 |
| Cap chain | PM, MSI, PCIe, MSI-X, VPD |
| Ext caps | AER, VC, DSN, LTR, L1SS |

## Build

Vivado 2023.2+ WebPACK. From the Tcl Shell:

```tcl
source vivado_generate_project.tcl -notrace
source vivado_build.tcl -notrace
```

Project generation creates the COE-backed BRAM/ROM IP (`bram_bar_rtl8168`,
`drom_bar_writemask`, `bram_bar4_msix`, and the cfgspace cores). Build takes
about an hour; flash with `vivado_flash.tcl` over the USB update port
(IS25LP128F). Per-unit MAC/DSN/subsystem customisation is in
[BUILD.md](BUILD.md).

## Layout

```
src/
  pcileech_bar_impl_rtl8168.sv   BAR0/BAR2 register file + state-machine mux
  pcileech_bar_impl_msix.sv      BAR4 MSI-X table / PBA
  rtl8168_phyar_emu.sv           PHYAR, MDIO PHY register access
  rtl8168_gphy_ocp_emu.sv        GPHY_OCP, OCP PHY access (shared PHY file)
  rtl8168_eriar_emu.sv           ERIAR/ERIDR, ERI register access
  rtl8168_chipcmd_emu.sv         ChipCmd with RST self-clear
  rtl8168_cfg9346_emu.sv         Cfg9346 config lock/unlock
  rtl8168_intr_emu.sv            interrupt mask/status + MSI trigger
  rtl8168_timer_emu.sv           free-running timer
  rtl8168_lfsr.sv                16-bit Galois LFSR for jitter
  pcileech_*.sv                  upstream PCILeech (see Provenance)
ip/
  pcileech_cfgspace*.coe         4 KB config space + writemask + W1C masks
  pcileech_bar_rtl8168.coe       BAR register reset values
  pcileech_bar_writemask.coe     BAR per-bit write mask
docs/REGISTERS.md                per-register map (offset/reset/mask/protocol)
```

## Resource usage (XC7A75T)

| Resource | Used | Available | % |
|---|---|---|---|
| LUT | ~12,500 | 47,200 | 26 |
| FF | ~9,500 | 94,400 | 10 |
| BRAM 36Kb | ~25 | 105 | 24 |
| GTP | 1 | 4 | 25 |

Approximate, post-implementation.

## Limitations

- MSI-X is exercised with a single vector; multi-vector delivery is untested.
- ASPM L1 is declared in LnkCap and left to the Xilinx PCIe core; the design
  does not manage L1 entry itself.
- The handshake jitter magnitudes are tuned for this board; another board may
  need different values.

## License

MIT, (c) 2025 Advit Arora. See [LICENSE](LICENSE).
