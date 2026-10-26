onerror {puts "FAIL: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory thumbnail_work]} {vlib thumbnail_work}
vmap thumbnail_work thumbnail_work
set rtl ../src/user_source/hdl_source
vlog -work thumbnail_work -sv +incdir+$rtl/SD $rtl/thumbnail_layout.v ../src/media_frame_reader.v $rtl/SD/fifo_prefetch_2.v $rtl/IP/afifo_32_16_256.v tb_thumbnail_display.sv
vsim -onfinish stop -voptargs=+acc -gW=640 -gH=480 -gFULL=1 -gMEM_HALF_PERIOD=5 thumbnail_work.tb_thumbnail_display
run -all
if {[examine -radix unsigned /tb_thumbnail_display/test_pass] != 1} {quit -code 1 -force}
quit -code 0 -force
