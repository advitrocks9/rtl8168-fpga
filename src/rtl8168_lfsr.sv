// 16-bit Galois LFSR for timing jitter

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module rtl8168_lfsr(
    input               clk,
    input               rst,
    output bit [15:0]   lfsr_out     // pseudo-random value, updates every CLK
);

    bit [15:0] lfsr = 16'hACE1;    // non-zero seed
    // FIXME: jitter cap may need tuning per-board

    always @ ( posedge clk ) begin
        if ( rst ) begin
            lfsr <= 16'hACE1;
        end
        else begin
            // Galois LFSR: x^16 + x^15 + x^13 + x^4 + 1
            lfsr[15] <= lfsr[0];
            lfsr[14] <= lfsr[15] ^ lfsr[0];    // tap at bit 15
            lfsr[13] <= lfsr[14];
            lfsr[12] <= lfsr[13] ^ lfsr[0];    // tap at bit 13
            lfsr[11] <= lfsr[12];
            lfsr[10] <= lfsr[11];
            lfsr[9]  <= lfsr[10];
            lfsr[8]  <= lfsr[9];
            lfsr[7]  <= lfsr[8];
            lfsr[6]  <= lfsr[7];
            lfsr[5]  <= lfsr[6];
            lfsr[4]  <= lfsr[5];
            lfsr[3]  <= lfsr[4] ^ lfsr[0];     // tap at bit 4
            lfsr[2]  <= lfsr[3];
            lfsr[1]  <= lfsr[2];
            lfsr[0]  <= lfsr[1];
        end
    end

    assign lfsr_out = lfsr;

endmodule
