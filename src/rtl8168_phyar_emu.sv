//
// RTL8168H NIC Emulation — PHY Access Register (PHYAR) State Machine
//
// BAR offset 0x60. Implements flag-polling protocol for PHY register access.
// Contains 32x16-bit PHY register file shared with GPHY_OCP module.
// Write (bit31=1): capture reg/data, update file, clear bit31 after delay.
// Read (bit31=0): look up value, set bit31 after delay, place data in [15:0].
// Delay: 1200 + (lfsr_val[6:0] % 101) cycles (~1200-1300, base 20us @ 62.5MHz).
//
// (c) 2024-2025
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

`define PHYAR_IDLE      2'b00
`define PHYAR_BUSY      2'b01

module rtl8168_phyar_emu(
    input               clk,
    input               rst,
    input               wr,          // write strobe
    input  [31:0]       wr_data,     // PHYAR write data
    input  [15:0]       lfsr_val,    // from LFSR module for jitter
    output bit [31:0]   rd_data,     // PHYAR read data (always valid)
    // Shared PHY register file access from GPHY_OCP
    input  [4:0]        ocp_phy_addr,
    input  [15:0]       ocp_phy_wr_data,
    input               ocp_phy_wr_en,
    output bit [15:0]   ocp_phy_rd_data
);

    // PHY register file: 32 x 16-bit
    bit [15:0] phy_regs [0:31];

    // RO mask: 1 = read-only (writes ignored)
    // RO regs: 1 (BMSR), 2 (PHYID1), 3 (PHYID2), 5 (ANLPAR), 6 (ANER),
    //          8 (ANNPRR), 10 (GBSR), 11-15 (reserved/GBESR)
    bit phy_ro [0:31];

    // State machine
    bit [1:0]   state = `PHYAR_IDLE;
    bit [10:0]  delay_cnt = 0;      // max ~1300 -> 11 bits
    bit         is_write = 0;       // 1=write op, 0=read op
    bit [4:0]   pending_reg = 0;
    bit [15:0]  pending_data = 0;

    // Jitter calculation: 1200 + (lfsr_val[6:0] % 101)
    // Since modulo is expensive in hardware, approximate with: 1200 + lfsr_val[6:0]
    // lfsr_val[6:0] range is 0-127, but we cap at 100 for 1200-1300 range
    wire [6:0] jitter_raw = lfsr_val[6:0];
    wire [10:0] delay_target = 11'd1200 + ((jitter_raw > 7'd100) ? 11'd100 : {4'd0, jitter_raw});

    // OCP read port: combinational lookup
    always @ ( posedge clk ) begin
        ocp_phy_rd_data <= phy_regs[ocp_phy_addr];
    end

    integer i;
    always @ ( posedge clk ) begin
        if ( rst ) begin
            // Initialize PHY register file
            for ( i = 0; i < 32; i = i + 1 ) begin
                phy_regs[i] <= 16'h0000;
            end
            phy_regs[0]  <= 16'h1140;  // BMCR
            phy_regs[1]  <= 16'h7949;  // BMSR
            phy_regs[2]  <= 16'h001C;  // PHYID1
            phy_regs[3]  <= 16'hC912;  // PHYID2
            phy_regs[4]  <= 16'h05E1;  // ANAR
            phy_regs[5]  <= 16'h0000;  // ANLPAR
            phy_regs[6]  <= 16'h0004;  // ANER
            phy_regs[7]  <= 16'h2001;  // ANNPTR
            phy_regs[8]  <= 16'h0000;  // ANNPRR
            phy_regs[9]  <= 16'h0200;  // GBCR
            phy_regs[10] <= 16'h0000;  // GBSR
            phy_regs[15] <= 16'h3000;  // GBESR
            phy_regs[31] <= 16'h0000;  // PageSel

            // Initialize RO flags
            for ( i = 0; i < 32; i = i + 1 ) begin
                phy_ro[i] <= 1'b0;
            end
            phy_ro[1]  <= 1'b1;  // BMSR
            phy_ro[2]  <= 1'b1;  // PHYID1
            phy_ro[3]  <= 1'b1;  // PHYID2
            phy_ro[5]  <= 1'b1;  // ANLPAR
            phy_ro[6]  <= 1'b1;  // ANER
            phy_ro[8]  <= 1'b1;  // ANNPRR
            phy_ro[10] <= 1'b1;  // GBSR
            phy_ro[11] <= 1'b1;  // reserved
            phy_ro[12] <= 1'b1;  // reserved
            phy_ro[13] <= 1'b1;  // reserved
            phy_ro[14] <= 1'b1;  // reserved
            phy_ro[15] <= 1'b1;  // GBESR

            rd_data <= 32'h00000000;
            state <= `PHYAR_IDLE;
            delay_cnt <= 11'd0;
            is_write <= 1'b0;
            pending_reg <= 5'd0;
            pending_data <= 16'h0000;
        end
        else begin
            // Handle OCP writes to shared PHY register file
            if ( ocp_phy_wr_en && !phy_ro[ocp_phy_addr] ) begin
                phy_regs[ocp_phy_addr] <= ocp_phy_wr_data;
            end

            case ( state )
                `PHYAR_IDLE: begin
                    if ( wr ) begin
                        if ( wr_data[31] ) begin
                            // PHY Write: bit31=1, reg=[20:16], data=[15:0]
                            is_write <= 1'b1;
                            pending_reg <= wr_data[20:16];
                            pending_data <= wr_data[15:0];
                            // Update PHY file immediately (if not RO)
                            if ( !phy_ro[wr_data[20:16]] ) begin
                                phy_regs[wr_data[20:16]] <= wr_data[15:0];
                            end
                            // Set bit31 in rd_data (busy/written)
                            rd_data <= wr_data;
                            delay_cnt <= delay_target;
                            state <= `PHYAR_BUSY;
                        end
                        else begin
                            // PHY Read: bit31=0, reg=[20:16]
                            is_write <= 1'b0;
                            pending_reg <= wr_data[20:16];
                            // Clear bit31, keep reg field
                            rd_data <= {1'b0, wr_data[30:0]};
                            delay_cnt <= delay_target;
                            state <= `PHYAR_BUSY;
                        end
                    end
                end
                `PHYAR_BUSY: begin
                    if ( delay_cnt == 11'd0 ) begin
                        if ( is_write ) begin
                            // Write complete: clear bit 31
                            rd_data[31] <= 1'b0;
                        end
                        else begin
                            // Read complete: set bit 31, place data in [15:0]
                            rd_data <= {1'b1, 10'd0, pending_reg, phy_regs[pending_reg]};
                        end
                        state <= `PHYAR_IDLE;
                    end
                    else begin
                        delay_cnt <= delay_cnt - 11'd1;
                    end
                end
                default: begin
                    state <= `PHYAR_IDLE;
                end
            endcase
        end
    end

endmodule
