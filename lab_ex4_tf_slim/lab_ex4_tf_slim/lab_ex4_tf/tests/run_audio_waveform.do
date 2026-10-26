onerror {puts "FAIL: waveform regression: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory waveform_work]} {vlib waveform_work}
vmap waveform_work waveform_work
vlog -work waveform_work -sv ../src/user_source/hdl_source/promax_audio_waveform.v tb_audio_waveform.sv
vsim -onfinish stop waveform_work.tb_audio_waveform
run -all
quit -code 0 -force
