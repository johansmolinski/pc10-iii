// pc_system.sv - the PC: clocks, 8088, system board and the cards.
// Ports: doc/architecture.md section 4.
//
// GPL-3.0-or-later, pc10-iii.

module pc_system #(
    parameter int RAM_KB  = 640,
    // fitted video cards (doc/architecture.md section 4, doc/mda.md section 7)
    parameter bit CGA_FIT = 1'b1,       // IBM CGA at B8000-BFFFF, 3D0-3DF
    parameter bit CGA_SNOW = 1'b1,      // the IBM CGA's 80-column snow (cga_card SNOW)
    parameter int MDA_FIT = 0,          // 0 none, 1 IBM MDA, 2 Hercules (B0000, 3B0-3BF)
    parameter int DRQ0_SKEW = 0,        // simulation only (xt_board)
    // the PC10-III's onboard video, the Paradise PVC4 (doc/pvc4.md), and its
    // Commodore configuration register 230h; the CGA/MDA parameters above are
    // then expansion cards (0 for the PC10-III as built). The vid_* outputs
    // come from the PVC4.
    parameter bit PVC4_FIT = 1'b0,
    // the PC20-III's hard disk on CN202 (rtl/hdc/xta_card.sv, doc/xta.md):
    // 0 = not built (the PC10-III), 1 = the drive's connector and logic exist;
    // xta_enable is then JMP208
    parameter bit XTA_FIT = 1'b0
) (
    input  logic        clk,
    input  logic        reset,
    // the chipset (xt_board): 1 = the PC10-III's FE2010A port logic, 0 = IBM
    // 5160 (8255); taken while reset is high
    input  logic        fe2010a,

    // the 8088's microcode bundle (tools/mkucode.py, doc/z8086.md): the file,
    // one byte per clk at offset ucl_addr, while reset is high
    input  logic        ucl_we,
    input  logic [12:0] ucl_addr,
    input  logic [7:0]  ucl_data,

    output logic [19:0] ram_addr,
    output logic        ram_en,
    output logic        ram_we,
    output logic [7:0]  ram_wdata,
    input  logic [7:0]  ram_rdata,
    input  logic        ram_ack,

    output logic [15:0] rom_addr,
    input  logic [7:0]  rom_rdata,

    output logic        vid_ce,
    output logic [3:0]  vid_rgbi,
    output logic        vid_hsync,
    output logic        vid_vsync,
    output logic        vid_hblank,
    output logic        vid_vblank,

    // MDA / Hercules video (MDA_FIT != 0): one dot per mda_ce (16.257 MHz,
    // Hercules 16.000 MHz, on average); 720x350 at 18.43 kHz / 49.8 Hz
    output logic        mda_ce,
    output logic        mda_video,
    output logic        mda_intens,
    output logic        mda_hsync,
    output logic        mda_vsync,
    output logic        mda_hblank,
    output logic        mda_vblank,

    // character ROM, loaded by the glue (8 KB, IBM 5788005 layout): the CGA
    // uses 0x1000-0x1FFF, the MDA 0x0000-0x0FFF
    input  logic        font_we,
    input  logic [12:0] font_addr,
    input  logic [7:0]  font_data,
    input  logic        font_thin,
    // PVC4: the character ROM image's layout (1: the PC10-III's 32 KB ROM,
    // font_addr_hi = address bits 14-13; 0: the IBM image above) and the two
    // CONFIG switches that are not the 8255's (1 = off): [0] switch 1
    // (1 = USA/Europe character set, 0 = Scandinavian), [1] switch 2
    // (1 = onboard video monochrome, 0 = colour)
    input  logic [1:0]  font_addr_hi,
    input  logic        font_cbm,
    input  logic [1:0]  cbm_dip,
    // PVC4: MONO (the monochrome video pin) and the mono personality, in which
    // vid_ce is the 16.257 MHz dot (1-2 clk) and vid_rgbi = {IT, MONO x 3}
    output logic        vid_mono,
    output logic        vid_monomode,

    // floppy drives A: and B: (rtl/fdc, doc/fdc.md): image geometry from the
    // glue, the sector port to the image backend
    input  logic [1:0]       drv_80trk,
    input  logic [1:0]       img_present,
    input  logic [1:0]       img_wp,
    input  logic [1:0][7:0]  img_tracks,
    input  logic [1:0][1:0]  img_heads,
    input  logic [1:0][5:0]  img_spt,
    output logic [1:0]       drv_motor,
    output logic             fdc_active,
    output logic [1:0]       drv_select,    // drive LED / drive sound (fdc_card.sv)
    output logic             drv_step,
    output logic             drv_step_in,
    output logic        sp_req,
    output logic        sp_write,
    output logic        sp_drive,
    output logic [7:0]  sp_cyl,
    output logic        sp_head,
    output logic [7:0]  sp_sector,
    output logic [15:0] sp_lba,
    input  logic        sp_rd_valid,
    input  logic [7:0]  sp_rd_data,
    output logic        sp_wr_valid,
    output logic [7:0]  sp_wr_data,
    input  logic        sp_wr_ready,
    input  logic        sp_done,
    input  logic        sp_err,

    // hard disk card (rtl/hdc, doc/hdc.md): an XTIDE-compatible card with
    // its option ROM socket at C8000-CBFFF (16 KB, the glue's block RAM, read
    // like the BIOS ROM), two drives and their sector port
    input  logic             hdc_enable,
    input  logic [1:0]       hdc_variant,   // 0 XT-CF / Lo-tech, 1 XTIDE rev 1, 2 XTIDE rev 2
    output logic [13:0]      hdc_rom_addr,
    input  logic [7:0]       hdc_rom_rdata, // 1 clk latency
    input  logic [1:0]       hd_present,
    input  logic [1:0][27:0] hd_sectors,
    input  logic [1:0][15:0] hd_cyls,
    input  logic [1:0][4:0]  hd_heads,
    input  logic [1:0][5:0]  hd_spt,
    output logic             hd_active,
    output logic        hd_sp_req,
    output logic        hd_sp_write,
    output logic        hd_sp_drive,
    output logic [27:0] hd_sp_lba,
    input  logic        hd_sp_rd_valid,
    input  logic [7:0]  hd_sp_rd_data,
    output logic        hd_sp_wr_valid,
    output logic [7:0]  hd_sp_wr_data,
    input  logic        hd_sp_wr_ready,
    input  logic        hd_sp_done,
    input  logic        hd_sp_err,

    // the PC20-III's hard disk (XTA_FIT, rtl/hdc/xta_card.sv, doc/xta.md): a
    // WD93024-X on CN202 at 320h-323h, DMA 3, IRQ 5. xta_enable = JMP208 in
    // position B (0: the ports read FFh, as on a PC10-III), xta_present = a
    // medium: a raw image of 41,820 sectors (615 x 4 x 17, 21,411,840 bytes)
    // behind the sector port (the hd_sp_* protocol, xta_sp_lba < 41820)
    input  logic        xta_enable,
    input  logic        xta_present,
    output logic        xta_active,     // the drive's LED
    output logic        xta_sp_req,
    output logic        xta_sp_write,
    output logic [27:0] xta_sp_lba,
    input  logic        xta_sp_rd_valid,
    input  logic [7:0]  xta_sp_rd_data,
    output logic        xta_sp_wr_valid,
    output logic [7:0]  xta_sp_wr_data,
    input  logic        xta_sp_wr_ready,
    input  logic        xta_sp_done,
    input  logic        xta_sp_err,

    // the PC10-III's real-time clock (PVC4_FIT: the board's MSM6242B at 2C0h,
    // rtl/system/msm6242.sv, doc/rtc.md): seeded from the MEGA65's battery RTC
    // (M2M's main_rtc_i: MiSTer's 65-bit format, years since 2000, bit 64 a
    // toggle per new value); rtc_set = one clk when the PC has set the clock,
    // rtc_time = the clock in M2M's RTC register order (hundredths, seconds,
    // minutes, hours, day, month, year since 2000, weekday 0 = Monday)
    input  logic [64:0] rtc_seed,
    output logic        rtc_set,
    output logic [63:0] rtc_time,

    // the PC10-III's serial port, parallel port and bus mouse (PVC4_FIT: the 5720's
    // board logic, doc/ports.md): the 8250's pins (TTL levels, as at the chip; the
    // inputs asynchronous), the parallel port's pins (the inputs synchronized by the
    // glue), the 9-pin mouse port (Amiga 1352 lines: H/HQ, V/VQ; asynchronous)
    output logic        ser_txd,
    output logic        ser_rts_n,
    output logic        ser_dtr_n,
    input  logic        ser_rxd,
    input  logic        ser_cts_n,
    input  logic        ser_dsr_n,
    input  logic        ser_dcd_n,
    input  logic        ser_ri_n,
    output logic [7:0]  lpt_data,       // also the Covox's DAC (pc_audio_mix.sv)
    output logic        lpt_strobe_n,
    output logic        lpt_autofd_n,
    output logic        lpt_init_n,
    output logic        lpt_selin_n,
    input  logic        lpt_busy,
    input  logic        lpt_ack_n,
    input  logic        lpt_pe,
    input  logic        lpt_slct,
    input  logic        lpt_err_n,
    input  logic        mouse_xp,       // H (DB9 pin 2)
    input  logic        mouse_xq,       // HQ (pin 4)
    input  logic        mouse_yp,       // V (pin 1)
    input  logic        mouse_yq,       // VQ (pin 3)
    input  logic [2:0]  mouse_btn_n,    // {right, middle, left}, 0 = pressed

    input  logic [7:0]  kbd_code,
    input  logic        kbd_valid,
    output logic        kbd_busy,

    output logic        speaker,

    input  logic [7:0]  dip_sw1
);

