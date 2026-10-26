onerror {puts "FAIL: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory brightness_contrast_work]} {vlib brightness_contrast_work}
vmap brightness_contrast_work brightness_contrast_work
set rtl ../src/user_source/hdl_source
vlog -work brightness_contrast_work -sv +incdir+$rtl/SD $rtl/param_menu_controller.v $rtl/param_config_service.v $rtl/brightness_contrast_adjust.v $rtl/SD/color_bar.v $rtl/pcm_gain_scale.v $rtl/media_hdmi_audio_bridge.v $rtl/status_osd_overlay.v $rtl/osd_overlay_24.v tb_brightness_contrast.sv tb_adjusted_video_alignment.sv
foreach test {tb_brightness_contrast tb_adjusted_video_alignment} {
    vsim -onfinish stop -voptargs=+acc brightness_contrast_work.$test
    run -all
    if {[examine -radix unsigned /$test/test_pass] != 1} {quit -code 1 -force}
    quit -sim
}
quit -code 0 -force
