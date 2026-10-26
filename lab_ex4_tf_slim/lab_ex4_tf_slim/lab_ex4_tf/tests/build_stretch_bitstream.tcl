set stretch_dir [file dirname [file normalize [info script]]]
set build_dir [file join $stretch_dir td_stretch_build]
set build_prefix player_stretch
source [file join $stretch_dir build_bitstream.tcl]
