`timescale 1ns / 1ps
// 单比特两级触发器同步器
// 用于跨时钟域的慢变电平信号同步
module sync_2ff #(
    parameter RESET_VAL = 1'b0
)(
    input  wire clk,       // 目的时钟域
    input  wire rst_n,     // 目的域低有效复位
    input  wire async_in,  // 异步输入（源域电平）
    output wire sync_out   // 同步后的输出
);

    (* async_reg = "true" *) reg s1, s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1 <= RESET_VAL;
            s2 <= RESET_VAL;
        end else begin
            s1 <= async_in;
            s2 <= s1;
        end
    end

    assign sync_out = s2;

endmodule