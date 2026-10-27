## PC10-III for MEGA65
##
## Core specific constraints (M2M/common.xdc and M2M/MEGA65-R6.xdc hold the framework's)
##
## Based on the M2M template and Megamiga's CORE/CORE.xdc; licensed under GPL v3

## The PC's one clock, 28.63636 MHz (CORE/vhdl/clk.vhd): the PC10-III's master clock, also M2M's
## video clock (one net, main.vhd hands the video over on it).
create_generated_clock -name main_clk [get_pins CORE/clk_gen/i_clk_main/CLKOUT0]

## ascal asynchronous FIFO data crossings (Megamiga CORE.xdc, framework paths; hard rule 5):
## i_dpram is written on i_clk (= main_clk) and read on avl_clk (= hr_clk), o_dpram is written
## on avl_clk and read on o_clk (= hdmi_clk). The LUTRAM primitives launch from their /CLK
## pins, which common.xdc's register false paths do not match; bound them to one destination
## period instead of the impossible edge-alignment requirement (and its hold-fix detours).
set_max_delay -datapath_only 10.000 \
   -from [get_pins -hierarchical -regexp {.*/i_ascal/i_dpram_reg.*/CLK}] \
   -to   [get_cells -hierarchical -regexp {.*/i_ascal/avl_dr_reg\[[0-9]+\]}]
set_max_delay -datapath_only 13.400 \
   -from [get_pins -hierarchical -regexp {.*/i_ascal/o_dpram_reg.*/CLK}] \
   -to   [get_cells -hierarchical -regexp {.*/i_ascal/o_dr_reg\[[0-9]+\]}]

## qnice_clk (50 MHz) <-> main_clk (28.63636 MHz): two MMCMs, no common period. All
## crossings are synchronizers, cdc_stable or the framework's own CDCs; bound them to one
## qnice period (max_delay, not false_path, so the tighter cdc_stable bounds of common.xdc
## stay in force).
set_max_delay -datapath_only 20.000 -from [get_clocks qnice_clk] -to [get_clocks main_clk]
set_max_delay -datapath_only 20.000 -from [get_clocks main_clk] -to [get_clocks qnice_clk]

## M2M-UPSTREAM sd-host: the native 4-bit SD bus needs pull-ups on CMD and DAT0..DAT3 of both
## slots. Port names are the SPI ones of the board XDCs: mosi = CMD, miso = DAT0, reset = DAT3.
set_property -dict {PULLUP TRUE} [get_ports {sd_mosi_o sd_miso_i sd_d1_i sd_d2_i sd_reset_o}]
set_property -dict {PULLUP TRUE} [get_ports {sd2_mosi_o sd2_miso_i sd2_d1_i sd2_d2_i sd2_reset_o}]


## The serial and parallel ports on the PMOD headers (pc_ports.vhd, doc/ports.md): RXD and
## /ACK pulled up (idle), /CTS and BUSY pulled down, so an unconnected input reads "clear to
## send" and "printer not busy" (Megamiga pulls /CTS up: its Amiga serial.device ignores it,
## the PC's BIOS INT 14h waits for it). The inputs are asynchronous and go through a 2-FF
## ASYNC_REG synchronizer; the outputs are slow, no I/O delay constraints.
set_property -dict {PULLUP TRUE}   [get_ports {p1lo_io[2] p1hi_io[2]}]
set_property -dict {PULLDOWN TRUE} [get_ports {p1lo_io[0] p1hi_io[1]}]
