//
// RTL8168H NIC Emulation — GPHY OCP PHY Access State Machine
//
// BAR offset 0xB8. RTL8168G+ uses OCP addressing for PHY access instead of PHYAR.
// Maps OCP addresses to shared PHY register file: PHY_reg = (OCP_addr - 0xA400) / 2.
// Same flag-polling protocol as PHYAR.
//
// GPHY_OCP bits: [31]=Flag, [30:16]=Addr(15-bit), [15:0]=Data
// Driver writes: (OCPAR_FLAG | (ocp_addr << 16) | data) for writes
//                (ocp_addr << 16) for reads
// Since ocp_addr=0xA400+reg*2, bits[30:16] = lower 15 bits = 0x2400+reg*2.
// PHY_reg = (bits[30:16] - 0x2400) / 2 = bits[21:17] - 0x12.
//
// Delay: 1200 + (lfsr_val[6:0] capped at 100) cycles.
//
// (c) 2024-2025
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

`define GPHY_IDLE       2'b00
`define GPHY_BUSY       2'b01

module rtl8168_gphy_ocp_emu(
    input               clk,
    input               rst,
    input               wr,
    input  [31:0]       wr_data,
    input  [15:0]       lfsr_val,
    // Shared PHY register file (32 x 16-bit) — connects to rtl8168_phyar_emu
    output bit [4:0]    phy_reg_addr,
    output bit [15:0]   phy_reg_wr_data,
    output bit          phy_reg_wr_en,
    input  [15:0]       phy_reg_rd_data,
    output bit [31:0]   rd_data
);

    // State machine
    bit [1:0]   state = `GPHY_IDLE;
    bit [10:0]  delay_cnt = 0;
    bit         is_write = 0;
    bit [4:0]   pending_reg = 0;
    bit [14:0]  pending_ocp_addr = 0;

    // Jitter: same as PHYAR — 1200 + (lfsr[6:0] capped at 100)
    wire [6:0] jitter_raw = lfsr_val[6:0];
    wire [10:0] delay_target = 11'd1200 + ((jitter_raw > 7'd100) ? 11'd100 : {4'd0, jitter_raw});

    // OCP address to PHY register mapping:
    // Driver uses OCP_STD_PHY_BASE=0xA400 + reg*2, shifted left 16 -> bits[30:16] = 0x2400 + reg*2
    // PHY_reg = (wr_data[30:16] - 15'h2400) >> 1
    // Simplified: the reg index is (wr_data[21:17] - 5'h12) since 0x2400>>1 = 0x1200, bits[21:17] = addr[5:1]+base
    // Even simpler: offset = wr_data[30:16] - 15'h2400, phy_reg = offset[5:1]
    wire [14:0] ocp_addr_in   = wr_data[30:16];
    wire [14:0] ocp_offset    = ocp_addr_in - 15'h2400;
    wire [4:0]  mapped_reg_in = ocp_offset[5:1];

    always @ ( posedge clk ) begin
        if ( rst ) begin
            rd_data <= 32'h00000000;
            state <= `GPHY_IDLE;
            delay_cnt <= 11'd0;
            is_write <= 1'b0;
            pending_reg <= 5'd0;
            pending_ocp_addr <= 15'd0;
            phy_reg_addr <= 5'd0;
            phy_reg_wr_data <= 16'h0000;
            phy_reg_wr_en <= 1'b0;
        end
        else begin
            // Default: deassert write enable
            phy_reg_wr_en <= 1'b0;

            case ( state )
                `GPHY_IDLE: begin
                    if ( wr ) begin
                        pending_ocp_addr <= ocp_addr_in;
                        pending_reg <= mapped_reg_in;

                        if ( wr_data[31] ) begin
                            // OCP Write: Flag=1
                            is_write <= 1'b1;
                            rd_data <= wr_data;
                            // Write to shared PHY register file
                            phy_reg_addr <= mapped_reg_in;
                            phy_reg_wr_data <= wr_data[15:0];
                            phy_reg_wr_en <= 1'b1;
                            delay_cnt <= delay_target;
                            state <= `GPHY_BUSY;
                        end
                        else begin
                            // OCP Read: Flag=0
                            is_write <= 1'b0;
                            rd_data <= {1'b0, wr_data[30:0]};
                            // Set up read address on shared PHY file
                            phy_reg_addr <= mapped_reg_in;
                            delay_cnt <= delay_target;
                            state <= `GPHY_BUSY;
                        end
                    end
                end
                `GPHY_BUSY: begin
                    // Keep read address stable for PHY file lookup
                    phy_reg_addr <= pending_reg;

                    if ( delay_cnt == 11'd0 ) begin
                        if ( is_write ) begin
                            // Write complete: clear Flag
                            rd_data[31] <= 1'b0;
                        end
                        else begin
                            // Read complete: set Flag, place PHY data in [15:0]
                            rd_data <= {1'b1, pending_ocp_addr, phy_reg_rd_data};
                        end
                        state <= `GPHY_IDLE;
                    end
                    else begin
                        delay_cnt <= delay_cnt - 11'd1;
                    end
                end
                default: begin
                    state <= `GPHY_IDLE;
                end
            endcase
        end
    end

endmodule
