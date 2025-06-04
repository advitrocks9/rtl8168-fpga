//
// RTL8168H NIC Emulation — ERI Access State Machine (ERIAR/ERIDR)
//
// BAR offsets: ERIDR (0x70, 32-bit data), ERIAR (0x74, control/address).
// Same flag-polling protocol as PHYAR. Internal 64x32-bit register file.
// ERIAR bits: [31]=Flag, [17:16]=Type, [15:12]=ByteEnable, [11:0]=Addr.
// Delay: 200 + lfsr_val[5:0] cycles (200-263 range).
//
// Write: host pre-loads ERIDR, then writes ERIAR with Flag=1. FPGA stores
//        ERIDR data into internal reg at Addr. Clears Flag after delay.
// Read:  host writes ERIAR with Flag=0. FPGA looks up data, sets Flag
//        and loads result into ERIDR after delay.
//
`timescale 1ns / 1ps
`include "pcileech_header.svh"

`define ERIAR_IDLE      2'b00
`define ERIAR_BUSY      2'b01

module rtl8168_eriar_emu(
    input               clk,
    input               rst,
    input               eriar_wr,        // ERIAR write strobe
    input  [31:0]       eriar_wr_data,
    input               eridr_wr,        // ERIDR write strobe (host pre-loads data)
    input  [31:0]       eridr_wr_data,
    input  [15:0]       lfsr_val,
    output bit [31:0]   eriar_rd_data,   // ERIAR read
    output bit [31:0]   eridr_rd_data    // ERIDR read
);

    // Internal ERI register file: 64 x 32-bit
    // Address mapping: ERIAR[11:0] is byte address, 4-byte aligned
    // -> register index = ERIAR[7:2] (6 bits -> 64 entries)
    bit [31:0] eri_regs [0:63];

    // State machine
    bit [1:0]   state = `ERIAR_IDLE;
    bit [7:0]   delay_cnt = 0;      // max ~263 -> 8 bits
    bit         is_write = 0;
    bit [5:0]   pending_idx = 0;
    bit [3:0]   pending_be = 0;

    // Jitter: 200 + lfsr_val[5:0] -> range 200-263
    // FIXME: eeprom emulation is read-only, may need write support later
    wire [7:0] delay_target = 8'd200 + {2'd0, lfsr_val[5:0]};

    integer i;
    always @ ( posedge clk ) begin
        if ( rst ) begin
            for ( i = 0; i < 64; i = i + 1 ) begin
                eri_regs[i] <= 32'h00000000;
            end
            eriar_rd_data <= 32'h00000000;
            eridr_rd_data <= 32'h00000000;
            state <= `ERIAR_IDLE;
            delay_cnt <= 8'd0;
            is_write <= 1'b0;
            pending_idx <= 6'd0;
            pending_be <= 4'h0;
        end
        else begin
            // ERIDR write: host pre-loads data register
            if ( eridr_wr ) begin
                eridr_rd_data <= eridr_wr_data;
            end

            case ( state )
                `ERIAR_IDLE: begin
                    if ( eriar_wr ) begin
                        if ( eriar_wr_data[31] ) begin
                            // ERI Write: Flag=1
                            is_write <= 1'b1;
                            pending_idx <= eriar_wr_data[7:2];
                            pending_be <= eriar_wr_data[15:12];
                            // Apply byte-enable masked write from ERIDR
                            if ( eriar_wr_data[15] ) begin
                                eri_regs[eriar_wr_data[7:2]][31:24] <= eridr_rd_data[31:24];
                            end
                            if ( eriar_wr_data[14] ) begin
                                eri_regs[eriar_wr_data[7:2]][23:16] <= eridr_rd_data[23:16];
                            end
                            if ( eriar_wr_data[13] ) begin
                                eri_regs[eriar_wr_data[7:2]][15:8] <= eridr_rd_data[15:8];
                            end
                            if ( eriar_wr_data[12] ) begin
                                eri_regs[eriar_wr_data[7:2]][7:0] <= eridr_rd_data[7:0];
                            end
                            eriar_rd_data <= eriar_wr_data;
                            delay_cnt <= delay_target;
                            state <= `ERIAR_BUSY;
                        end
                        else begin
                            // ERI Read: Flag=0
                            is_write <= 1'b0;
                            pending_idx <= eriar_wr_data[7:2];
                            pending_be <= eriar_wr_data[15:12];
                            eriar_rd_data <= {1'b0, eriar_wr_data[30:0]};
                            delay_cnt <= delay_target;
                            state <= `ERIAR_BUSY;
                        end
                    end
                end
                `ERIAR_BUSY: begin
                    if ( delay_cnt == 8'd0 ) begin
                        if ( is_write ) begin
                            // Write complete: clear Flag
                            eriar_rd_data[31] <= 1'b0;
                        end
                        else begin
                            // Read complete: set Flag, load data into ERIDR
                            eriar_rd_data[31] <= 1'b1;
                            eridr_rd_data <= eri_regs[pending_idx];
                        end
                        state <= `ERIAR_IDLE;
                    end
                    else begin
                        delay_cnt <= delay_cnt - 8'd1;
                    end
                end
                default: begin
                    state <= `ERIAR_IDLE;
                end
            endcase
        end
    end

endmodule
