#!/usr/bin/env python3
"""Generate the pc10-iii MUL/IMUL/DIV/IDIV (F6/F7 /4-/7) and AAM/AAD routines
for the MCL86 microcode listing.

  gen_muldiv.py microcode.txt          rewrite the generated section in place
  gen_muldiv.py --test [N]             run the routines in a small microcode
                                       simulator against the 8088 model below

The 8088 computes these with microcode loops whose length depends on the
data. The routines here do the 8088's algorithm step by step (CORX for the
multiplications, CORD for the divisions, with the pre/post steps of the
signed forms), so that the results, the flags an INT 0 pushes and the cycle
count are the 8088's, and add up the cycles of every step in r3. The cycle
counts of the steps are timing facts from MartyPC's cpu_808x/muldiv.rs (MIT,
Daniel Balsom), which follows the 8088's microcode line by line; no microcode
text is copied. Checked against the SingleStepTests suite: register operand,
end = opcode read + 3 + cycles; memory operand, end = the operand read's end
+ 2 + cycles; AAM/AAD end = immediate read + 1 + cycles.

Registers: r0 = tmpb (operand / divisor), r1 = tmpc, r2 = tmpa, r3 = cycles
<< 5 | loop counter. CF carries the 8088's ALU carry between the steps, flag
bit 1 (scratch, cleared in the main loop) the negate flag of the signed forms
(the 8088 starts it set when a REP prefix is present). The BIU's RM register
keeps the minuend of the last flag-setting subtraction of a division, for the
flags a divide error pushes.
"""
import random
import re
import sys

BASE = 0x1B20
LIMIT = 0x1FF0
BEGIN = '# pc10-iii gen_muldiv.py: BEGIN (generated, do not edit by hand)'
END = '# pc10-iii gen_muldiv.py: END'

# operand codes
AX, BX, CX, DX = 0, 1, 2, 3
FL, R0, R1, R2, R3, CMD, SYS, F = 8, 9, 10, 11, 12, 13, 14, 15
DUM = SYS          # destination E: the result only goes to last_alu
DOUT = F           # destination F: biu_dataout
RM = 5             # operand 1: the BIU's RM register

SUB_BYTE, SUB_WORD = 0x0A46, 0x0A52     # r0 = r0 - r1 with all flags (destroys r1-r3)
MAIN = 0x0004
INT_ENTRY = 0x055D                      # after INT n's release: pop the strobe, INTERRUPT


def w(t, d, a, b, imm=0, cin=0):
    return (cin << 31) | (t << 28) | (d << 24) | (a << 20) | (b << 16) | (imm & 0xFFFF)


class Asm:
    def __init__(self, base):
        self.base = base
        self.code = []          # [word or (kind, label), comment]
        self.labels = {}
        self.n = 0

    def here(self):
        return self.base + len(self.code)

    def label(self, name):
        assert name not in self.labels, name
        self.labels[name] = self.here()

    def uniq(self, s):
        self.n += 1
        return f'{s}_{self.n}'

    def emit(self, x, c):
        self.code.append([x, c])

    # ALU
    def add(self, d, a, b, imm=0, c=''): self.emit(w(2, d, a, b, imm), c)
    def adc(self, d, a, b, imm=0, c=''): self.emit(w(2, d, a, b, imm, 1), c)
    def and_(self, d, a, b, imm=0, c=''): self.emit(w(4, d, a, b, imm), c)
    def or_(self, d, a, b, imm=0, c=''): self.emit(w(5, d, a, b, imm), c)
    def xor(self, d, a, b, imm=0, c=''): self.emit(w(6, d, a, b, imm), c)
    def shr(self, d, a, c=''): self.emit(w(7, d, a, F), c)
    def mov(self, d, b, c=''): self.emit(w(5, d, F, b), c)          # d = 0 | op1
    def movi(self, d, imm, c=''): self.emit(w(5, d, F, F, imm), c)
    def sync(self, imm, c=''): self.emit(imm, c)
    # control
    def jmp(self, l, c=''): self.emit(('jmp', l), c)
    def jz(self, l, c=''): self.emit(('jz', l), c)
    def jnz(self, l, c=''): self.emit(('jnz', l), c)
    def call(self, l, c=''): self.emit(('call', l), c)
    def ret(self, c='Return to calling code'): self.emit(0x10300000, c)

    def words(self):
        out = []
        for i, (x, c) in enumerate(self.code):
            if isinstance(x, tuple):
                k, l = x
                t = self.labels[l] if isinstance(l, str) else l
                x = {'jmp': 0x10000000, 'jz': 0x10020000, 'jnz': 0x10010000, 'call': 0x11000000}[k] | t
            out.append((self.base + i, x, c))
        return out


# ------------------------------------------------------------------ macros

def cyc(a, k, why=''):
    if k:
        a.add(R3, R3, F, (k << 5) & 0xFFFF, f'r3 += {k} cycles' + (f' ({why})' if why else ''))


def cf_from_carry(a, b):
    """CF = the carry of the last addition at width b (8: Carry8, 16: Carry16)."""
    l0, l1 = a.uniq('cf0'), a.uniq('cfd')
    a.and_(DUM, SYS, F, 0x2000 if b == 8 else 0x0001, f'Isolate the Carry{b} signal')
    a.jz(l0, 'Jump if zero to clear CF')
    a.or_(FL, FL, F, 0x0001, 'CF = 1')
    a.jmp(l1, 'Jump over the clear')
    a.label(l0)
    a.and_(FL, FL, F, 0xFFFE, 'CF = 0')
    a.label(l1)


