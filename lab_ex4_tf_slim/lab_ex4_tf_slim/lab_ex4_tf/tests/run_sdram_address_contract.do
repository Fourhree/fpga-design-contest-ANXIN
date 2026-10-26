onerror {puts "FAIL: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory thumbnail_work]} {vlib thumbnail_work}
vmap thumbnail_work thumbnail_work
set rtl ../src/user_source/hdl_source
# Preserve the existing 32-bit interpretation of the vendor unsized constant.
vlog -work thumbnail_work -sv -suppress 2121 +incdir+$rtl/include $rtl/SD/sdram_refresh_scheduler.v $rtl/include/sdr_as_ram.enc.v $rtl/include/sdr_init_ref.enc.v $rtl/include/sdr_wrrd.enc.v tb_sdram_address_contract.sv
vsim -onfinish stop -voptargs=+acc thumbnail_work.tb_sdram_address_contract
run -all
if {[examine -radix unsigned /tb_sdram_address_contract/test_pass] != 1} {quit -code 1 -force}
quit -code 0 -force
