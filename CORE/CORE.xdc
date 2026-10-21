## PC10-III for MEGA65
##
## Core specific constraints (M2M/common.xdc and M2M/MEGA65-R6.xdc hold the framework's)
##
## Based on the M2M template and Megamiga's CORE/CORE.xdc; licensed under GPL v3

## The PC's one clock: 100.2273 MHz, and M2M's video clock: 28.63636 MHz (CORE/vhdl/clk.vhd), both
## from one MMCM: related clocks, so the RGBI crossing (main.vhd p_video) is timed as a synchronous
## path (a pixel = 7 main clocks = 2 video clocks).
create_generated_clock -name main_clk  [get_pins CORE/clk_gen/i_clk_main/CLKOUT1]
create_generated_clock -name video_clk [get_pins CORE/clk_gen/i_clk_main/CLKOUT0]

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

## qnice_clk (50 MHz) <-> main_clk (100.2273 MHz): two MMCMs, no common period. All
## crossings are synchronizers, cdc_stable or the framework's own CDCs; bound them to one
## qnice period (max_delay, not false_path, so the tighter cdc_stable bounds of common.xdc
## stay in force).
set_max_delay -datapath_only 20.000 -from [get_clocks qnice_clk] -to [get_clocks main_clk]
set_max_delay -datapath_only 20.000 -from [get_clocks main_clk] -to [get_clocks qnice_clk]
set_max_delay -datapath_only 20.000 -from [get_clocks qnice_clk] -to [get_clocks video_clk]
set_max_delay -datapath_only 20.000 -from [get_clocks video_clk] -to [get_clocks qnice_clk]

## The floppy geometry (pc_fdd_sd.vhd, cdc_stable into main_clk) only changes when the firmware
## sets up a drive, and the FDC card drops its buffer at every command: its paths into the FDC's
## LBA arithmetic get 4 clocks.
set_multicycle_path -setup 4 -from [get_cells -hierarchical -filter {NAME =~ CORE/i_pc_fdd_sd/i_cdc_geo/*dst_data_o_reg*}]
set_multicycle_path -hold 3 -from [get_cells -hierarchical -filter {NAME =~ CORE/i_pc_fdd_sd/i_cdc_geo/*dst_data_o_reg*}]

## M2M-UPSTREAM sd-host: the native 4-bit SD bus needs pull-ups on CMD and DAT0..DAT3 of both
## slots. Port names are the SPI ones of the board XDCs: mosi = CMD, miso = DAT0, reset = DAT3.
set_property -dict {PULLUP TRUE} [get_ports {sd_mosi_o sd_miso_i sd_d1_i sd_d2_i sd_reset_o}]
set_property -dict {PULLUP TRUE} [get_ports {sd2_mosi_o sd2_miso_i sd2_d1_i sd2_d2_i sd2_reset_o}]
