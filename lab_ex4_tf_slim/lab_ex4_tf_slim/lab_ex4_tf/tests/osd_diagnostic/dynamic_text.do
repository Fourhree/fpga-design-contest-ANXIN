onerror {puts "FAIL: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory work]} {vlib work}
vmap work work
set rtl ../../src/user_source/hdl_source
vlog -sv $rtl/promax_text_overlay.v $rtl/timestamp_osd.v $rtl/dynamic_text_overlay.v tb_dynamic_text.sv
vsim -onfinish stop work.tb_dynamic_text
run -all
if {[examine -radix unsigned /tb_dynamic_text/test_pass] != 1} {quit -code 1 -force}
quit -code 0 -force
