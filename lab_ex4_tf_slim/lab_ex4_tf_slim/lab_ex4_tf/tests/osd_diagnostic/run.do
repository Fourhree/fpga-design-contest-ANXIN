onerror {puts "FAIL: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory work]} {vlib work}
vmap work work
set rtl ../../src/user_source/hdl_source
vlog -sv +incdir+$rtl/SD $rtl/SD/color_bar.v $rtl/pcm_gain_scale.v $rtl/media_hdmi_audio_bridge.v $rtl/status_osd_overlay.v $rtl/osd_overlay_24.v $rtl/promax_text_overlay.v $rtl/timestamp_osd.v $rtl/dynamic_text_overlay.v tb_osd_display.sv
vsim -onfinish stop work.tb_osd_display
run -all
if {[examine -radix unsigned /tb_osd_display/test_pass] != 1} {quit -code 1 -force}
quit -code 0 -force
