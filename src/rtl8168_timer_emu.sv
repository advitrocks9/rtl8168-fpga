//
// RTL8168H NIC Emulation — Free-Running Timer Counter (TCTR)
//
// BAR offset 0x48. 32-bit free-running counter equivalent to 125MHz.
// Since clk_pcie is 62.5MHz, increment by 2 each clock cycle.
//
// (c) 2024-2025
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module rtl8168_timer_emu(
    input               clk,
    input               rst,
    output bit [31:0]   rd_data     // TCTR value (always valid)
);

    always @ ( posedge clk ) begin
        if ( rst ) begin
            rd_data <= 32'h00000000;
        end
        else begin
            rd_data <= rd_data + 32'd2;
        end
    end

endmodule
