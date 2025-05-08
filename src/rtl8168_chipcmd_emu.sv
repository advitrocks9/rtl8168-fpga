//
// RTL8168H NIC Emulation — ChipCmd Command Register State Machine
//
// BAR offset 0x37. Writable bits: 7 (StopReq), 4 (CmdReset), 3 (CmdRxEnb), 2 (CmdTxEnb).
// Bit 0 (RxBufEmpty) always 1 after reset. When CmdReset written: 625-cycle countdown,
// then clear bits[4:2] and set bit 0. Post-reset value: 0x01.
//
// (c) 2024-2025
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

`define CHIPCMD_IDLE    2'b00
`define CHIPCMD_RESET   2'b01

module rtl8168_chipcmd_emu(
    input               clk,
    input               rst,
    input               wr,
    input  [7:0]        wr_data,
    output bit [7:0]    rd_data
);

    bit [1:0]   state = `CHIPCMD_IDLE;
    bit [9:0]   reset_cnt = 0;      // 625 cycles max -> 10 bits

    always @ ( posedge clk ) begin
        if ( rst ) begin
            rd_data <= 8'h01;       // RxBufEmpty = 1
            state <= `CHIPCMD_IDLE;
            reset_cnt <= 10'd0;
        end
        else begin
            case ( state )
                `CHIPCMD_IDLE: begin
                    if ( wr ) begin
                        // Writable bits: 7, 4, 3, 2. Bit 0 always 1.
                        rd_data[7] <= wr_data[7];
                        rd_data[6:5] <= 2'b00;
                        rd_data[4] <= wr_data[4];
                        rd_data[3] <= wr_data[3];
                        rd_data[2] <= wr_data[2];
                        rd_data[1] <= 1'b0;
                        rd_data[0] <= 1'b1;
                        // If CmdReset written, start countdown
                        if ( wr_data[4] ) begin
                            state <= `CHIPCMD_RESET;
                            reset_cnt <= 10'd625;
                        end
                    end
                end
                `CHIPCMD_RESET: begin
                    if ( reset_cnt == 10'd0 ) begin
                        // Reset complete: clear RST, RE, TE; set RxBufEmpty
                        rd_data[4:2] <= 3'b000;
                        rd_data[0] <= 1'b1;
                        state <= `CHIPCMD_IDLE;
                    end
                    else begin
                        reset_cnt <= reset_cnt - 10'd1;
                    end
                end
                default: begin
                    state <= `CHIPCMD_IDLE;
                end
            endcase
        end
    end

endmodule
