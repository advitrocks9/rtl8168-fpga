//
// RTL8168H NIC Emulation — BAR0/BAR2 Register Emulation
//
// Serves both BAR0 (I/O 256B) and BAR2 (MMIO 4KB) — both map to the same
// register space backed by bram_bar_rtl8168 (1024x32, COE-initialized).
//
// Read pipeline: 2-CLK latency (matches pcileech_bar_impl_zerowrite4k).
//   CLK 0: Issue BRAM read, register address and context into pipeline stage 1
//   CLK 1: Mux BRAM output vs state machine outputs based on registered address
//   CLK 2: rd_rsp_ctx/data/valid visible to BAR controller
//
// Write pipeline: 2-cycle read-modify-write with writemask ROM.
//   CLK 0: Issue BRAM port A read + writemask ROM read, decode state machine routes
//   CLK 1: Compute masked data, apply byte enables, write back to BRAM port A
//
// State machine intercepts: PHYAR, ChipCmd, Cfg9346, IntrMask/Status,
//   Timer, ERIAR/ERIDR, GPHY_OCP, TxPoll.
//
`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_bar_impl_rtl8168(
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
    output bit          rd_rsp_valid,
    // MSI interrupt output:
    output bit          msi_request
);

    // TODO: ASPM L1 support
    // ====================================================================
    // LFSR for timing jitter
    // ====================================================================
    wire [15:0] lfsr_val;
    rtl8168_lfsr i_lfsr(
        .clk        ( clk       ),
        .rst        ( rst       ),
        .lfsr_out   ( lfsr_val  )
    );

    // ====================================================================
    // State machine instances
    // ====================================================================

    // --- PHYAR (BAR offset 0x60, DWORD 0x018) ---
    wire        phyar_wr;
    wire [31:0] phyar_rd_data;
    wire [4:0]  ocp_phy_addr;
    wire [15:0] ocp_phy_wr_data;
    wire        ocp_phy_wr_en;
    wire [15:0] ocp_phy_rd_data;
    wire        phy_link_chg;

    rtl8168_phyar_emu i_phyar(
        .clk            ( clk               ),
        .rst            ( rst               ),
        .wr             ( phyar_wr          ),
        .wr_data        ( wr_data           ),
        .lfsr_val       ( lfsr_val          ),
        .rd_data        ( phyar_rd_data     ),
        .ocp_phy_addr   ( ocp_phy_addr      ),
        .ocp_phy_wr_data( ocp_phy_wr_data   ),
        .ocp_phy_wr_en  ( ocp_phy_wr_en     ),
        .ocp_phy_rd_data( ocp_phy_rd_data   ),
        .phy_link_chg   ( phy_link_chg      )
    );

    // --- Cfg9346 (BAR offset 0x50, DWORD 0x014 byte 0) ---
    wire        cfg9346_wr;
    wire [7:0]  cfg9346_rd_data;
    wire        config_unlock;

    rtl8168_cfg9346_emu i_cfg9346(
        .clk            ( clk               ),
        .rst            ( rst               ),
        .wr             ( cfg9346_wr        ),
        .wr_data        ( wr_data[7:0]      ),
        .rd_data        ( cfg9346_rd_data   ),
        .config_unlock  ( config_unlock     )
    );

    // --- ChipCmd (BAR offset 0x37, DWORD 0x00D byte 3) ---
    wire        chipcmd_wr;
    wire [7:0]  chipcmd_rd_data;

    rtl8168_chipcmd_emu i_chipcmd(
        .clk            ( clk               ),
        .rst            ( rst               ),
        .wr             ( chipcmd_wr        ),
        .wr_data        ( wr_data[31:24]    ),
        .rd_data        ( chipcmd_rd_data   )
    );

    // --- Interrupt Mask/Status (BAR offset 0x3C-0x3F, DWORD 0x00F) ---
    wire        intr_mask_wr;
    wire        intr_status_wr;
    wire [15:0] intr_mask_rd;
    wire [15:0] intr_status_rd;

    // LinkChg (bit 1) fires on any PHY register write
    wire [15:0] ext_intr_events = {14'd0, phy_link_chg, 1'b0};

    rtl8168_intr_emu i_intr(
        .clk            ( clk               ),
        .rst            ( rst               ),
        .mask_wr        ( intr_mask_wr      ),
        .mask_wr_data   ( wr_data[15:0]     ),
        .status_wr      ( intr_status_wr    ),
        .status_wr_data ( wr_data[31:16]    ),
        .ext_intr_set   ( ext_intr_events   ),
        .mask_rd_data   ( intr_mask_rd      ),
        .status_rd_data ( intr_status_rd    ),
        .msi_request    ( msi_request       )
    );

    // --- ERIAR/ERIDR (BAR offsets 0x74/0x70, DWORDs 0x01D/0x01C) ---
    wire        eriar_wr;
    wire        eridr_wr;
    wire [31:0] eriar_rd_data;
    wire [31:0] eridr_rd_data;

    rtl8168_eriar_emu i_eriar(
        .clk            ( clk               ),
        .rst            ( rst               ),
        .eriar_wr       ( eriar_wr          ),
        .eriar_wr_data  ( wr_data           ),
        .eridr_wr       ( eridr_wr          ),
        .eridr_wr_data  ( wr_data           ),
        .lfsr_val       ( lfsr_val          ),
        .eriar_rd_data  ( eriar_rd_data     ),
        .eridr_rd_data  ( eridr_rd_data     )
    );

    // --- GPHY_OCP (BAR offset 0xB8, DWORD 0x02E) ---
    wire        gphy_ocp_wr;
    wire [31:0] gphy_ocp_rd_data;

    rtl8168_gphy_ocp_emu i_gphy_ocp(
        .clk            ( clk               ),
        .rst            ( rst               ),
        .wr             ( gphy_ocp_wr       ),
        .wr_data        ( wr_data           ),
        .lfsr_val       ( lfsr_val          ),
        .phy_reg_addr   ( ocp_phy_addr      ),
        .phy_reg_wr_data( ocp_phy_wr_data   ),
        .phy_reg_wr_en  ( ocp_phy_wr_en     ),
        .phy_reg_rd_data( ocp_phy_rd_data   ),
        .rd_data        ( gphy_ocp_rd_data  )
    );

    // --- Timer (BAR offset 0x48, DWORD 0x012) ---
    wire [31:0] timer_rd_data;

    rtl8168_timer_emu i_timer(
        .clk            ( clk               ),
        .rst            ( rst               ),
        .rd_data        ( timer_rd_data     )
    );

    // ====================================================================
    // BRAM and Writemask ROM
    // ====================================================================
    // Port A: read-modify-write for host writes
    // Port B: read for host reads (2-CLK pipeline)

    bit [9:0]   bram_addra;
    bit [31:0]  bram_dina;
    bit         bram_ena;
    bit [3:0]   bram_wea;
    wire [31:0] bram_douta;     // port A read data (1-CLK latency)
    wire [31:0] bram_doutb;     // port B read data (1-CLK latency)

    bram_bar_rtl8168 i_bram_bar_rtl8168(
        // Port A - read-modify-write:
        .addra  ( bram_addra        ),
        .clka   ( clk               ),
        .dina   ( bram_dina         ),
        .ena    ( bram_ena          ),
        .wea    ( bram_wea          ),
        .douta  ( bram_douta        ),
        // Port B - read:
        .addrb  ( rd_req_addr[11:2] ),
        .clkb   ( clk               ),
        .doutb  ( bram_doutb        ),
        .enb    ( rd_req_valid      )
    );

    wire [31:0] writemask_data;

    drom_bar_writemask i_drom_bar_writemask(
        .addra  ( wr_addr[11:2]     ),
        .clka   ( clk               ),
        .douta  ( writemask_data    ),
        .ena    ( wr_valid          )
    );

    // ====================================================================
    // READ PIPELINE (2-CLK latency)
    // ====================================================================
    // CLK 0: BRAM port B read issued (by enb = rd_req_valid above)
    //         Register address and context
    // CLK 1: Mux BRAM output vs state machine data
    // CLK 2: Outputs visible (registered in pipeline stage 2)

    bit [87:0]  drd_req_ctx;
    bit         drd_req_valid;
    bit [9:0]   rd_addr_dw_d1;     // registered DWORD address from CLK 0

    // Read mux: combinational, evaluated at CLK 1 using registered address
    bit [31:0]  rd_mux_data;

    always @ ( * ) begin
        case ( rd_addr_dw_d1 )
            10'h00D: rd_mux_data = {chipcmd_rd_data, 24'h000000};
            10'h00E: rd_mux_data = {24'h000000, 8'hFF};                     // TxPoll always 0xFF
            10'h00F: rd_mux_data = {intr_status_rd, intr_mask_rd};
            10'h012: rd_mux_data = timer_rd_data;
            10'h014: rd_mux_data = {bram_doutb[31:24], bram_doutb[23:16], bram_doutb[15:8], cfg9346_rd_data}; // Config2/1/0 from BRAM, Cfg9346 from SM
            10'h018: rd_mux_data = phyar_rd_data;
            10'h01C: rd_mux_data = eridr_rd_data;
            10'h01D: rd_mux_data = eriar_rd_data;
            10'h02E: rd_mux_data = gphy_ocp_rd_data;
            default: rd_mux_data = bram_doutb;
        endcase
    end

    // Pipeline registers (same pattern as pcileech_bar_impl_zerowrite4k)
    always @ ( posedge clk ) begin
        // Stage 1: register context and address
        drd_req_ctx     <= rd_req_ctx;
        drd_req_valid   <= rd_req_valid;
        rd_addr_dw_d1   <= rd_req_addr[11:2];
        // Stage 2: register muxed read data and context
        rd_rsp_ctx      <= drd_req_ctx;
        rd_rsp_valid    <= drd_req_valid;
        rd_rsp_data     <= rd_mux_data;
    end

    // ====================================================================
    // WRITE PIPELINE
    // ====================================================================

    // --- Write address decode (combinational, CLK 0) ---
    wire [9:0] wr_dw_addr = wr_addr[11:2];

    wire wr_is_phyar    = wr_valid && (wr_dw_addr == 10'h018);
    wire wr_is_chipcmd  = wr_valid && (wr_dw_addr == 10'h00D) && wr_be[3];
    wire wr_is_intrmask = wr_valid && (wr_dw_addr == 10'h00F) && (wr_be[0] || wr_be[1]);
    wire wr_is_intrstat = wr_valid && (wr_dw_addr == 10'h00F) && (wr_be[2] || wr_be[3]);
    wire wr_is_cfg9346  = wr_valid && (wr_dw_addr == 10'h014) && wr_be[0];
    wire wr_is_eridr    = wr_valid && (wr_dw_addr == 10'h01C);
    wire wr_is_eriar    = wr_valid && (wr_dw_addr == 10'h01D);
    wire wr_is_gphy_ocp = wr_valid && (wr_dw_addr == 10'h02E);
    wire wr_is_txpoll   = wr_valid && (wr_dw_addr == 10'h00E) && wr_be[0];

    // State machine controlled — skip BRAM write
    wire wr_is_sm = wr_is_phyar || wr_is_chipcmd || wr_is_intrmask || wr_is_intrstat ||
                    wr_is_cfg9346 || wr_is_eridr || wr_is_eriar || wr_is_gphy_ocp || wr_is_txpoll;

    // Cfg9346-protected DWORD ranges: MAC (0x000-0x001), Config1-5 parts (0x014-0x015)
    // Only allow BRAM write if config_unlock is asserted
    wire wr_is_cfg_protected = (wr_dw_addr == 10'h000) || (wr_dw_addr == 10'h001) ||
                               (wr_dw_addr == 10'h014) || (wr_dw_addr == 10'h015);

    // A write is a regular BRAM candidate if not state-machine-controlled and
    // not config-protected (or unlocked)
    wire wr_is_regular = wr_valid && !wr_is_sm && (!wr_is_cfg_protected || config_unlock);

    // --- State machine write strobes ---
    assign phyar_wr     = wr_is_phyar;
    assign chipcmd_wr   = wr_is_chipcmd;
    assign intr_mask_wr = wr_is_intrmask;
    assign intr_status_wr = wr_is_intrstat;
    assign cfg9346_wr   = wr_is_cfg9346;
    assign eridr_wr     = wr_is_eridr;
    assign eriar_wr     = wr_is_eriar;
    assign gphy_ocp_wr  = wr_is_gphy_ocp;

    // --- BRAM read-modify-write pipeline ---
    // Cycle 0: Issue reads to BRAM port A and writemask ROM
    // Cycle 1: Compute masked data, write to BRAM port A
    // 1-deep skid buffer catches a second write arriving while pending

    bit         wr_pending = 0;
    bit [9:0]   wr_pending_addr;
    bit [3:0]   wr_pending_be;
    bit [31:0]  wr_pending_data;

    bit         wr_buf_valid = 0;
    bit [9:0]   wr_buf_addr;
    bit [3:0]   wr_buf_be;
    bit [31:0]  wr_buf_data;

    // Start a new RMW cycle from the bus or from the skid buffer
    wire wr_start = wr_is_regular && !wr_pending;

    always @ ( posedge clk ) begin
        if ( rst ) begin
            wr_pending <= 1'b0;
            wr_buf_valid <= 1'b0;
            bram_wea <= 4'h0;
            bram_ena <= 1'b0;
        end
        else begin
            // Default: no write to BRAM
            bram_wea <= 4'h0;
            bram_ena <= 1'b0;

            // Skid buffer: catch a write that arrives while RMW is pending
            if ( wr_is_regular && wr_pending && !wr_buf_valid ) begin
                wr_buf_valid <= 1'b1;
                wr_buf_addr  <= wr_dw_addr;
                wr_buf_be    <= wr_be;
                wr_buf_data  <= wr_data;
            end

            // Cycle 0: Start RMW — either from bus or by draining skid buffer
            if ( wr_start ) begin
                wr_pending      <= 1'b1;
                wr_pending_addr <= wr_dw_addr;
                wr_pending_be   <= wr_be;
                wr_pending_data <= wr_data;
                bram_addra      <= wr_dw_addr;
                bram_ena        <= 1'b1;
                bram_wea        <= 4'h0;
            end
            else if ( !wr_pending && wr_buf_valid ) begin
                wr_buf_valid    <= 1'b0;
                wr_pending      <= 1'b1;
                wr_pending_addr <= wr_buf_addr;
                wr_pending_be   <= wr_buf_be;
                wr_pending_data <= wr_buf_data;
                bram_addra      <= wr_buf_addr;
                bram_ena        <= 1'b1;
                bram_wea        <= 4'h0;
            end

            // Cycle 1: Writemask and BRAM data available, compute and write back
            if ( wr_pending ) begin
                wr_pending <= 1'b0;
                bram_addra <= wr_pending_addr;
                bram_ena   <= 1'b1;
                // Apply writemask: new = (current & ~mask) | (wr_data & mask)
                // Then apply byte enables
                bram_wea[0] <= wr_pending_be[0];
                bram_wea[1] <= wr_pending_be[1];
                bram_wea[2] <= wr_pending_be[2];
                bram_wea[3] <= wr_pending_be[3];
                bram_dina[7:0]   <= wr_pending_be[0] ?
                    ((bram_douta[7:0]   & ~writemask_data[7:0])   | (wr_pending_data[7:0]   & writemask_data[7:0]))   : bram_douta[7:0];
                bram_dina[15:8]  <= wr_pending_be[1] ?
                    ((bram_douta[15:8]  & ~writemask_data[15:8])  | (wr_pending_data[15:8]  & writemask_data[15:8]))  : bram_douta[15:8];
                bram_dina[23:16] <= wr_pending_be[2] ?
                    ((bram_douta[23:16] & ~writemask_data[23:16]) | (wr_pending_data[23:16] & writemask_data[23:16])) : bram_douta[23:16];
                bram_dina[31:24] <= wr_pending_be[3] ?
                    ((bram_douta[31:24] & ~writemask_data[31:24]) | (wr_pending_data[31:24] & writemask_data[31:24])) : bram_douta[31:24];
            end
        end
    end

endmodule
