onerror {quit -code 1 -force}
onbreak {resume}
run -all
if {[examine -radix unsigned /tb_bmp_stretch/test_pass] != 1} {quit -code 1 -force}
quit -code 0 -force
