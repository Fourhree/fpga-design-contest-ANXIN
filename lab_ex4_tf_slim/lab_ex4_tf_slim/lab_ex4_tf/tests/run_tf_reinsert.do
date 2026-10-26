onerror {puts "FAIL: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory work]} {vlib work}
vmap work work
set rtl ../src/user_source/hdl_source/SD
vlog -sv $rtl/sd_card_bmp.v $rtl/bmp_read.v $rtl/sd_card_top.v $rtl/sd_card_sec_read_write.v $rtl/sd_card_cmd.v $rtl/spi_master.v tb_tf_reinsert.sv
vsim -onfinish stop -voptargs=+acc work.tb_tf_reinsert
run -all
if {[examine -radix unsigned /tb_tf_reinsert/test_pass] != 1} {quit -code 1 -force}
quit -code 0 -force
