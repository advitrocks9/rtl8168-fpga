// free-running timer counter (BAR offset 0x48)

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