def rcr(a, x, b, name):
    """x, CF = x >> 1 | CF << (b-1), x[0] (the 8088's RCR by one)."""
    top = 0x80 if b == 8 else 0x8000
    l1, l0b, l1b, ld = a.uniq('rcr1'), a.uniq('rcr0b'), a.uniq('rcr1b'), a.uniq('rcrd')
    a.and_(DUM, x, F, 0x0001, f'RCR {name}: isolate bit 0 (the new CF)')
    a.jnz(l1, 'Jump if one')
    a.shr(x, x, f'{name} >> 1')
    a.and_(DUM, FL, F, 0x0001, 'Isolate CF')
    a.jz(l0b, 'Jump if zero over the next')
    a.or_(x, x, F, top, f'{name}[{b - 1}] = CF')
    a.label(l0b)
    a.and_(FL, FL, F, 0xFFFE, 'CF = 0 (the bit shifted out)')
    a.jmp(ld, 'Jump to the end of the RCR')
    a.label(l1)
    a.shr(x, x, f'{name} >> 1')
    a.and_(DUM, FL, F, 0x0001, 'Isolate CF')
    a.jz(l1b, 'Jump if zero over the next')
    a.or_(x, x, F, top, f'{name}[{b - 1}] = CF')
    a.label(l1b)
    a.or_(FL, FL, F, 0x0001, 'CF = 1 (the bit shifted out)')
    a.label(ld)


def rcl(a, x, b, name):
    """x, CF = x << 1 | CF, x[b-1] (the 8088's RCL by one)."""
    a.adc(x, x, x, 0, f'RCL {name}: {name} = {name} + {name} + CF')
    cf_from_carry(a, b)
    if b == 8:
        a.and_(x, x, F, 0x00FF, f'{name} &= 00FF')


def neg(a, x, b, name):
    m = 0xFF if b == 8 else 0xFFFF
    a.xor(x, x, F, m, f'{name} = NOT {name}')
    a.add(x, x, F, 1, f'{name} = {name} + 1 (two\'s complement)')
    if b == 8:
        a.and_(x, x, F, 0x00FF, f'{name} &= 00FF')


def counter_set(a, n):
    a.or_(R3, R3, F, n, f'r3[4:0] = {n} (the loop counter)')


def counter_dec(a, l_more, why):
    a.add(R3, R3, F, 0xFFFF, 'r3 = r3 - 1 (the loop counter)')
    a.and_(DUM, R3, F, 0x001F, 'Isolate the loop counter')
    a.jnz(l_more, why)


# ------------------------------------------------------------------ cores

def corx(a, b):
    """The 8088's CORX multiplication: r2:r1 = r0 * r1 (tmpb * tmpc), CF the
    carry in. r2 must be 0."""
    p = f'CORX{b}'
    a.label(p)
    rcr(a, R1, b, 'tmpc')
    counter_set(a, b)
    cyc(a, 2)
    a.label(p + '_LOOP')
    cyc(a, 1)
    a.and_(DUM, FL, F, 0x0001, 'Isolate CF (the bit of tmpc shifted out)')
    a.jz(p + '_NOADD', 'Jump if zero: no addition')
    a.add(R2, R2, R0, 0, 'tmpa = tmpa + tmpb')
    cf_from_carry(a, b)
    if b == 8:
        a.and_(R2, R2, F, 0x00FF, 'tmpa &= 00FF')
    cyc(a, 2)
    a.jmp(p + '_SHIFT', 'Jump to the shifts')
    a.label(p + '_NOADD')
    cyc(a, 1, 'the jump')
    a.label(p + '_SHIFT')
    rcr(a, R2, b, 'tmpa')
    rcr(a, R1, b, 'tmpc')
    cyc(a, 3)
    a.add(R3, R3, F, 0xFFFF, 'r3 = r3 - 1 (the loop counter)')
    a.and_(DUM, R3, F, 0x001F, 'Isolate the loop counter')
    a.jz(p + '_DONE', 'Jump if zero: done')
    cyc(a, 1, 'the jump back')
    a.jmp(p + '_LOOP', 'Jump to the next bit')
    a.label(p + '_DONE')
    cyc(a, 2)
    a.ret()


def save_minuend(a):
    a.mov(DOUT, R2, 'biu_dataout = tmpa (the minuend of the flag-setting subtraction)')
    a.or_(CMD, CMD, F, 0x3040, 'Strobe BIU - set the RM register (kept for the divide error flags)')
    a.and_(CMD, CMD, F, 0xC003, 'Debounce BIU Strobe (and its register code)')


