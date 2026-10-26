`timescale 1ns / 1ps

module sync_2ff #(
    parameter RESET_VAL = 1'b0
) (
    input  wire clk,
    input  wire rst_n,
    input  wire async_in,
    output wire sync_out
);

    (* async_reg = "true" *) reg sync_ff1;
    (* async_reg = "true" *) reg sync_ff2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_ff1 <= RESET_VAL;
            sync_ff2 <= RESET_VAL;
        end else begin
            sync_ff1 <= async_in;
            sync_ff2 <= sync_ff1;
        end
    end

    assign sync_out = sync_ff2;

endmodule
