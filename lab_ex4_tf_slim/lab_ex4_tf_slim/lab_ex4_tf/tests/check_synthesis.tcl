# Run from tests. Keep verification outputs separate from the user's TD runs.
set test_dir [file dirname [file normalize [info script]]]
set project [file normalize [file join $test_dir ../src/td_project/lab_ex5_i2s_v1.0.al]]
set build_dir [file join $test_dir td_check]
file mkdir $build_dir
cd $build_dir
# TD's command-line project reader expects run-style .prj paths. Generate a
# build-only copy with absolute source paths, leaving the GUI project intact.
set project_dir [file dirname $project]
set input_file [open $project r]
set project_xml [read $input_file]
close $input_file
set project_xml [string map [list {Path="../} "Path=\"[file normalize [file join $project_dir ..]]/" {Path="al_ip/} "Path=\"$project_dir/al_ip/"] $project_xml]
set check_project [file join $build_dir lab_ex5_i2s_v1.0.prj]
set output_file [open $check_project w]
puts $output_file $project_xml
close $output_file
import_device eagle_s20.db -package EG4S20BG256
open_project $check_project
elaborate -top top
read_adc [file normalize [file join $test_dir ../src/user_source/constraints_source/pin.adc]]
read_sdc [file normalize [file join $test_dir ../src/user_source/constraints_source/timing.sdc]]
optimize_rtl
report_area -file fixed_rtl.area
optimize_gate -packarea fixed_gate.area
legalize_phy_inst
export_db fixed_gate.db
puts "PASS: player top elaboration and gate synthesis"
exit