// ------------------------------------------------------------ clocks
logic ce_14m, cpu_step, cpu_fall, rdy_ce, cpu_prestep, ce_477, ce_pclk, pit_clk;
logic [1:0] speed, spd;                 // turbo: 63h's speed, the running one (doc/turbo.md)
pc_clocks u_clocks (
    .clk        (clk),
    .reset      (reset),
    .speed      (speed),
    .spd        (spd),
    .ce_14m     (ce_14m),
    .cpu_step   (cpu_step),
    .cpu_fall   (cpu_fall),
    .rdy_ce     (rdy_ce),
    .cpu_prestep(cpu_prestep),
    .ce_477     (ce_477),
    .ce_pclk    (ce_pclk),
    .pit_clk    (pit_clk)
);

// ------------------------------------------------------------ CPU
logic [19:0] cpu_ad;
logic [7:0]  cpu_din;
logic [2:0]  cpu_s2_s0, cpu_bus_t, cpu_bus_type;
logic [1:0]  cpu_qs;
logic        cpu_lock_n, cpu_ale, cpu_ready, cpu_intr, cpu_nmi;

cpu8088 u_cpu (
    .clk      (clk),
    .reset    (reset),
    .step     (cpu_step),
    .ucl_we   (ucl_we),
    .ucl_addr (ucl_addr),
    .ucl_data (ucl_data),
    .ready    (cpu_ready),
    .intr     (cpu_intr),
    .nmi      (cpu_nmi),
    .test_n   (1'b1),
    .ad_out   (cpu_ad),
    .ad_in    (cpu_din),
    .s2_s0    (cpu_s2_s0),
    .qs       (cpu_qs),
    .lock_n   (cpu_lock_n),
    .ale      (cpu_ale),
    .bus_t    (cpu_bus_t),
    .bus_type (cpu_bus_type),
    .dbg_cs   (),
    .dbg_ip   ()
);

// ------------------------------------------------------------ system board
logic [19:0] isa_addr, isa_addr_next;
logic [7:0]  isa_dout, isa_din;
logic        isa_dsel, isa_memr_n, isa_memw_n, isa_ior_n, isa_iow_n;
logic        isa_aen, isa_aen_next, isa_ale, isa_ready, isa_tc;
logic        isa_ior_n_next, isa_iow_n_next, isa_memr_n_next, isa_memw_n_next;
logic [7:2]  isa_irq;
logic [3:1]  isa_drq;
logic [3:0]  isa_dack_n;

xt_board #(.RAM_KB(RAM_KB), .DRQ0_SKEW(DRQ0_SKEW)) u_board (
    .clk          (clk),
    .reset        (reset),
    .fe2010a      (fe2010a),
    .cpu_step     (cpu_step),
    .cpu_fall     (cpu_fall),
    .rdy_ce       (rdy_ce),
    .cpu_prestep  (cpu_prestep),
    .ce_477       (ce_477),
    .spd          (spd),
    .speed        (speed),
    .pit_clk      (pit_clk),
    .cpu_ad       (cpu_ad),
    .cpu_din      (cpu_din),
    .cpu_s2_s0    (cpu_s2_s0),
    .cpu_lock_n   (cpu_lock_n),
    .cpu_bus_t    (cpu_bus_t),
    .cpu_bus_type (cpu_bus_type),
    .cpu_ready    (cpu_ready),
    .cpu_intr     (cpu_intr),
    .cpu_nmi      (cpu_nmi),
    .ram_addr     (ram_addr),
    .ram_en       (ram_en),
    .ram_we       (ram_we),
    .ram_wdata    (ram_wdata),
    .ram_rdata    (ram_rdata),
    .ram_ack      (ram_ack),
    .rom_addr     (rom_addr),
    .rom_rdata    (rom_rdata),
    .isa_addr     (isa_addr),
    .isa_addr_next(isa_addr_next),
    .isa_aen_next (isa_aen_next),
    .isa_ior_n_next(isa_ior_n_next),
    .isa_iow_n_next(isa_iow_n_next),
    .isa_memr_n_next(isa_memr_n_next),
    .isa_memw_n_next(isa_memw_n_next),
    .isa_dout     (isa_dout),
    .isa_din      (isa_din),
    .isa_dsel     (isa_dsel),
    .isa_memr_n   (isa_memr_n),
    .isa_memw_n   (isa_memw_n),
    .isa_ior_n    (isa_ior_n),
    .isa_iow_n    (isa_iow_n),
    .isa_aen      (isa_aen),
    .isa_ale      (isa_ale),
    .isa_ready    (isa_ready),
    .isa_irq      (isa_irq),
    .isa_drq      (isa_drq),
    .isa_dack_n   (isa_dack_n),
    .isa_tc       (isa_tc),
    .kbd_code     (kbd_code),
    .kbd_valid    (kbd_valid),
    .kbd_busy     (kbd_busy),
    .speaker      (speaker),
    .dip_sw1      (dip_sw1)
);