def cord(a, b):
    """The 8088's CORD division of r2:r1 by r0 (tmpa:tmpc / tmpb). r0 holds
    -tmpb here (tmpb = 0 always fails the first test). Returns with CF = the
    8088's final carry; r2 = remainder, r1 = complemented quotient. A divide
    error jumps to the error path instead (r3 has the cycles)."""
    p = f'CORD{b}'
    m = 0xFF if b == 8 else 0xFFFF
    a.label(p)
    save_minuend(a)
    cyc(a, 3)
    a.and_(DUM, R0, F, m, 'Isolate tmpb')
    a.jz(p + '_ERR', 'Jump if zero: division by zero')
    neg(a, R0, b, 'r0 (-tmpb)')
    a.add(DUM, R2, R0, 0, 'Dummy = tmpa - tmpb')
    a.and_(DUM, SYS, F, 0x2000 if b == 8 else 0x0001, f'Isolate the Carry{b} signal (no borrow)')
    a.jnz(p + '_ERRN', 'Jump if no borrow: the quotient does not fit')
    a.or_(FL, FL, F, 0x0001, 'CF = 1 (the borrow)')
    counter_set(a, b)
    a.label(p + '_LOOP')
    rcl(a, R1, b, 'tmpc')
    rcl(a, R2, b, 'tmpa')
    cyc(a, 4)
    a.and_(DUM, FL, F, 0x0001, 'Isolate CF (tmpa overflowed)')
    a.jz(p + '_CMP', 'Jump if zero to the trial subtraction')
    cyc(a, 3, 'tmpa overflowed: subtract')
    a.and_(FL, FL, F, 0xFFFE, 'CF = 0')
    a.add(R2, R2, R0, 0, 'tmpa = tmpa - tmpb')
    if b == 8:
        a.and_(R2, R2, F, 0x00FF, 'tmpa &= 00FF')
    a.add(R3, R3, F, 0xFFFF, 'r3 = r3 - 1 (the loop counter)')
    a.and_(DUM, R3, F, 0x001F, 'Isolate the loop counter')
    a.jz(p + '_LAST2', 'Jump if zero: the last bit')
    cyc(a, 1, 'the jump back')
    a.jmp(p + '_LOOP', 'Jump to the next bit')
    a.label(p + '_CMP')
    save_minuend(a)
    cyc(a, 2)
    a.add(DUM, R2, R0, 0, 'Dummy = tmpa - tmpb (sets the flags on the 8088)')
    a.and_(DUM, SYS, F, 0x2000 if b == 8 else 0x0001, f'Isolate the Carry{b} signal (no borrow)')
    a.jz(p + '_BORROW', 'Jump if zero: borrow, keep tmpa')
    a.and_(FL, FL, F, 0xFFFE, 'CF = 0 (no borrow)')
    cyc(a, 2)
    a.add(R2, R2, R0, 0, 'tmpa = tmpa - tmpb')
    if b == 8:
        a.and_(R2, R2, F, 0x00FF, 'tmpa &= 00FF')
    a.add(R3, R3, F, 0xFFFF, 'r3 = r3 - 1 (the loop counter)')
    a.and_(DUM, R3, F, 0x001F, 'Isolate the loop counter')
    a.jz(p + '_LAST2', 'Jump if zero: the last bit')
    cyc(a, 1, 'the jump back')
    a.jmp(p + '_LOOP', 'Jump to the next bit')
    a.label(p + '_BORROW')
    a.or_(FL, FL, F, 0x0001, 'CF = 1 (borrow)')
    cyc(a, 1)
    a.add(R3, R3, F, 0xFFFF, 'r3 = r3 - 1 (the loop counter)')
    a.and_(DUM, R3, F, 0x001F, 'Isolate the loop counter')
    a.jz(p + '_END', 'Jump if zero: done')
    cyc(a, 1, 'the jump back')
    a.jmp(p + '_LOOP', 'Jump to the next bit')
    a.label(p + '_LAST2')
    cyc(a, 2)
    a.label(p + '_END')
    rcl(a, R1, b, 'tmpc')
    a.and_(FL, FL, F, 0xFFFE, 'CF = 0')
    a.and_(DUM, R1, F, 0x80 if b == 8 else 0x8000, 'Isolate the top bit of tmpc (the final carry)')
    a.jz(p + '_C0', 'Jump if zero')
    a.or_(FL, FL, F, 0x0001, 'CF = 1')
    a.label(p + '_C0')
    cyc(a, 4)
    neg(a, R0, b, 'r0 (tmpb again)')
    a.ret()
    a.label(p + '_ERRN')
    neg(a, R0, b, 'r0 (tmpb again)')
    a.label(p + '_ERR')
    cyc(a, 1, 'the jump')
    a.jmp(f'DIVERR{b}', 'Jump to the divide error')


def cor_negate(a, b, skip, tag):
    """The 8088's NEGATE: unless skip, tmpa:tmpc = -(tmpa:tmpc) and the negate
    flag toggles; then CF = tmpb's sign, and a negative tmpb is negated (the
    flag toggles again)."""
    m = 0xFF if b == 8 else 0xFFFF
    s = 0x80 if b == 8 else 0x8000
    p = f'NEG{b}{tag}'
    if not skip:
        a.and_(DUM, R1, F, m, 'Isolate tmpc')
        a.jz(p + '_C0', 'Jump if zero: tmpc stays 0, tmpa is negated')
        neg(a, R1, b, 'tmpc')
        a.xor(R2, R2, F, m, 'tmpa = NOT tmpa (the borrow of tmpc)')
        a.jmp(p + '_C1', 'Jump over the next')
        a.label(p + '_C0')
        neg(a, R2, b, 'tmpa')
        a.label(p + '_C1')
        cyc(a, 5)
        a.xor(FL, FL, F, 0x0002, 'Toggle the negate flag (flag bit 1)')
    cyc(a, 3)
    a.and_(DUM, R0, F, s, 'Isolate the sign of tmpb')
    a.jnz(p + '_BN', 'Jump if negative')
    a.and_(FL, FL, F, 0xFFFE, 'CF = 0 (tmpb positive)')
    cyc(a, 3)
    a.jmp(p + '_END', 'Jump to the end')
    a.label(p + '_BN')
    a.or_(FL, FL, F, 0x0001, 'CF = 1 (tmpb negative)')
    neg(a, R0, b, 'tmpb')
    a.xor(FL, FL, F, 0x0002, 'Toggle the negate flag (flag bit 1)')
    cyc(a, 2)
    a.label(p + '_END')


