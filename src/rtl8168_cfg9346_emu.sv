// cfg9346 config lock/unlock

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module rtl8168_cfg9346_emu(
    input               clk,
    input               rst,
    input               wr,
    input  [7:0]        wr_data,
    output bit [7:0]    rd_data,
    output bit          config_unlock   // 1=unlocked, 0=locked
);

    always @ ( posedge clk ) begin
        if ( rst ) begin
            rd_data <= 8'h00;
            config_unlock <= 1'b0;
        end
        else if ( wr ) begin
            rd_data <= wr_data;
            // Unlock only when bits[7:6] == 2'b11
            config_unlock <= (wr_data[7:6] == 2'b11) ? 1'b1 : 1'b0;
        end
    end

endmodule
