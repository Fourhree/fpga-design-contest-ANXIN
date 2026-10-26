onerror {puts "FAIL: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory integrity_work]} {vlib integrity_work}
vmap integrity_work integrity_work
set rtl ../src/user_source/hdl_source
vlog -work integrity_work -sv +incdir+$rtl/SD ../src/media_frame_loader.v ../src/media_frame_reader.v $rtl/SD/fifo_prefetch_2.v $rtl/IP/afifo_32_16_256.v tb_media_storage_integrity.sv
foreach test {tb_media_loader_integrity tb_media_reader_integrity} {
    vsim -onfinish stop -voptargs=+acc integrity_work.$test
    run -all
    if {[examine -radix unsigned /$test/test_pass] != 1} {quit -code 1 -force}
    quit -sim
}
quit -code 0 -force
