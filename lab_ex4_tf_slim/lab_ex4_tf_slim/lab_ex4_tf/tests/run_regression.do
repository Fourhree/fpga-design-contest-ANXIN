onerror {puts "FAIL: regression Tcl command: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory work]} {vlib work}
vmap work work
set rtl ../src/user_source/hdl_source
vlog -sv +incdir+$rtl/SD $rtl/SD/color_bar.v $rtl/SD/video_timing_data.v $rtl/SD/video_delay.v
vlog -sv $rtl/hdmi_bch8.v $rtl/hdmi_audio_acr_packetizer.v $rtl/hdmi_data_island_mapper.v tb_hdmi_audio_format.sv
vlog -sv $rtl/SD/sd_card_bmp.v $rtl/SD/bmp_read.v $rtl/SD/sd_card_top.v $rtl/SD/sd_card_sec_read_write.v $rtl/SD/sd_card_cmd.v $rtl/SD/spi_master.v tb_player_controls.sv tb_sd_read_recovery.sv
vlog -sv $rtl/pcm_media_tone.v $rtl/audio_source_mux.v $rtl/pcm_gain_scale.v $rtl/sync_fade_gain.v $rtl/m06_pcm_contract_adapter.v $rtl/media_hdmi_audio_bridge.v $rtl/hdmi_audio_symbol_core.v $rtl/hdmi_audio_sample_packetizer.v $rtl/hdmi_audio_infoframe_packetizer.v $rtl/hdmi_avi_infoframe_packetizer.v $rtl/hdmi_audio_packet_scheduler.v $rtl/hdmi_data_island_scheduler.v $rtl/hdmi_tmds_channel_encoder.v $rtl/hdmi_terc4_encoder.v tb_audio_stream.sv tb_volume_fade.sv
vlog -sv $rtl/ip/afifo_16_32_256.v $rtl/SD/fat32_file_streamer.v $rtl/wav_stream_player.v tb_wav_stream_player.sv tb_audio_source_mux.sv tb_wav_hdmi_bridge.sv
vsim -onfinish stop -voptargs=+acc work.tb_hdmi_audio_format
run -all
if {[examine -radix unsigned /tb_hdmi_audio_format/test_pass] != 1} {quit -code 1 -force}
quit -sim
vsim -onfinish stop -voptargs=+acc work.tb_wav_stream_player
run -all
if {[examine -radix unsigned /tb_wav_stream_player/test_pass] != 1} {quit -code 1 -force}
quit -sim
vsim -onfinish stop -voptargs=+acc work.tb_audio_source_mux
run -all
if {[examine -radix unsigned /tb_audio_source_mux/test_pass] != 1} {quit -code 1 -force}
quit -sim
vsim -onfinish stop -voptargs=+acc work.tb_volume_fade
run -all
if {[examine -radix unsigned /tb_volume_fade/test_pass] != 1} {quit -code 1 -force}
quit -sim
vsim -onfinish stop -voptargs=+acc work.tb_wav_hdmi_bridge
run -all
if {[examine -radix unsigned /tb_wav_hdmi_bridge/test_pass] != 1} {quit -code 1 -force}
quit -sim
vsim -onfinish stop -voptargs=+acc work.tb_player_controls
run -all
if {[examine -radix unsigned /tb_player_controls/test_pass] != 1} {quit -code 1 -force}
quit -sim
vsim -onfinish stop -voptargs=+acc work.tb_sd_read_recovery
run -all
if {[examine -radix unsigned /tb_sd_read_recovery/test_pass] != 1} {quit -code 1 -force}
quit -sim
vsim -onfinish stop -voptargs=+acc work.tb_audio_stream
run -all
if {[examine -radix unsigned /tb_audio_stream/test_pass] != 1} {quit -code 1 -force}
quit -code 0 -force