# ------------------------------------------------------------------ ends

def arm_end(a, b, kind):
    """r3 >> 5 = the cycles of the 8088's routine. Arm the end:
    kind 'mul'/'div' (F6/F7): register operand, A(cycles + 2) (the ModR/M byte
    was the last queue read, at cycle 1); memory operand, 2 cycles after
    the operand read's end: SYNC 64 cycles after it, then F(rest).
    kind 'aa' (AAM/AAD): A(cycles + 1) after the immediate."""
    p = a.uniq('END')
    for _ in range(5):
        a.shr(R3, R3, 'r3 >> 1')
    if kind == 'aa':
        a.add(DOUT, R3, F, 0xA001, 'biu_dataout = A000 + cycles + 1 (end: after the immediate)')
    else:
        a.and_(DUM, FL, F, 0x4000, 'Isolate the REPZ bit (register operand)')
        a.jz(p + '_MEM', 'Jump if zero to the memory operand end')
        a.add(DOUT, R3, F, 0xA002, 'biu_dataout = A000 + cycles + 2 (end: after the ModR/M byte)')
        a.jmp(p + '_ARM', 'Jump to the strobe')
        a.label(p + '_MEM')
        a.sync(0xC040, 'SYNC: 64 cycles after the operand read ended')
        k = 2 - 64
        a.add(DOUT, R3, F, (0xF000 + k) & 0xFFFF, f'biu_dataout = F000 + cycles {k:+d} (end: n cycles from now)')
        a.label(p + '_ARM')
    a.or_(CMD, CMD, F, 0x2000, 'Strobe BIU - Set clock counter')
    a.and_(CMD, CMD, F, 0xCFFF, 'Debounce BIU Strobe')


def divide_error(a, b, tag=''):
    """INT 0. The first vector read is released as the 8088's, 10 cycles after
    the cycles counted end (register: cycles + 9 after the ModR/M read, the
    request 3 before T1; memory: after the operand read). Then the flags."""
    p = f'DIVERR{b}{tag}'
    a.label(p)
    for _ in range(5):
        a.shr(R3, R3, 'r3 >> 1')
    a.and_(DUM, FL, F, 0x4000, 'Isolate the REPZ bit (register operand)')
    a.jz(p + '_MEM', 'Jump if zero to the memory operand release')
    a.add(DOUT, R3, F, 0x0006, 'biu_dataout = cycles + 6 (release: after the ModR/M byte)')
    a.jmp(p + '_REL', 'Jump to the strobe')
    a.label(p + '_MEM')
    a.add(DOUT, R3, F, 0x2006, 'biu_dataout = 2000 + cycles + 6 (release: after the operand read)')
    a.label(p + '_REL')
    a.or_(CMD, CMD, F, 0x3060, 'Strobe BIU - set the request release')
    a.and_(CMD, CMD, F, 0xC003, 'Debounce BIU Strobe (and its register code)')
    a.jmp(p + '_FL', 'Jump to the flags')


# ------------------------------------------------------------------ routines

def routine_mul(a, b, signed):
    name = f'{"I" if signed else ""}MUL{b}'
    m = 0xFF if b == 8 else 0xFFFF
    s = 0x80 if b == 8 else 0x8000
    a.label(name)
    a.and_(R0, R0, F, m, 'tmpb = the operand')
    a.and_(R1, AX, F, m, 'tmpc = AL' if b == 8 else 'tmpc = AX')
    a.movi(R2, 0, 'tmpa = 0')
    a.movi(R3, 0, 'r3 = 0 (cycles, loop counter)')
    cyc(a, 2)
    a.and_(FL, FL, F, 0xFFFE, 'CF = 0')
    a.and_(DUM, R1, F, s, 'Isolate the sign of tmpc')
    a.jz(name + '_CP', 'Jump if zero')
    a.or_(FL, FL, F, 0x0001, 'CF = the sign of tmpc')
    a.label(name + '_CP')
    if signed:
        cyc(a, 3)
        a.and_(DUM, FL, F, 0x0001, 'Isolate CF (tmpc negative)')
        a.jz(name + '_AP', 'Jump if zero: tmpc positive')
        neg(a, R1, b, 'tmpc')
        a.xor(FL, FL, F, 0x0002, 'Toggle the negate flag (flag bit 1)')
        cyc(a, 3)
        a.jmp(name + '_N', 'Jump to NEGATE')
        a.label(name + '_AP')
        cyc(a, 1)
        a.label(name + '_N')
        cor_negate(a, b, True, name)
    cyc(a, 2)
    a.call(f'CORX{b}', f'CALL CORX{b}')
    cyc(a, 1)
    a.and_(DUM, FL, F, 0x0002, 'Isolate the negate flag')
    a.jz(name + '_NN', 'Jump if zero: no negation')
    cyc(a, 1)
    cor_negate(a, b, False, name + 'X')
    a.label(name + '_NN')
    cyc(a, 1)
    a.and_(FL, FL, F, 0xF7FE, 'CF = OF = 0')
    if signed:
        cyc(a, 4)
        a.and_(DUM, R1, F, s, 'Isolate the sign of tmpc (low half)')
        a.jz(name + '_S0', 'Jump if zero')
        a.add(DUM, R2, F, 1, 'Dummy = tmpa + 1')
        a.and_(DUM, SYS, F, 0x2000 if b == 8 else 0x0001, 'Isolate the carry: tmpa was all ones')
        a.jnz(name + '_FIT', 'Jump if the product fits the low half')
        a.jmp(name + '_OV', 'Jump: it does not')
        a.label(name + '_S0')
        a.and_(DUM, R2, F, m, 'Isolate tmpa')
        a.jz(name + '_FIT', 'Jump if zero: the product fits the low half')
        a.label(name + '_OV')
        cyc(a, 3 + 2)
        a.or_(FL, FL, F, 0x0801, 'CF = OF = 1')
        a.jmp(name + '_WB', 'Jump to the writeback')
        a.label(name + '_FIT')
        cyc(a, 4 + 2)
    else:
        cyc(a, 6)
        a.and_(DUM, R2, F, m, 'Isolate tmpa (the high half)')
        a.jz(name + '_Z', 'Jump if zero')
        cyc(a, 3)
        a.or_(FL, FL, F, 0x0801, 'CF = OF = 1')
        a.jmp(name + '_WB', 'Jump to the writeback')
        a.label(name + '_Z')
        cyc(a, 4)
    a.label(name + '_WB')
    if b == 8:
        a.emit(w(3, R2, R2, F), 'tmpa << 8 (byte swap)')
        a.or_(AX, R2, R1, 0, 'AX = tmpa:tmpc')
    else:
        a.mov(AX, R1, 'AX = tmpc')
        a.mov(DX, R2, 'DX = tmpa')
    arm_end(a, b, 'mul')
    a.jmp(0x093B, 'Jump to the queue strobe and the main loop')


