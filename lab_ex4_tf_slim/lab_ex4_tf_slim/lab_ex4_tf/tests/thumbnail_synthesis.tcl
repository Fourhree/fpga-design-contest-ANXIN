set test_dir [file dirname [file normalize [info script]]]
set project [file normalize [file join $test_dir ../src/td_project/lab_ex5_i2s_v1.0.al]]
set project_dir [file dirname $project]
set build_dir [file join $test_dir thumbnail_build]
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
elaborate -top top
read_adc [file normalize [file join $test_dir ../src/user_source/constraints_source/pin.adc]]
read_sdc [file normalize [file join $test_dir ../src/user_source/constraints_source/timing.sdc]]
optimize_rtl
report_area -file thumbnail_rtl.area
optimize_gate -packarea thumbnail_gate.area
legalize_phy_inst
export_db thumbnail_gate.db
puts "PASS: thumbnail top elaboration and gate synthesis"
exit
