onerror {puts "FAIL: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory fat_compat_work]} {vlib fat_compat_work}
vmap fat_compat_work fat_compat_work
set rtl ../src/user_source/hdl_source
vlog -work fat_compat_work -sv $rtl/IP/afifo_16_32_256.v $rtl/SD/fat32_file_streamer.v $rtl/wav_stream_player.v tb_wav_stream_player.sv
vsim -onfinish stop -voptargs=+acc fat_compat_work.tb_wav_stream_player
run -all
if {[examine -radix unsigned /tb_wav_stream_player/test_pass] != 1} {quit -code 1 -force}
quit -code 0 -force
