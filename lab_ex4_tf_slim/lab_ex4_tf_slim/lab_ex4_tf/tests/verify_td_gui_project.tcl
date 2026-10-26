set test_dir [file dirname [file normalize [info script]]]
set project [file normalize [file join $test_dir ../src/td_project/lab_ex5_i2s_v1.0.al]]

if {[catch {
    open_project $project -single_run
    puts "PASS: TD opened GUI project $project"
} result]} {
    puts stderr "FAIL: TD could not open GUI project: $result"
    exit 1
}

exit 0
