onerror {puts "FAIL: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory refresh_work]} {vlib refresh_work}
vmap refresh_work refresh_work
set rtl ../src/user_source/hdl_source
vlog -work refresh_work -sv $rtl/SD/sdram_refresh_scheduler.v tb_sdram_refresh_scheduler.sv
vsim -onfinish stop -voptargs=+acc refresh_work.tb_sdram_refresh_scheduler
run -all
if {[examine -radix unsigned /tb_sdram_refresh_scheduler/test_pass] != 1} {quit -code 1 -force}
quit -code 0 -force