def routine_div(a, b, signed):
    name = f'{"I" if signed else ""}DIV{b}'
    m = 0xFF if b == 8 else 0xFFFF
    s = 0x80 if b == 8 else 0x8000
    a.label(name)
    a.and_(R0, R0, F, m, 'tmpb = the operand')
    if b == 8:
        a.and_(R1, AX, F, 0x00FF, 'tmpc = AL')
        a.and_(R2, AX, F, 0xFF00, 'tmpa = AH << 8')
        a.emit(w(3, R2, R2, F), 'tmpa = AH (byte swap)')
    else:
        a.or_(R1, AX, F, 0, 'tmpc = AX')
        a.or_(R2, DX, F, 0, 'tmpa = DX')
    a.movi(R3, 0, 'r3 = 0 (cycles, loop counter)')
    cyc(a, 3)
    if signed:
        cyc(a, 1 + 2)
        a.and_(DUM, R2, F, s, 'Isolate the sign of tmpa (the dividend)')
        a.jnz(name + '_NEG', 'Jump if negative')
        cyc(a, 1)
        cor_negate(a, b, True, name + 'P')
        a.jmp(name + '_CORD', 'Jump to CORD')
        a.label(name + '_NEG')
        cor_negate(a, b, False, name + 'N')
        a.label(name + '_CORD')
    cyc(a, 2)
    a.call(f'CORD{b}', f'CALL CORD{b}')
    cyc(a, 2)
    if signed:
        cyc(a, 1 + 1)
        a.and_(DUM, FL, F, 0x0001, 'Isolate CF (the final carry)')
        a.jz(f'IDIVERR{b}', 'Jump if zero: the quotient does not fit')
        cyc(a, 3 + 1 + 2 + 1 + 2)
        if b == 8:
            a.and_(DUM, AX, F, 0x8000, 'Isolate the sign of AH (the dividend)')
        else:
            a.and_(DUM, DX, F, 0x8000, 'Isolate the sign of DX (the dividend)')
        a.jz(name + '_RP', 'Jump if zero: the remainder stays')
        neg(a, R2, b, 'tmpa (the remainder)')
        a.label(name + '_RP')
        a.and_(DUM, FL, F, 0x0002, 'Isolate the negate flag')
        a.jz(name + '_QC', 'Jump if zero: quotient = NOT tmpc')
        a.add(R1, R1, F, 1, 'quotient = tmpc + 1')
        if b == 8:
            a.and_(R1, R1, F, 0x00FF, 'quotient &= 00FF')
        a.jmp(name + '_WB', 'Jump to the writeback')
        a.label(name + '_QC')
    a.xor(R1, R1, F, m, 'quotient = NOT tmpc')
    if signed:
        a.label(name + '_WB')
    if b == 8:
        a.emit(w(3, R2, R2, F), 'remainder << 8 (byte swap)')
        a.or_(AX, R2, R1, 0, 'AX = remainder:quotient')
    else:
        a.mov(AX, R1, 'AX = the quotient')
        a.mov(DX, R2, 'DX = the remainder')
    arm_end(a, b, 'div')
    a.jmp(0x093B, 'Jump to the queue strobe and the main loop')
    if signed:
        a.label(f'IDIVERR{b}')
        cyc(a, 1, 'the jump to INT0')
        a.jmp(f'DIVERR{b}C', 'Jump to the divide error (after CORD)')


def routine_divflags(a, b, tag=''):
    """The error path's flags: the 8088's subtraction tmpa_saved - tmpb at
    width b (all six flags; after CORD, IDIV's late error, CF = CORD's final
    carry, 0), then the INT 0 entry."""
    a.label(f'DIVERR{b}{tag}_FL')
    a.mov(R1, R0, 'r1 = tmpb')
    a.mov(R0, RM, 'r0 = the saved minuend (the BIU RM register)')
    a.call(SUB_BYTE if b == 8 else SUB_WORD, 'CALL SUB_BYTE' if b == 8 else 'CALL SUB_WORD')
    if tag:
        a.and_(FL, FL, F, 0xFFFE, 'CF = 0 (CORD\'s final carry)')
    a.and_(FL, FL, F, 0x1FFF, 'Clear flag bits 15-13 (the register operand marker would push IP-1)')
    a.movi(R0, 0, 'r0 = 0 (interrupt type 0)')
    a.jmp(INT_ENTRY, 'Jump to the interrupt processing (after INT n\'s release)')


