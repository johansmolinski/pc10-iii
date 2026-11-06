# The sign-off gates of a routed (or opened) design: constraints that silently no-op when
# instance names drift. Sourced by build_bitstream.tcl and reroll_bitstream.tcl, so a first
# pass and a re-roll are signed off the same way. Returns a list of failures (empty = pass).
proc signoff_gates {} {
    set gate {}
    foreach {clk want} {main_clk 34.921} {
        set c [get_clocks -quiet $clk]
        if {[llength $c] == 0} {
            lappend gate "generated clock $clk missing"
        } elseif {[expr {abs([get_property PERIOD $c] - $want)}] > 0.01} {
            lappend gate "$clk period [get_property PERIOD $c] ns, expected $want ns"
        }
    }
    if {[llength [get_cells -quiet -hierarchical -filter {NAME =~ CORE/i_pc_ram/* && REF_NAME =~ RAMB*}]] < 160} {
        lappend gate "pc_ram has fewer than 160 block RAM primitives (640 KB optimised away?)"
    }
    return $gate
}
