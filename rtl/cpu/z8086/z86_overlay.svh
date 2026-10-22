// z86_overlay.svh - the 8088's interrupt behaviour as an overlay on an 8086
// microcode ROM (included by z86_tables.sv; active only when the bundle is not
// a genuine 8088 ROM, flag bit 0 of tools/mkucode.py's format).
//
// Our own words, written from documented behaviour, not taken from a ROM
// (AGENTS.md rule 4; derivation: doc/z8086.md, "The 8088 interrupt overlay").
// What the 8088 does differently from the 8086 in its interrupt sequences:
//
//   1. One interrupt acknowledge access. The 8086 makes two word INTA accesses;
//      the 8088 makes one, which its BIU splits into the two INTA bus cycles
//      the 8259 needs (Jenner, "8086 microcode disassembled"). The vector
//      arrives with the second cycle (biu88 returns it in the low byte).
//      -> row 0x19C does nothing.
//   2. The INTR entry of the translation ROM is 0x19E, not 0x19D (Jenner);
//      the software interrupts (INT n, INT 3, INTO, divide error, single step,
//      NMI) enter there, past the hardware path's 0x19D. The interrupt number
//      therefore has to be in tmpb when they get there (0x19E zeroes its high
//      byte and doubles it), instead of in OPR.
//      -> rows 0x198 (INT1), 0x199 (INT2), 0x1A7 (INT0): CR -> tmpb, then a
//         short jump to 0x19E; rows 0x1AF (INTO), 0x1B2 (INT 3): CR -> tmpb,
//         long jump INTR; the translation entry INTR -> 0x19E. (CR, the
//         microcode counter, is the interrupt number at these rows.) INT n
//         (0x1A8/0x1A9) has its number in tmpb already.
//   3. Prefetching goes on during the vector reads and is suspended after them
//      (SingleStepTests CD: a code fetch between the two vector words; MartyPC,
//      cpu_808x/interrupt.rs: the suspend after reading CS). The 8086 suspends
//      at its INTR entry.
//      -> row 0x19D (the hardware path after INTA): the vector to tmpb's low
//         byte, without the suspend; row 0x1A3 (the move after the CS read)
//         adds the suspend.
//
// Cycle counts (MartyPC's 8088 sequences, SingleStepTests CC, CD, CE, F6.6,
// F6.7, F7.6, F7.7, D4) are met by these words with the jump bubbles of the
// sequencer; see doc/z8086.md.

// a microinstruction from its fields (the field layout of z86_eu.sv)
function automatic [20:0] uword(input [4:0] d, input [4:0] s, input f, input [9:0] lo);
    uword = {d[0], d[1], d[2], d[3], d[4], s[4], s[3], s[0], s[2], s[1], f, lo};
endfunction

localparam [4:0] OV_D_TMPB  = 5'b01101, OV_D_TMPBL = 5'b10101, OV_D_TMPA = 5'b01100,
                 OV_D_NONE  = 5'b00111;                                  // Q: no destination
localparam [4:0] OV_S_CR    = 5'b10110, OV_S_OPR   = 5'b00110, OV_S_ONES = 5'b10101,
                 OV_S_Q     = 5'b00111;
localparam [9:0] OV_JMP_19E = {2'b00, 4'b1000, 4'd6},   // short jump, UNC, CR = 6
                 OV_LJ_INTR = {3'b101, 3'b000, 4'd6},   // long jump, UNC, INTR
                 OV_NONE    = {3'b100, 4'b1111, 3'b111},// type 4, no operation
                 OV_SUSP    = {3'b100, 4'b1111, 3'b011};// type 4, SUSP

// {hit, word} for a ROM row
function automatic [21:0] overlay_8088(input [8:0] row);
    case (row)
    9'h198, 9'h199, 9'h1A7: overlay_8088 = {1'b1, uword(OV_D_TMPB,  OV_S_CR,   1'b0, OV_JMP_19E)};
    9'h1AF, 9'h1B2:         overlay_8088 = {1'b1, uword(OV_D_TMPB,  OV_S_CR,   1'b0, OV_LJ_INTR)};
    9'h1A8:                 overlay_8088 = {1'b1, uword(OV_D_TMPB,  OV_S_Q,    1'b0, OV_LJ_INTR)};
    9'h19C:                 overlay_8088 = {1'b1, uword(OV_D_NONE,  OV_S_ONES, 1'b0, OV_NONE)};
    9'h19D:                 overlay_8088 = {1'b1, uword(OV_D_TMPBL, OV_S_OPR,  1'b0, OV_NONE)};
    9'h1A3:                 overlay_8088 = {1'b1, uword(OV_D_TMPA,  OV_S_OPR,  1'b0, OV_SUSP)};
    default:                overlay_8088 = 22'd0;
    endcase
endfunction

// the translation ROM's INTR entry (long jump/call destination 6, any
// displacement/read bits: index 00110?0?)
function automatic tr_ov_hit(input [7:0] idx);
    tr_ov_hit = idx[7:3] == 5'b00110 && !idx[1];
endfunction
function automatic [12:0] tr_ov(input [7:0] idx);
    tr_ov = {9'b1_0000_0000, 4'd6};
endfunction