// ------------------------------------------------------------ cards
logic [7:0] cga_din, cga_din_c;
logic       cga_dsel, cga_ready, cga_dsel_c, cga_ready_c;
logic [3:0] cga_rgbi;
logic       cga_hs, cga_vs, cga_hb, cga_vb;

wire        ibm_font_we = font_we && font_addr_hi == 2'b00;

cga_card #(.REG_READY(1'b1), .SNOW(CGA_SNOW)) u_cga (
    .clk        (clk),
    .reset      (reset),
    .ce_14m     (ce_14m),
    .isa_addr   (isa_addr),
    .isa_addr_next  (isa_addr_next),
    .isa_memr_n_next(isa_memr_n_next | !CGA_FIT),   // an unfitted card sees no strobes
    .isa_memw_n_next(isa_memw_n_next | !CGA_FIT),
    .isa_aen_next   (isa_aen_next),
    .isa_ior_n_next (isa_ior_n_next  | !CGA_FIT),
    .isa_iow_n_next (isa_iow_n_next  | !CGA_FIT),
    .isa_dout   (isa_dout),
    .isa_din    (cga_din_c),
    .isa_dsel   (cga_dsel_c),
    .isa_memr_n (isa_memr_n | !CGA_FIT),
    .isa_memw_n (isa_memw_n | !CGA_FIT),
    .isa_ior_n  (isa_ior_n  | !CGA_FIT),
    .isa_iow_n  (isa_iow_n  | !CGA_FIT),
    .isa_aen    (isa_aen),
    .isa_ready  (cga_ready_c),
    .font_we    (ibm_font_we),
    .font_addr  (font_addr),
    .font_data  (font_data),
    .font_thin  (font_thin),
    .lpen_trig  (1'b0),
    .lpen_sw    (1'b0),
    .vid_rgbi   (cga_rgbi),
    .vid_hsync  (cga_hs),
    .vid_vsync  (cga_vs),
    .vid_hblank (cga_hb),
    .vid_vblank (cga_vb),
    .comp_cphase(),
    .comp_hsync (),
    .comp_vsync (),
    .comp_burst (),
    .comp_bw    (),
    .comp_mode  ()
);

// a card that is not fitted is not on the bus (synthesis removes it)
assign cga_din    = CGA_FIT ? cga_din_c : 8'h00;
assign cga_dsel   = CGA_FIT && cga_dsel_c;
assign cga_ready  = !CGA_FIT || cga_ready_c;
// video out: the PVC4 when it is on the board, else the CGA
logic       pvc_ce, pvc_mono, pvc_mm, pvc_hs, pvc_vs, pvc_hb, pvc_vb;
logic [3:0] pvc_rgbi;
assign vid_ce       = PVC4_FIT ? pvc_ce : ce_14m;
assign vid_rgbi     = PVC4_FIT ? pvc_rgbi : CGA_FIT ? cga_rgbi : 4'h0;
assign vid_hsync    = PVC4_FIT ? pvc_hs : CGA_FIT && cga_hs;
assign vid_vsync    = PVC4_FIT ? pvc_vs : CGA_FIT && cga_vs;
assign vid_hblank   = PVC4_FIT ? pvc_hb : !CGA_FIT || cga_hb;
assign vid_vblank   = PVC4_FIT ? pvc_vb : !CGA_FIT || cga_vb;
assign vid_mono     = PVC4_FIT && pvc_mono;
assign vid_monomode = PVC4_FIT && pvc_mm;

// MDA or Hercules. With a CGA in the machine the Hercules card does not
// answer at B8000-BFFFF (its page 2 stays invisible to the CPU).
logic [7:0] mda_din, mda_din_c;
logic       mda_dsel, mda_ready, mda_dsel_c, mda_ready_c;
logic       mda_ce_c, mda_v_c, mda_i_c, mda_hs_c, mda_vs_c, mda_hb_c, mda_vb_c;
wire        mda_on = MDA_FIT != 0;

mda_card #(.HERC(MDA_FIT == 2)) u_mda (
    .clk        (clk),
    .reset      (reset),
    .isa_addr   (isa_addr),
    .isa_dout   (isa_dout),
    .isa_din    (mda_din_c),
    .isa_dsel   (mda_dsel_c),
    .isa_memr_n (isa_memr_n | !mda_on),     // an unfitted card sees no strobes (its
    .isa_memw_n (isa_memw_n | !mda_on),     // write-lost check would fire on a BIOS
    .isa_ior_n  (isa_ior_n  | !mda_on),     // probing B0000 with nobody answering)
    .isa_iow_n  (isa_iow_n  | !mda_on),
    .isa_aen    (isa_aen),
    .isa_ready  (mda_ready_c),
    .cga_fitted (CGA_FIT),
    .font_we    (ibm_font_we),
    .font_addr  (font_addr),
    .font_data  (font_data),
    .vid_ce     (mda_ce_c),
    .vid_video  (mda_v_c),
    .vid_intens (mda_i_c),
    .vid_hsync  (mda_hs_c),
    .vid_vsync  (mda_vs_c),
    .vid_hblank (mda_hb_c),
    .vid_vblank (mda_vb_c)
);

