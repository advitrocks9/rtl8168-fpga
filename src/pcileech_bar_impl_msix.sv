//
// RTL8168H NIC Emulation — BAR4 MSI-X Table/PBA Implementation
//
// BAR4 is a 16KB MMIO region containing:
//   - MSI-X table (4 entries x 16 bytes at offset 0x000)
//   - PBA (8 bytes at offset 0x800)
// Backed by bram_bar4_msix (4096x32, zero-initialized).
// Host programs MSI-X table entries during driver init.
//
// Latency = 2CLKs (matches pcileech_bar_impl_zerowrite4k).
//
// (c) 2024-2025
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_bar_impl_msix(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    bit [87:0]  drd_req_ctx;
    bit         drd_req_valid;
    wire [31:0] doutb;

    always @ ( posedge clk ) begin
        drd_req_ctx     <= rd_req_ctx;
        drd_req_valid   <= rd_req_valid;
        rd_rsp_ctx      <= drd_req_ctx;
        rd_rsp_valid    <= drd_req_valid;
        rd_rsp_data     <= doutb;
    end

    bram_bar4_msix i_bram_bar4_msix(
        // Port A - write:
        .addra  ( wr_addr[13:2]     ),
        .clka   ( clk               ),
        .dina   ( wr_data           ),
        .ena    ( wr_valid          ),
        .wea    ( wr_be             ),
        // Port B - read (2 CLK latency):
        .addrb  ( rd_req_addr[13:2] ),
        .clkb   ( clk               ),
        .doutb  ( doutb             ),
        .enb    ( rd_req_valid      )
    );

endmodule
