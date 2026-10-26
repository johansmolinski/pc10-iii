# PC10-III (from Megamiga): put new QNICE firmware into an implemented design without synthesis.
#
# Called by patch_firmware.sh (see there), not directly:
#   vivado -mode batch -source patch_firmware.tcl -tclargs <dcp> <out.bit> \
#          <rom ref.hex> <rom new.hex> <rodata ref.hex|-> <rodata new.hex|-> \
#          <banks ref.hex|-> <banks new.hex|->
#
# The .hex files hold one 16-bit word per line (patch_firmware.sh converts the .rom
# files); patch_firmware.py computes the INIT strings. For each memory (the QNICE ROM, and the read-only data RAM when it is in
# block RAM) the script finds the RAMB cells of that memory in the routed checkpoint,
# checks that their INIT_xx equal the REFERENCE contents (the firmware the checkpoint was
# built with: a wrong checkpoint or a wrong bit mapping stops here), sets the INIT_xx of
# the NEW contents and writes the bitstream. Nothing else of the design changes.
#
# Supported cell shapes: any READ_WIDTH whose data bits cover the cell's slice without
# parity bits (Vivado maps the 32K x 16 QNICE ROM to 16 RAMB36 of 32K x 1, slice = bit).

set dcp     [lindex $argv 0]
set outbit  [lindex $argv 1]
set rom_ref [lindex $argv 2]
set rom_new [lindex $argv 3]
set rod_ref [lindex $argv 4]
set rod_new [lindex $argv 5]
set bnk_ref [lindex $argv 6]
set bnk_new [lindex $argv 7]

# the shape of a cell: data bits per address (no parity), slice, address range, bits
proc cell_shape {c} {
   set rw  [get_property READ_WIDTH_A $c]
   set wd  [expr {$rw >= 9 ? $rw / 9 * 8 : $rw}]
   set sb  [get_property ram_slice_begin $c]
   set se  [get_property ram_slice_end $c]
   set ab  [get_property ram_addr_begin $c]
   set ae  [get_property ram_addr_end $c]
   if {$se - $sb + 1 > $wd} { error "$c: [expr {$se - $sb + 1}] bits per address, only $wd data bits (parity not supported)" }
   set nbits [expr {[string match RAMB36* [get_property REF_NAME $c]] ? 32768 : 16384}]
   if {($ae - $ab + 1) * $wd > $nbits} { error "$c: address range $ab..$ae does not fit" }
   return "$wd $sb $se $ab $ae $nbits"
}

# a property value 256'hXXXX..., possibly without leading zeros, as 64 hex digits
proc norm {v} {
   regsub {^256'h} $v {} v
   return [format %064s [string toupper $v]]
}

proc patch_mem {name pattern ref new} {
   set cells [get_cells -hier -filter "REF_NAME =~ RAMB* && NAME =~ $pattern"]
   if {[llength $cells] == 0} { return 0 }
   # the INIT strings are computed by patch_firmware.py (Tcl is slow at bit work)
   set shapes [file join [file dirname $ref] shapes.txt]
   set inits  [file join [file dirname $ref] inits.txt]
   set fh [open $shapes w]
   foreach c $cells { puts $fh "$c [cell_shape $c]" }
   close $fh
   exec python3 [file join [file dirname [info script]] patch_firmware.py] $ref $new $shapes $inits
   set fh [open $inits r]
   while {[gets $fh l] >= 0} { set val([lindex $l 0],[lindex $l 1]) [lrange $l 2 end] }
   close $fh
   foreach c $cells {
      set iref $val($c,ref)
      for {set k 0} {$k < [llength $iref]} {incr k} {
         set pn [format INIT_%02X $k]
         if {[norm [get_property $pn $c]] ne [lindex $iref $k]} {
            error "PATCH: $name: $c $pn does not hold the reference firmware - wrong checkpoint or reference .rom?"
         }
      }
      set inew $val($c,new)
      for {set k 0} {$k < [llength $inew]} {incr k} {
         set_property [format INIT_%02X $k] "256'h[lindex $inew $k]" $c
      }
   }
   puts "PATCH: $name: [llength $cells] block RAMs verified against the reference and patched"
   return [llength $cells]
}

open_checkpoint $dcp

if {[patch_mem "QNICE ROM" "*QNICE_SOC/rom/*" $rom_ref $rom_new] == 0} {
   error "PATCH: the QNICE ROM block RAMs were not found"
}
if {$rod_ref ne "-"} {
   if {[patch_mem "read-only data" "CORE/i_rodata/*" $rod_ref $rod_new] == 0} {
      error "PATCH: the read-only data changed, but it is not in block RAM in this build (LUT ROM): synthesize"
   }
}

# Megamiga code banks (M2M-UPSTREAM code-banks): the bank ROM behind the window 0x9000
if {$bnk_new ne "-"} {
   if {$bnk_ref eq "-"} {
      error "PATCH: the firmware has code banks, but this build was saved without a bank image (older build): synthesize"
   }
   if {[patch_mem "code banks" "*QNICE_SOC/g_codebanks.codebanks/*" $bnk_ref $bnk_new] == 0} {
      error "PATCH: the firmware has code banks, but this build has no code bank ROM: synthesize"
   }
}

write_bitstream -force $outbit
puts "PATCH: OK $outbit"