def routine_repsave(a):
    """From the armed ModR/M entries of F6/F7 (0x16B0/0x16D0) where they
    return for a memory operand (0x16B9/0x16D9) or for MUL/IMUL/DIV/IDIV
    (0x16BD/0x16DD), before the wrappers clear the REP bits: the negate flag
    (flag bit 1) starts set when a REP prefix is present (the 8088's
    MUL/IMUL/DIV/IDIV negate their result then). The register forms of
    TEST/NOT/NEG keep their path."""
    a.label('REPSAVE')
    a.and_(DUM, FL, F, 0xC000, 'Isolate the REPZ and REPNZ bits')
    a.jz('REPSAVE_0', 'Jump if zero over the next')
    a.or_(FL, FL, F, 0x0002, 'Flag bit 1 = 1 (the negate flag)')
    a.label('REPSAVE_0')
    a.ret('Return to calling code (from the armed ModR/M entry)')


def routine_aam(a):
    """AAM (from 0x02CA; r0 = the immediate, not 0, r1 = AL): CORD on 0:AL,
    AH = the quotient, AL = the remainder; end imm + 1 + 3 + CORD + 1."""
    a.label('AAM')
    a.and_(R0, R0, F, 0x00FF, 'tmpb = the immediate')
    a.and_(R1, R1, F, 0x00FF, 'tmpc = AL')
    a.movi(R2, 0, 'tmpa = 0')
    a.movi(R3, 0, 'r3 = 0 (cycles, loop counter)')
    cyc(a, 3)
    a.call('CORD8', 'CALL CORD8 (no error: tmpa = 0 < tmpb)')
    cyc(a, 1)
    a.xor(R1, R1, F, 0x00FF, 'quotient = NOT tmpc')
    a.emit(w(3, R1, R1, F), 'quotient << 8 (byte swap)')
    a.or_(AX, R2, R1, 0, 'AX = quotient:remainder')
    for _ in range(5):
        a.shr(R3, R3, 'r3 >> 1')
    a.add(DOUT, R3, F, 0xA001, 'biu_dataout = A000 + cycles + 1 (end: after the immediate)')
    a.jmp(0x02D7, 'Jump to the flags (from AL) and the multibyte ending')


def routine_aamerr(a):
    """AAM 0 (from 0x1AEF, flags of a zero result set, r0 = 0): the first
    vector read is released 12 cycles after the immediate (T1 14 after it:
    3 + CORD's 4 to the error, then the 8088's INT 0 entry)."""
    a.label('AAMERR')
    a.movi(DOUT, 0x000C, 'biu_dataout = 000C (release: 12 cycles after the immediate)')
    a.or_(CMD, CMD, F, 0x3060, 'Strobe BIU - set the request release')
    a.and_(CMD, CMD, F, 0xC003, 'Debounce BIU Strobe (and its register code)')
    a.jmp(INT_ENTRY, 'Jump to the interrupt processing (after INT n\'s release)')


def routine_aad(a):
    """AAD's end (from 0x02BE and the zero immediate path at 0x02B3; r3 = the
    immediate): CORX multiplies AH by the immediate, its length depends on the
    immediate's one bits: end = imm + 1 + 3 + (2 + 5*8 + 7 + 2 + ones) + 2."""
    a.label('AADZ')
    a.movi(R3, 0, 'r3 = 0 (the immediate)')
    a.call('AADEND', 'CALL AADEND')
    a.jmp(0x02BF, 'Jump to the flags (from AL: 0x02BF sets last_alu)')
    a.label('AADEND')
    a.and_(R1, R3, F, 0x00FF, 'r1 = the immediate')
    a.movi(R0, 0xA039, 'r0 = A000 + 57 (end: after the immediate)')
    a.label('AADEND_L')
    a.and_(DUM, R1, F, 0x0001, 'Isolate bit 0')
    a.jz('AADEND_0', 'Jump if zero')
    a.add(R0, R0, F, 1, 'r0 = r0 + 1 (an addition in CORX)')
    a.label('AADEND_0')
    a.shr(R1, R1, 'r1 >> 1')
    a.jnz('AADEND_L', 'Jump if bits are left')
    a.mov(DOUT, R0, 'biu_dataout = r0')
    a.ret()


def build():
    a = Asm(BASE)
    routine_repsave(a)
    routine_aam(a)
    routine_aamerr(a)
    routine_aad(a)
    entries = {}
    for b in (8, 16):
        for signed in (False, True):
            entries[('mul', b, signed)] = None
            routine_mul(a, b, signed)
            routine_div(a, b, signed)
    for b in (8, 16):
        corx(a, b)
        cord(a, b)
        divide_error(a, b)
        routine_divflags(a, b)
        divide_error(a, b, 'C')
        routine_divflags(a, b, 'C')
    return a


