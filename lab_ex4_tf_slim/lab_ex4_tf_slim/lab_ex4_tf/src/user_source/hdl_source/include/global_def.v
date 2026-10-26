


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

`define   SDR_CLK_PERIOD                   10
// 64 ms / 2048 rows / 10 ns at the fixed 100 MHz SDRAM clock.
// Keep this literal because TD evaluates the former exponent expression as 0.
`define   SELF_REFRESH_INTERVAL            3125

