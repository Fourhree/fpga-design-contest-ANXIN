# Generate a fresh bitstream from current sources in an isolated build folder.
if {[catch {
set test_dir [file dirname [file normalize [info script]]]
# Keep the same board and FIFO timing constraints as the GUI synthesis run.
set project [file normalize [file join $test_dir ../src/td_project/lab_ex5_i2s_v1.0.al]]
set project_dir [file dirname $project]
if {![info exists build_dir]} {set build_dir [file join $test_dir td_build]}
if {![info exists build_prefix]} {set build_prefix player_fixed}
file mkdir $build_dir
cd $build_dir
set input_file [open $project r]
set project_xml [read $input_file]
close $input_file
set project_xml [string map [list {Path="../} "Path=\"[file normalize [file join $project_dir ..]]/" {Path="al_ip/} "Path=\"$project_dir/al_ip/"] $project_xml]
set output_file [open lab_ex5_i2s_v1.0.prj w]
puts $output_file $project_xml
close $output_file
import_device eagle_s20.db -package EG4S20BG256
open_project lab_ex5_i2s_v1.0.prj
load_run_param -run phy_1
elaborate -top top
read_adc [file normalize [file join $test_dir ../src/user_source/constraints_source/pin.adc]]
read_sdc [file normalize [file join $test_dir ../src/user_source/constraints_source/timing.sdc]]
read_sdc -ip rfifo_32_32_512 [file normalize [file join $test_dir ../src/user_source/hdl_source/ip/afifo_32_16_256.tcl]]
read_sdc -ip wfifo_32_32_512 [file normalize [file join $test_dir ../src/user_source/hdl_source/ip/afifo_16_32_256.tcl]]
optimize_rtl
optimize_gate -packarea ${build_prefix}_gate.area
legalize_phy_inst
insert_debugger
# Load the same persistent physical parameters as the GUI run.
commit_param -step place
place
commit_param -step route
route
update_timing -mode final
report_timing_status -file ${build_prefix}_phy.ts
report_timing_summary -file ${build_prefix}_pr.timing
export_db ${build_prefix}_pr.db
bitgen -bit ${build_prefix}.bit
puts "PASS: fresh source-to-bitstream implementation completed"
} result]} {
    puts stderr "FAIL: $result"
    exit 1
}
exit 0