def patches(a):
    """Existing words that lead to the generated routines: (addr, word, comment)."""
    L = a.labels
    return [(0x1651, 0x110016B0, 'pc10-iii: CALL the armed ModR/M entry (F6) first (gen_muldiv.py: it saves the REP bits)'),
            (0x1652, 0x488F3FFF, 'pc10-iii: Initialize REPZ and REPNZ flags to zero (after the entry, gen_muldiv.py)'),
            (0x1655, 0x110016D0, 'pc10-iii: CALL the armed ModR/M entry (F7) first (gen_muldiv.py: it saves the REP bits)'),
            (0x1656, 0x488F3FFF, 'pc10-iii: Initialize REPZ and REPNZ flags to zero (after the entry, gen_muldiv.py)'),
            (0x16B9, 0x10010000 | L['REPSAVE'], 'pc10-iii: memory operand: to REPSAVE, which returns (gen_muldiv.py)'),
            (0x16BD, 0x10010000 | L['REPSAVE'], 'pc10-iii: MUL/DIV: to REPSAVE, which returns (gen_muldiv.py)'),
            (0x16D9, 0x10010000 | L['REPSAVE'], 'pc10-iii: memory operand: to REPSAVE, which returns (gen_muldiv.py)'),
            (0x16DD, 0x10010000 | L['REPSAVE'], 'pc10-iii: MUL/DIV: to REPSAVE, which returns (gen_muldiv.py)'),
            (0x0E1C, 0x10000000 | L['MUL8'], 'pc10-iii: to MUL8 (gen_muldiv.py)'),
            (0x0E1D, 0x10000000 | L['IMUL8'], 'pc10-iii: to IMUL8 (gen_muldiv.py)'),
            (0x0E1E, 0x10000000 | L['DIV8'], 'pc10-iii: to DIV8 (gen_muldiv.py)'),
            (0x0E1F, 0x10000000 | L['IDIV8'], 'pc10-iii: to IDIV8 (gen_muldiv.py)'),
            (0x0E8C, 0x10000000 | L['MUL16'], 'pc10-iii: to MUL16 (gen_muldiv.py)'),
            (0x0E8D, 0x10000000 | L['IMUL16'], 'pc10-iii: to IMUL16 (gen_muldiv.py)'),
            (0x0E8E, 0x10000000 | L['DIV16'], 'pc10-iii: to DIV16 (gen_muldiv.py)'),
            (0x0E8F, 0x10000000 | L['IDIV16'], 'pc10-iii: to IDIV16 (gen_muldiv.py)'),
            (0x02CA, 0x10000000 | L['AAM'], 'pc10-iii: to AAM (gen_muldiv.py: CORD, the 8088\'s cycle count)'),
            (0x02BE, 0x11000000 | L['AADEND'], 'pc10-iii: CALL AADEND (gen_muldiv.py: the end from the immediate\'s one bits)'),
            (0x02B3, 0x10000000 | L['AADZ'], 'pc10-iii: to AADZ (gen_muldiv.py: the end for a zero immediate)'),
            (0x1AEF, 0x10000000 | L['AAMERR'], 'pc10-iii: to AAMERR (gen_muldiv.py: the INT 0 vector read released as the 8088\'s)')]


def apply_patches(s, a):
    lines = s.split('\n')
    for ad, x, c in patches(a):
        k = lines.index('p 00 00000 00001 %04X' % ad)
        while 'gen_muldiv.py' in lines[k - 1] and lines[k - 1] != '# ' + c:
            del lines[k - 1]
            k -= 1
        if lines[k - 1] != '# ' + c:
            lines.insert(k, '# ' + c)
            k += 1
        lines[k + 1] = 'p 01 00000 00001 %04X' % (x >> 16)
        lines[k + 2] = 'p 01 00000 00001 %04X' % (x & 0xFFFF)
    return '\n'.join(lines)


def emit_listing(path):
    a = build()
    ws = a.words()
    assert ws[-1][0] < LIMIT, hex(ws[-1][0])
    out = [BEGIN, '#',
           '# MUL/IMUL/DIV/IDIV r/m8 and r/m16 (from the F6/F7 jump tables) as the',
           '# 8088 computes them, with its cycle count; see tools/gen_muldiv.py.']
    for l, ad in sorted(a.labels.items(), key=lambda kv: kv[1]):
        out.append(f'#   {ad:04X} {l}')
    out.append('#')
    for ad, x, c in ws:
        out.append('# ' + c)
        out += ['p 00 00000 00001 %04X' % ad, 'p 01 00000 00001 %04X' % (x >> 16),
                'p 01 00000 00001 %04X' % (x & 0xFFFF), '#']
    out.append(END)
    s = open(path).read()
    if BEGIN in s:
        i = s.index(BEGIN); j = s.index(END) + len(END)
        s = s[:i] + '\n'.join(out) + s[j:]
    else:
        s = s.rstrip('\n') + '\n#\n' + '\n'.join(out) + '\n'
    s = apply_patches(s, a)
    open(path, 'w').write(s)
    print(f'{len(ws)} words, {BASE:04X}-{ws[-1][0]:04X}', file=sys.stderr)
    return a


# ------------------------------------------------------------------ test

