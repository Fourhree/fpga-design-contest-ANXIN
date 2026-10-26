onerror {puts "FAIL: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory thumbnail_work]} {vlib thumbnail_work}
vmap thumbnail_work thumbnail_work
set rtl ../src/user_source/hdl_source
vlog -work thumbnail_work -sv $rtl/SD/bmp_stream_stretch.v
vlog -work thumbnail_work -sv +incdir+$rtl/SD $rtl/SD/color_bar.v $rtl/thumbnail_layout.v ../src/media_frame_reader.v ../src/media_frame_loader.v $rtl/SD/fifo_prefetch_2.v $rtl/SD/media_pixel_cdc.v $rtl/IP/afifo_32_16_256.v $rtl/SD/bmp_fat_reader.v $rtl/SD/fat32_file_streamer.v tb_thumbnail_display.sv tb_bmp_dynamic.sv tb_color_bar_coordinates.sv
vlog -work thumbnail_work -sv +incdir+$rtl/SD $rtl/SD/sd_card_bmp.v $rtl/SD/fat32_volume_scanner.v $rtl/SD/sd_sector_adapter.v $rtl/SD/sd_card_top.v $rtl/SD/sd_card_sec_read_write.v $rtl/SD/sd_card_cmd.v $rtl/SD/spi_master.v ../src/media_player_control.v tb_thumbnail_controls.sv
foreach test {tb_bmp_dynamic tb_thumbnail_display tb_color_bar_coordinates tb_thumbnail_controls} {
    vsim -onfinish stop -voptargs=+acc thumbnail_work.$test
    run -all
    if {[examine -radix unsigned /$test/test_pass] != 1} {quit -code 1 -force}
    quit -sim
}
quit -code 0 -force
