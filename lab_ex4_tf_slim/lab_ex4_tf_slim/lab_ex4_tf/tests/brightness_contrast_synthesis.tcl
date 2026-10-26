# Validate the current RTL and gate synthesis without assigning an unknown
# reset pad or replacing an existing download bitstream.
set test_dir [file dirname [file normalize [info script]]]
set project [file normalize [file join $test_dir ../src/td_project/lab_ex5_i2s_v1.0.al]]
set project_dir [file dirname $project]
set build_dir [file join $test_dir brightness_contrast_check]
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
report_area -file brightness_contrast_rtl.area
optimize_gate -packarea brightness_contrast_gate.area
export_db brightness_contrast_gate.db
puts "PASS: brightness/contrast top elaboration and gate synthesis"
exit
