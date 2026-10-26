onerror {puts "FAIL: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory stretch_work]} {vlib stretch_work}
vmap stretch_work stretch_work
set rtl ../src/user_source/hdl_source
vlog -work stretch_work -sv $rtl/SD/bmp_stream_stretch.v $rtl/SD/bmp_fat_reader.v $rtl/SD/fat32_file_streamer.v $rtl/SD/media_pixel_cdc.v $rtl/IP/afifo_32_16_256.v ../src/media_frame_loader.v tb_bmp_stretch.sv
vsim -onfinish stop -voptargs=+acc stretch_work.tb_bmp_stretch
run -all
if {[examine -radix unsigned /tb_bmp_stretch/test_pass] != 1} {quit -code 1 -force}
quit -code 0 -force
