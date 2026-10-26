onerror {puts "FAIL: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory work]} {vlib work}
vmap work work
set rtl ../src/user_source/hdl_source
vlog -sv $rtl/SD/sd_card_bmp.v $rtl/SD/bmp_read.v $rtl/SD/sd_card_top.v $rtl/SD/sd_card_sec_read_write.v $rtl/SD/sd_card_cmd.v $rtl/SD/spi_master.v $rtl/SD/frame_fifo_write.v tb_bmp_header_validation.sv tb_bmp_read_errors.sv tb_player_controls.sv tb_sd_read_recovery.sv tb_frame_writer.sv
foreach test {tb_bmp_header_validation tb_bmp_read_errors tb_player_controls tb_sd_read_recovery tb_frame_writer} {
    vsim -onfinish stop -voptargs=+acc work.$test
    run -all
    if {[examine -radix unsigned /$test/test_pass] != 1} {quit -code 1 -force}
    quit -sim
}
quit -code 0 -force
