//
// RTL8168H NIC Emulation — Interrupt Mask/Status State Machine
//
// BAR offset 0x3C (IntrMask, 16-bit RW) and 0x3E (IntrStatus, 16-bit W1C).
// USB host can inject interrupt events. Output msi_request when any
// unmasked interrupt is pending: msi_request = |(status & mask).
//
// (c) 2024-2025
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module rtl8168_intr_emu(
    input               clk,
    input               rst,
    input               mask_wr,         // IntrMask write strobe
    input  [15:0]       mask_wr_data,
    input               status_wr,       // IntrStatus write strobe (W1C)
    input  [15:0]       status_wr_data,  // bits to clear
    input  [15:0]       usb_intr_set,    // USB-injected interrupt events
    output bit [15:0]   mask_rd_data,    // IntrMask read
    output bit [15:0]   status_rd_data,  // IntrStatus read
    output bit          msi_request      // active when any unmasked interrupt pending
);

    always @ ( posedge clk ) begin
        if ( rst ) begin
            mask_rd_data <= 16'h0000;
            status_rd_data <= 16'h0000;
            msi_request <= 1'b0;
        end
        else begin
            // IntrMask: fully writable
            if ( mask_wr ) begin
                mask_rd_data <= mask_wr_data;
            end

            // IntrStatus: W1C (write-1-to-clear) + USB inject (set)
            if ( status_wr ) begin
                // Clear bits that host writes as 1, then OR in any new USB events
                status_rd_data <= (status_rd_data & ~status_wr_data) | usb_intr_set;
            end
            else begin
                // Just OR in USB-injected events
                status_rd_data <= status_rd_data | usb_intr_set;
            end

            // MSI request: any unmasked interrupt pending
            // Use next-cycle values for accurate computation
            msi_request <= |(status_rd_data & mask_rd_data);
        end
    end

endmodule
