# RTL8168H emulated register map

Reference for the registers the `r8169` driver touches and how this build
answers them. Offsets are BAR0/BAR2 byte offsets; "DW idx" is the DWORD index
into the shared 1024x32 register BRAM. Values cross-checked against
`drivers/net/ethernet/realtek/r8169_main.c` and the COE reset files.

## BAR0 / BAR2 registers

| Register | DW idx | Byte off | Reset | Write/RO behaviour | Completion delay | Source |
|---|---|---|---|---|---|---|
| IDR0-5 (MAC) | 0x000-0x001 | 0x00-0x05 | placeholder | Cfg9346-gated write | none | `pcileech_bar_rtl8168.coe` |
| ChipCmd | 0x00D b3 | 0x37 | `0x01` | bits 7,4,3,2 writable; b0=1 forced | reset bit: 625 clk self-clear | `rtl8168_chipcmd_emu.sv` |
| TxPoll | 0x00E b0 | 0x38 | reads `0xFF` | writes accepted, no effect | none | mux in `bar_impl_rtl8168.sv` |
| IntrMask | 0x00F[15:0] | 0x3C | `0x0000` | fully writable | none | `rtl8168_intr_emu.sv` |
| IntrStatus | 0x00F[31:16] | 0x3E | `0x0000` | write-1-to-clear | none | `rtl8168_intr_emu.sv` |
| TxConfig | 0x010 | 0x40 | `0x54100780` | XID bits RO (writemask `0x03000780`) | none | `pcileech_bar_rtl8168.coe` |
| TCTR (timer) | 0x012 | 0x48 | `0x00000000` | RO, free-running +2/clk | none | `rtl8168_timer_emu.sv` |
| Cfg9346 | 0x014 b0 | 0x50 | `0x00` | unlock when write[7:6]=`11` (`0xC0`) | none | `rtl8168_cfg9346_emu.sv` |
| Config0/1/2 | 0x014 b1-3 | 0x51-0x53 | `00/00/80` | Cfg9346-gated | none | mux + BRAM |
| PHYAR | 0x018 | 0x60 | `0x00000000` | flag-poll bit31; reg=[20:16] data=[15:0] | 1200-1300 clk (~20 us) | `rtl8168_phyar_emu.sv` |
| ERIDR | 0x01C | 0x70 | `0x00000000` | host pre-loads data | loaded by ERIAR | `rtl8168_eriar_emu.sv` |
| ERIAR | 0x01D | 0x74 | `0x00000000` | flag-poll bit31; idx=[7:2] BE=[15:12] | 200-263 clk (~3-4 us) | `rtl8168_eriar_emu.sv` |
| GPHY_OCP | 0x02E | 0xB8 | `0x00000000` | flag-poll bit31 (see bug note) | 1200-1300 clk | `rtl8168_gphy_ocp_emu.sv` |
| CPlusCmd | 0x038[15:0] | 0xE0 | `0x2060` | writemask `0x2063` | none | BRAM |

Anything not listed is plain read/write storage in the BRAM, masked by
`pcileech_bar_writemask.coe`.

## PHY register file (32x16, shared by PHYAR and GPHY_OCP)

| Idx | Reg | Reset | RO |
|---|---|---|---|
| 0 | BMCR | `0x1140` | |
| 1 | BMSR | `0x7949` | RO |
| 2 | PHYID1 | `0x001C` | RO |
| 3 | PHYID2 | `0xC912` | RO |
| 4 | ANAR | `0x05E1` | |
| 5 | ANLPAR | `0x0000` | RO |
| 6 | ANER | `0x0004` | RO |
| 9 | GBCR | `0x0200` | |
| 10 | GBSR | `0x0000` | RO |
| 15 | GBESR | `0x3000` | RO |

`PHYstatus` reads `0x00` (no link), consistent with a card that has no cable
attached, which is what this device is.

## Configuration space (4 KB shadow, `pcileech_cfgspace.coe`)

Type-0 header:

| Off | Field | Value |
|---|---|---|
| 0x00 | VID / DID | `10EC` / `8168` |
| 0x08 | Class / Rev | `020000` / `15` |
| 0x10 | BAR0 | `0000E001` (I/O, 256 B) |
| 0x18 | BAR2 | `0000F004` (Mem64, 4 KB) |
| 0x20 | BAR4 | `0000C004` (Mem64, 16 KB) |
| 0x2C | SVID / SSID | `1458` / `E000` |
| 0x34 | Cap pointer | `0x40` |

Standard capability chain (offset, ID, next):

```
PM    0x40  id 01  next 0x50   PMC 0xC803  (see fidelity note: D1/D2 off)
MSI   0x50  id 05  next 0x70   64-bit, Count 1/1
PCIe  0x70  id 10  next 0xB0   Express v2 Endpoint
MSI-X 0xB0  id 11  next 0xD0   4 vectors, table BIR4@0x000, PBA BIR4@0x800
VPD   0xD0  id 03  next 0x00
```

Extended capability chain (offset, ID, next):

```
AER   0x100  id 0001  next 0x140
VC    0x140  id 0002  next 0x160
DSN   0x160  id 0003  next 0x170   (per-unit, set before use)
LTR   0x170  id 0018  next 0x178
L1SS  0x178  id 001E  next 0x000
```

The chain placement and next-pointers match a real RTL8168H. Field-level
divergences (LnkCap Gen2/x8, DevCap MPS, PM D1/D2, ext-cap version nibbles, DSN
placeholder) are listed under "Known issues" in the [README](../README.md).