assign mda_din    = mda_on ? mda_din_c : 8'h00;
assign mda_dsel   = mda_on && mda_dsel_c;
assign mda_ready  = !mda_on || mda_ready_c;
assign mda_ce     = mda_on && mda_ce_c;
assign mda_video  = mda_on && mda_v_c;
assign mda_intens = mda_on && mda_i_c;
assign mda_hsync  = mda_on && mda_hs_c;
assign mda_vsync  = mda_on && mda_vs_c;
assign mda_hblank = !mda_on || mda_hb_c;
assign mda_vblank = !mda_on || mda_vb_c;

// The PC10-III's onboard video (doc/pvc4.md): the PVC4 with its power-up
// straps as sheet 9-6 wires them, and the 230h register that enables it.
// Paradise register (MA7-MA0): MA7 and MA5 through 33K to the switch 2 node
// (1K pull-up; the switch grounds it for colour), MA6 open (the PVC4's
// internal pull-up), MA4-MA0 pulled down: monochrome mapping and 9-dot
// characters with switch 2 off. Configuration register (MD7-MD0): pull-ups on
// MD7, 6, 4, 2, 1, 0, a pull-down on MD3, MD5 open: one 64K x 8 bank, IBM 200
// lines, composite sync, MONO pin = mono video, border on, printer decode off.
logic [7:0] pvc_din_c, cfg_din_c, pvc_din, cfg_din;
logic       pvc_dsel_c, cfg_dsel_c, pvc_dsel, cfg_dsel, pvc_ready_c, pvc_ready;
logic       venb_n;
logic [6:0] cfg_bits;                   // 230h bits 6-0 (bit 6: the RTC)
logic [7:0] rtc_din;
logic       rtc_dsel;
logic [7:0] com_din, lpt_din, mse_din;
logic       com_dsel, lpt_dsel, mse_dsel, com_irq3, com_irq4, lpt_irq7, mse_irq2;
wire        pvc_on = PVC4_FIT;

