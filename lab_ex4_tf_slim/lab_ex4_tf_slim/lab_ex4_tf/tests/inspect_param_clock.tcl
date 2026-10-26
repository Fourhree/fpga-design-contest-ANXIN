set test_dir [file dirname [file normalize [info script]]]
cd [file join $test_dir brightness_contrast_check]
import_device eagle_s20.db -package EG4S20BG256
open_project lab_ex5_i2s_v1.0.prj -noanalyze
import_db brightness_contrast_gate.db
write_verilog brightness_contrast_gate.v
exit
