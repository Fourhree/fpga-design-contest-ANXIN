onerror {puts "FAIL: $errorInfo"; quit -code 1 -force}
onbreak {resume}
if {![file isdirectory image6_key4_work]} {vlib image6_key4_work}
vmap image6_key4_work image6_key4_work
set rtl ../src/user_source/hdl_source
vlog -work image6_key4_work -sv $rtl/param_menu_controller.v tb_image6_key4_lock.sv
vsim -onfinish stop -voptargs=+acc image6_key4_work.tb_image6_key4_lock
run -all
if {[examine -radix unsigned /tb_image6_key4_lock/test_pass] != 1} {
    quit -code 1 -force
}
quit -code 0 -force