generate if (PVC4_FIT) begin : g_pvc4
    cbm_cfg230 u_cfg230 (
        .clk           (clk),
        .reset         (reset),
        .isa_addr      (isa_addr),
        .isa_addr_next (isa_addr_next),
        .isa_aen_next  (isa_aen_next),
        .isa_ior_n_next(isa_ior_n_next),
        .isa_iow_n_next(isa_iow_n_next),
        .isa_dout      (isa_dout),
        .isa_din       (cfg_din_c),
        .isa_dsel      (cfg_dsel_c),
        .isa_ior_n     (isa_ior_n),
        .isa_iow_n     (isa_iow_n),
        .isa_aen       (isa_aen),
        .sw_mono       (cbm_dip[1]),
        .venb_n        (venb_n),
        .cfg           (cfg_bits)
    );

    // the MSM6242B at 2C0h-2CFh, selected by the 5720 while 230h bit 6 is set
    // (doc/rtc.md); battery backed: no reset
    msm6242 u_rtc (
        .clk           (clk),
        .isa_addr      (isa_addr),
        .isa_addr_next (isa_addr_next),
        .isa_aen_next  (isa_aen_next),
        .isa_ior_n_next(isa_ior_n_next),
        .isa_iow_n_next(isa_iow_n_next),
        .isa_dout      (isa_dout),
        .isa_din       (rtc_din),
        .isa_dsel      (rtc_dsel),
        .isa_ior_n     (isa_ior_n),
        .isa_iow_n     (isa_iow_n),
        .isa_aen       (isa_aen),
        .enable        (cfg_bits[6]),
        .seed          (rtc_seed),
        .clk_set       (rtc_set),
        .now           (rtc_time)
    );

    // the serial port (doc/ports.md): an INS8250 at 3F8h (IRQ4) or 2F8h (IRQ3), 230h bits 3-2
    uart8250 u_com (
        .clk           (clk),
        .reset         (reset),
        .isa_addr      (isa_addr),
        .isa_addr_next (isa_addr_next),
        .isa_aen_next  (isa_aen_next),
        .isa_ior_n_next(isa_ior_n_next),
        .isa_iow_n_next(isa_iow_n_next),
        .isa_dout      (isa_dout),
        .isa_din       (com_din),
        .isa_dsel      (com_dsel),
        .isa_ior_n     (isa_ior_n),
        .isa_iow_n     (isa_iow_n),
        .isa_aen       (isa_aen),
        .com           (cfg_bits[3:2]),
        .irq3          (com_irq3),
        .irq4          (com_irq4),
        .intr          (),
        .sout          (ser_txd),
        .sin           (ser_rxd),
        .rts_n         (ser_rts_n),
        .dtr_n         (ser_dtr_n),
        .out1_n        (),
        .out2_n        (),
        .cts_n         (ser_cts_n),
        .dsr_n         (ser_dsr_n),
        .dcd_n         (ser_dcd_n),
        .ri_n          (ser_ri_n)
    );

    // the parallel port (doc/ports.md): the PPC1 at 3BCh/378h/278h (230h bits 1-0), IRQ7
    lpt_ppc1 u_lpt (
        .clk           (clk),
        .reset         (reset),
        .isa_addr      (isa_addr),
        .isa_addr_next (isa_addr_next),
        .isa_aen_next  (isa_aen_next),
        .isa_iow_n_next(isa_iow_n_next),
        .isa_dout      (isa_dout),
        .isa_din       (lpt_din),
        .isa_dsel      (lpt_dsel),
        .isa_ior_n     (isa_ior_n),
        .isa_iow_n     (isa_iow_n),
        .isa_aen       (isa_aen),
        .lpt           (cfg_bits[1:0]),
        .irq7          (lpt_irq7),
        .data          (lpt_data),
        .strobe_n      (lpt_strobe_n),
        .autofd_n      (lpt_autofd_n),
        .init_n        (lpt_init_n),
        .selin_n       (lpt_selin_n),
        .busy          (lpt_busy),
        .ack_n         (lpt_ack_n),
        .pe            (lpt_pe),
        .slct          (lpt_slct),
        .err_n         (lpt_err_n)
    );

    // the 5720's bus mouse at 23Ch-23Eh, IRQ2 (230h bit 4; doc/ports.md)
    cbm_mouse u_mouse (
        .clk           (clk),
        .reset         (reset),
        .isa_addr      (isa_addr),
        .isa_addr_next (isa_addr_next),
        .isa_aen_next  (isa_aen_next),
        .isa_iow_n_next(isa_iow_n_next),
        .isa_dout      (isa_dout),
        .isa_din       (mse_din),
        .isa_dsel      (mse_dsel),
        .isa_ior_n     (isa_ior_n),
        .isa_iow_n     (isa_iow_n),
        .isa_aen       (isa_aen),
        .enable        (cfg_bits[4]),
        .irq2          (mse_irq2),
        .x_p           (mouse_xp),
        .x_q           (mouse_xq),
        .y_p           (mouse_yp),
        .y_q           (mouse_yq),
        .btn_l_n       (mouse_btn_n[0]),
        .btn_m_n       (mouse_btn_n[1]),
        .btn_r_n       (mouse_btn_n[2])
    );

    pvc4 u_pvc4 (
        .clk            (clk),
        .reset          (reset),
        .ce_14m         (ce_14m),
        .isa_addr       (isa_addr),
        .isa_addr_next  (isa_addr_next),
        .isa_memr_n_next(isa_memr_n_next),
        .isa_memw_n_next(isa_memw_n_next),
        .isa_aen_next   (isa_aen_next),
        .isa_ior_n_next (isa_ior_n_next),
        .isa_iow_n_next (isa_iow_n_next),
        .isa_dout       (isa_dout),
        .isa_din        (pvc_din_c),
        .isa_dsel       (pvc_dsel_c),
        .isa_memr_n     (isa_memr_n),
        .isa_memw_n     (isa_memw_n),
        .isa_ior_n      (isa_ior_n),
        .isa_iow_n      (isa_iow_n),
        .isa_aen        (isa_aen),
        .isa_ready      (pvc_ready_c),
        .enable         (pvc_on && !venb_n),
        .par_strap      ({cbm_dip[1], 1'b1, cbm_dip[1], 5'b00000}),
        .cnf_strap      (8'hF7),
        .cg_a14         (cbm_dip[0]),
        .cg_a11         (!cbm_dip[1]),
        .font_we        (font_we),
        .font_addr      ({font_addr_hi, font_addr}),
        .font_data      (font_data),
        .font_cbm       (font_cbm),
        .lpen_trig      (1'b0),
        .lpen_sw        (1'b0),
        .vid_ce         (pvc_ce),
        .vid_rgbi       (pvc_rgbi),
        .vid_mono       (pvc_mono),
        .vid_hsync      (pvc_hs),
        .vid_vsync      (pvc_vs),
        .vid_hblank     (pvc_hb),
        .vid_vblank     (pvc_vb),
        .vid_monomode   (pvc_mm)
    );
end else begin : g_no_pvc4
    assign cfg_din_c = 8'h00;  assign cfg_dsel_c = 1'b0;  assign venb_n = 1'b1;  assign cfg_bits = 7'd0;
    assign rtc_din = 8'h00;  assign rtc_dsel = 1'b0;  assign rtc_set = 1'b0;  assign rtc_time = 64'd0;
    assign com_din = 8'h00;  assign com_dsel = 1'b0;  assign com_irq3 = 1'b0;  assign com_irq4 = 1'b0;
    assign lpt_din = 8'h00;  assign lpt_dsel = 1'b0;  assign lpt_irq7 = 1'b0;
    assign mse_din = 8'h00;  assign mse_dsel = 1'b0;  assign mse_irq2 = 1'b0;
    assign ser_txd = 1'b1;  assign ser_rts_n = 1'b1;  assign ser_dtr_n = 1'b1;
    assign lpt_data = 8'h00;  assign lpt_strobe_n = 1'b1;  assign lpt_autofd_n = 1'b1;
    assign lpt_init_n = 1'b1;  assign lpt_selin_n = 1'b1;
    assign pvc_din_c = 8'h00;  assign pvc_dsel_c = 1'b0;  assign pvc_ready_c = 1'b1;
    assign pvc_ce = 1'b0;  assign pvc_rgbi = 4'h0;  assign pvc_mono = 1'b0;  assign pvc_mm = 1'b0;
    assign pvc_hs = 1'b0;  assign pvc_vs = 1'b0;  assign pvc_hb = 1'b1;  assign pvc_vb = 1'b1;
end endgenerate

assign pvc_din   = pvc_on ? pvc_din_c : 8'h00;
assign pvc_dsel  = pvc_on && pvc_dsel_c;
assign pvc_ready = !pvc_on || pvc_ready_c;
assign cfg_din   = pvc_on ? cfg_din_c : 8'h00;
assign cfg_dsel  = pvc_on && cfg_dsel_c;

logic [7:0] fdc_din;
logic       fdc_dsel, fdc_ready;
logic [7:2] fdc_irq;
logic [3:1] fdc_drq;

fdc_card #(.REG_DECODE(1'b1)) u_fdc (
    .clk         (clk),
    .reset       (reset),
    .isa_addr    (isa_addr),
    .isa_addr_next(isa_addr_next),
    .isa_aen_next(isa_aen_next),
    .isa_ior_n_next(isa_ior_n_next),
    .isa_iow_n_next(isa_iow_n_next),
    .isa_dout    (isa_dout),
    .isa_din     (fdc_din),
    .isa_dsel    (fdc_dsel),
    .isa_ior_n   (isa_ior_n),
    .isa_iow_n   (isa_iow_n),
    .isa_aen     (isa_aen),
    .isa_ready   (fdc_ready),
    .isa_irq     (fdc_irq),
    .isa_drq     (fdc_drq),
    .isa_dack_n  (isa_dack_n),
    .isa_tc      (isa_tc),
    .drv_80trk   (drv_80trk),
    .img_present (img_present),
    .img_wp      (img_wp),
    .img_tracks  (img_tracks),
    .img_heads   (img_heads),
    .img_spt     (img_spt),
    .drv_motor   (drv_motor),
    .fdc_active  (fdc_active),
    .drv_select  (drv_select),
    .drv_step    (drv_step),
    .drv_step_in (drv_step_in),
    .sp_req      (sp_req),
    .sp_write    (sp_write),
    .sp_drive    (sp_drive),
    .sp_cyl      (sp_cyl),
    .sp_head     (sp_head),
    .sp_sector   (sp_sector),
    .sp_lba      (sp_lba),
    .sp_rd_valid (sp_rd_valid),
    .sp_rd_data  (sp_rd_data),
    .sp_wr_valid (sp_wr_valid),
    .sp_wr_data  (sp_wr_data),
    .sp_wr_ready (sp_wr_ready),
    .sp_done     (sp_done),
    .sp_err      (sp_err)
);

logic [7:0] hdc_din;
logic       hdc_dsel, hdc_ready;
logic [7:2] hdc_irq;

xtide_card u_hdc (
    .clk         (clk),
    .reset       (reset),
    .isa_addr    (isa_addr),
    .isa_dout    (isa_dout),
    .isa_din     (hdc_din),
    .isa_dsel    (hdc_dsel),
    .isa_memr_n  (isa_memr_n),
    .isa_ior_n   (isa_ior_n),
    .isa_iow_n   (isa_iow_n),
    .isa_aen     (isa_aen),
    .isa_ready   (hdc_ready),
    .isa_irq     (hdc_irq),
    .enable      (hdc_enable),
    .variant     (hdc_variant),
    .rom_addr    (hdc_rom_addr),
    .rom_rdata   (hdc_rom_rdata),
    .hd_present  (hd_present),
    .hd_sectors  (hd_sectors),
    .hd_cyls     (hd_cyls),
    .hd_heads    (hd_heads),
    .hd_spt      (hd_spt),
    .hd_active   (hd_active),
    .sp_req      (hd_sp_req),
    .sp_write    (hd_sp_write),
    .sp_drive    (hd_sp_drive),
    .sp_lba      (hd_sp_lba),
    .sp_rd_valid (hd_sp_rd_valid),
    .sp_rd_data  (hd_sp_rd_data),
    .sp_wr_valid (hd_sp_wr_valid),
    .sp_wr_data  (hd_sp_wr_data),
    .sp_wr_ready (hd_sp_wr_ready),
    .sp_done     (hd_sp_done),
    .sp_err      (hd_sp_err)
);

// The PC20-III's hard disk (doc/xta.md): the drive on CN202, JMP206/207 fitted
// (IRQ5, DRQ3), JMP208 = xta_enable
logic [7:0] xta_din;
logic       xta_dsel;
logic [7:2] xta_irq;
logic [3:1] xta_drq;

generate if (XTA_FIT) begin : g_xta
    xta_card u_xta (
        .clk         (clk),
        .reset       (reset),
        .isa_addr    (isa_addr),
        .isa_dout    (isa_dout),
        .isa_din     (xta_din),
        .isa_dsel    (xta_dsel),
        .isa_ior_n   (isa_ior_n),
        .isa_iow_n   (isa_iow_n),
        .isa_aen     (isa_aen),
        .isa_ale     (isa_ale),
        .isa_irq     (xta_irq),
        .isa_drq     (xta_drq),
        .isa_dack_n  (isa_dack_n),
        .enable      (xta_enable),
        .present     (xta_present),
        .active      (xta_active),
        .sp_req      (xta_sp_req),
        .sp_write    (xta_sp_write),
        .sp_lba      (xta_sp_lba),
        .sp_rd_valid (xta_sp_rd_valid),
        .sp_rd_data  (xta_sp_rd_data),
        .sp_wr_valid (xta_sp_wr_valid),
        .sp_wr_data  (xta_sp_wr_data),
        .sp_wr_ready (xta_sp_wr_ready),
        .sp_done     (xta_sp_done),
        .sp_err      (xta_sp_err)
    );
end else begin : g_no_xta
    assign xta_din = 8'h00;  assign xta_dsel = 1'b0;  assign xta_irq = 6'b000000;  assign xta_drq = 3'b000;
    assign xta_active = 1'b0;  assign xta_sp_req = 1'b0;  assign xta_sp_write = 1'b0;  assign xta_sp_lba = 28'd0;
    assign xta_sp_wr_valid = 1'b0;  assign xta_sp_wr_data = 8'h00;
end endgenerate

assign isa_din   = (cga_dsel ? cga_din : 8'h00) | (mda_dsel ? mda_din : 8'h00) |
                   (fdc_dsel ? fdc_din : 8'h00) | (hdc_dsel ? hdc_din : 8'h00) |
                   (pvc_dsel ? pvc_din : 8'h00) | (cfg_dsel ? cfg_din : 8'h00) |
                   (xta_dsel ? xta_din : 8'h00) | (rtc_dsel ? rtc_din : 8'h00) |
                   (com_dsel ? com_din : 8'h00) | (lpt_dsel ? lpt_din : 8'h00) | (mse_dsel ? mse_din : 8'h00);
assign isa_dsel  = cga_dsel | mda_dsel | fdc_dsel | hdc_dsel | pvc_dsel | cfg_dsel | xta_dsel | rtc_dsel |
                   com_dsel | lpt_dsel | mse_dsel;
assign isa_ready = cga_ready & mda_ready & fdc_ready & hdc_ready & pvc_ready;
// the 5720's interrupts: the mouse IRQ2, the serial port IRQ3/IRQ4, the parallel port IRQ7
assign isa_irq   = fdc_irq | hdc_irq | xta_irq | {lpt_irq7, 2'b00, com_irq4, com_irq3, mse_irq2};
assign isa_drq   = fdc_drq | xta_drq;

endmodule
