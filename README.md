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
| Config space | 4 KB shadow BRAM; std caps PM, MSI, PCIe, MSI-X, VPD; ext caps AER, VC, DSN, LTR, L1SS; per-bit writemask + W1C masks |
| BAR0 / BAR2 | I/O 256 B / MMIO 4 KB, shared register file, RMW behind writemask, Cfg9346-gated MAC/Config writes |
| BAR4 | 16 KB MSI-X table (4 vectors) + PBA backing store |
| State machines | PHYAR, GPHY_OCP, ERIAR/ERIDR, ChipCmd (reset self-clear), Cfg9346 (lock), IntrMask/Status (W1C), free-running timer |
| Timing | LFSR-jittered completion delays on the polling handshakes |

## Verification status

I want to be precise here, because "passes the driver probe" is easy to assert
and hard to earn.

- **Cross-checked against primary sources (done).** Every config-space DWORD,
  register offset, and handshake protocol in this repo was checked against the
  live `r8169_main.c` source and against real `lspci -nnvvxxx` dumps of
  `10ec:8168` cards. The identity, BAR sizing, capability offsets/order, MSI
  and MSI-X fields, and the PHYAR/ERIAR/GPHY_OCP/Cfg9346/ChipCmd protocols all
  match. Those checks are what the table above and the register doc rest on.
- **Not yet done: live bring-up.** No real hardware has had the `r8169` driver
  bind against this build. There is no `dmesg` or `lspci` capture from a
  programmed card in this repo, and `rtl8168_phyar_emu.sv:48` still carries a
  `TODO: test with actual r8169 driver on 6.x kernel`. Read the probe claim as
  a design target, not a measured result.
- **Resource numbers are estimates.** The utilisation table below is a
  pre-bring-up estimate; no Vivado utilisation or timing report is committed.

## Known issues and fidelity gaps

Found during a source-level audit and documented rather than silently patched.
Some are correctness bugs; some are places where the counterfeit diverges from
a real RTL8168H, i.e. detectable tells.

**Functional bugs**

- **GPHY_OCP address decode is wrong** (`rtl8168_gphy_ocp_emu.sv:52-54`). The
  driver issues `RTL_W32(GPHY_OCP, OCPAR_FLAG | (reg << 15) | data)` with
  `reg = 0xA400 + phy_reg*2`, so the PHY register lands in
  `bits[30:16] = 0x5200 + phy_reg`. The code assumes `addr << 16`, subtracts
  `0x2400`, then shifts, which is correct only for register 0; every other OCP
  access maps to the wrong PHY register.
- **Back-to-back BAR writes can be dropped** (`pcileech_bar_impl_rtl8168.sv:273`).
  The read-modify-write takes two cycles and is gated on `!wr_pending` with no
  backpressure to the write engine, so a second write arriving on the next
  cycle (for example a multi-DWORD burst) is lost. Single-DWORD register
  writes, the common probe path, are unaffected.
- **The device never raises an interrupt** (`rtl8168_intr_emu.sv:41`,
  `pcileech_bar_impl_rtl8168.sv:117`). IntrStatus can only be set from
  `usb_intr_set`, which is tied to `0`, so `msi_request` is permanently low.
  The MSI plumbing and the rising-edge `cfg_interrupt` handshake are correct
  but have no live source. That is fine for a link-less card that generates no
  traffic, but the path is cosmetic as built, and the advertised MSI-X table
  (BAR4) is passive storage that nothing emits TLPs from.

**Config-space tells (diverge from a real RTL8168H)**

- **LnkCap advertises Gen2 / x8** (`pcileech_cfgspace.coe`, LnkCap `0x00015C82`).
  A real RTL8168H is Gen1 (2.5 GT/s) x1, and this build's own LnkSta already
  reads Gen1 x1, so LnkCap is both inaccurate and self-inconsistent.
- **DevCap MaxPayload 256 B** where the real chip reports 128 B.
- **PM capability** declares no D1/D2 and 0 mA aux current in the COE
  (`PMC = 0xC803`), while a real RTL8168H reports `D1+ D2+ AuxCurrent=375mA`.
- **Extended-capability version nibbles** are malformed: VC/DSN carry version
  2/3 and LTR/L1SS carry version 0 instead of 1 (a running counter was packed
  into the version field). Version 0 is invalid.
- **Device Serial Number** in the COE is a placeholder that doesn't decode to a
  valid EUI-64 and disagrees with the runtime DSN in `pcileech_pcie_cfg_a7.sv`
  and the derivation in [BUILD.md](BUILD.md). Set it per-unit before use.

**Smaller items**

- ERI register file indexes only `addr[7:2]` (64 entries), so the driver's
  >8-bit ERI addresses alias.
- The PHY ID `001C:C912` decodes to an RTL8211B model number; the `r8169` 8168H
  path doesn't read the internal PHY ID, so this has no functional effect.
- The PHYAR/OCP jitter is a clamp, not the modulo its comment claims, so the
  delay distribution piles up at the maximum.
- The README's old "no ASPM L1 support" note contradicted L1 being declared in
  LnkCap; L1 is declared and handled by the Xilinx core, L1 PM Substates are
  declared in the ext-cap chain but not independently exercised.

## Key values

| Field | Value |
|---|---|
| VID / DID | `10EC` / `8168` |
| RevID | `0x15` |
| SVID / SSID | `1458` / `E000` (Gigabyte) |
| XID | `0x541`, maps to `RTL_GIGA_MAC_VER_46` (RTL8168h/8111h) |
| TxConfig | `0x54100780` |
| PHY ID | `001C:C912` |
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

## Resource usage (XC7A75T, estimate)

| Resource | Used | Available | % |
|---|---|---|---|
| LUT | ~12,500 | 47,200 | 26 |
| FF | ~9,500 | 94,400 | 10 |
| BRAM 36Kb | ~25 | 105 | 24 |
| GTP | 1 | 4 | 25 |

Pre-bring-up estimate; no committed utilisation report.

## Provenance and attribution

`fb47c2a` imports the stock upstream EnigmaX1 source set unchanged; everything
RTL8168-specific is committed on top. Upstream files keep their
`(c) Ulf Frisk` header and are byte-identical to that baseline; the four
modified upstream files (`pcileech_fifo.sv`, `pcileech_pcie_a7.sv`,
`pcileech_pcie_tlp_a7.sv`, `pcileech_pcie_cfg_a7.sv`) carry only the ID/MSI/DSN
rewiring described above. The `rtl8168_*` modules, `pcileech_bar_impl_*`, and
the COE files are new. See [NOTICE](NOTICE).

## License

The upstream PCILeech-FPGA files are `(c) Ulf Frisk` and are used under their
original terms (the upstream project ships no separate license file). The new
files added in this fork are MIT, (c) 2025 Advit Arora. See [LICENSE](LICENSE)
and [NOTICE](NOTICE) for the file-by-file split; the project as a whole is a
derivative work and is **not** uniformly MIT.

Based on [ufrisk/pcileech-fpga](https://github.com/ufrisk/pcileech-fpga/) by Ulf Frisk.