class Sim:
    """The MCL86 microsequencer subset the routines use."""
    def __init__(self, a):
        self.mem = {ad: x for ad, x, c in a.words()}
        self.labels = a.labels
        self.reg = [0] * 16
        self.c16 = self.c8 = 0
        self.last = 0
        self.rm = 0
        self.dout = 0
        self.ends = []
        self.syncs = []

    def op0(self, s):
        if s == SYS:
            return self.c16 | (self.c8 << 13)
        if s == F:
            return 0
        return self.reg[s]

    def op1(self, s, imm):
        if s == F:
            return imm
        if s == RM:
            return self.rm
        if s == SYS:
            return self.c16 | (self.c8 << 13)
        assert s >= 9, s
        return self.reg[s]

    def run(self, pc, limit=200000):
        stack = []
        for _ in range(limit):
            if pc in (0x093B, INT_ENTRY):
                return pc
            if pc == SUB_BYTE or pc == SUB_WORD:
                bits = 8 if pc == SUB_BYTE else 16
                self.flags_sub(self.reg[R0], self.reg[R1], bits)
                pc = stack.pop()
                continue
            x = self.mem[pc]
            t = (x >> 28) & 7; d = (x >> 24) & 15; o0 = (x >> 20) & 15; o1 = (x >> 16) & 15
            imm = x & 0xFFFF
            pc += 1
            if t == 0:
                if imm:
                    self.syncs.append(imm)
                continue
            if t == 1:
                tgt = x & 0x1FFF
                if x == 0x10300000:
                    pc = stack.pop(); continue
                cond = (x >> 16) & 15
                if (x >> 24) & 1:
                    stack.append(pc); assert len(stack) <= 4; pc = tgt; continue
                if cond == 0 or (cond == 1 and self.last) or (cond == 2 and not self.last):
                    pc = tgt
                continue
            A = self.op0(o0); B = self.op1(o1, imm)
            if t == 2:
                cin = (x >> 31) & self.reg[FL] & 1
                s = A + B + cin
                r = s & 0xFFFF
                self.c16 = s >> 16
                self.c8 = ((A ^ B ^ s) >> 8) & 1
            elif t == 3:
                r = ((A & 0xFF) << 8) | (A >> 8)
            elif t == 4:
                r = A & B
            elif t == 5:
                r = A | B
            elif t == 6:
                r = A ^ B
            else:
                r = A >> 1
            self.last = r
            if d == DOUT:
                self.dout = r
            elif d == CMD:
                if r & 0x3000 == 0x3000 and (r >> 4) & 15 == 4:
                    self.rm = self.dout
                if r & 0x3000 == 0x2000:
                    self.ends.append(self.dout)
                if r & 0x3000 == 0x3000 and (r >> 4) & 15 == 6:
                    self.ends.append(('rel', self.dout))
                self.reg[CMD] = r & 0xC003
            elif d != DUM:
                self.reg[d] = r
        raise RuntimeError('no end')

    def flags_sub(self, x, y, bits):
        m = (1 << bits) - 1
        x &= m; y &= m
        r = (x - y) & m
        f = self.reg[FL] & ~0x08D5
        if x < y: f |= 1
        if (x ^ y ^ r) & 0x10: f |= 0x10
        if ((x ^ y) & (x ^ r)) >> (bits - 1) & 1: f |= 0x800
        if r >> (bits - 1) & 1: f |= 0x80
        if r == 0: f |= 0x40
        if bin(r & 0xFF).count('1') % 2 == 0: f |= 0x04
        self.reg[FL] = f
        self.reg[R0] = r


def model_test(n):
    sys.path.insert(0, '/home/user/pcxt-work/scratch/cpuy/py')
    import mdmodel as M
    a = build()
    bad = 0
    rnd = random.Random(1)
    for k in range(n):
        for b in (8, 16):
            mm = (1 << b) - 1
            for op in ('MUL', 'IMUL', 'DIV', 'IDIV'):
                sim = Sim(a)
                ax = rnd.randrange(65536); dx = rnd.randrange(65536)
                v = rnd.randrange(1 << b)
                if rnd.random() < 0.1: v = rnd.choice([0, 1, mm, 1 << (b - 1)])
                rep = rnd.random() < 0.1
                regsurf = rnd.random() < 0.5
                sim.reg[AX] = ax; sim.reg[DX] = dx; sim.reg[R0] = v
                sim.reg[FL] = (2 if rep else 0) | (0x4000 if regsurf else 0)
                end = sim.run(sim.labels[f'{op}{b}'])
                signed = op.startswith('I')
                if 'MUL' in op:
                    cy, prod = M.mul(b, ax & mm, v, signed, rep)
                    want = (prod & 0xFFFF, dx) if b == 8 else (prod & 0xFFFF, prod >> 16)
                    got = (sim.reg[AX], sim.reg[DX])
                    ok = got == want and end == 0x093B
                else:
                    dd = (dx << 16 | ax) if b == 16 else ax
                    cy, r = M.div(b, dd, v, signed, rep)
                    if r is None:
                        ok = end == INT_ENTRY and (sim.reg[AX], sim.reg[DX]) == (ax, dx)
                        got = ('err', sim.ends); want = cy
                    else:
                        q, rem = r
                        want = (rem << 8 | q, dx) if b == 8 else (q, rem)
                        got = (sim.reg[AX], sim.reg[DX])
                        ok = got == want and end == 0x093B
                # cycles
                c = sim.reg[R3]   # shifted already
                if end == 0x093B:
                    e = sim.ends[-1]
                    if regsurf:
                        okc = e == 0xA000 + cy + 2
                    else:
                        okc = e == ((0xF000 + cy + 2 - 64) & 0xFFFF)
                else:
                    e = sim.ends[-1]
                    okc = e == ('rel', (cy + 6) | (0 if regsurf else 0x2000))
                if not (ok and okc):
                    bad += 1
                    if bad < 10:
                        print(op, b, hex(ax), hex(dx), hex(v), rep, regsurf, 'got', got, sim.ends, 'want', want, cy)
    print('bad', bad)


if __name__ == '__main__':
    if sys.argv[1] == '--test':
        model_test(int(sys.argv[2]) if len(sys.argv) > 2 else 500)
    else:
        emit_listing(sys.argv[1])
