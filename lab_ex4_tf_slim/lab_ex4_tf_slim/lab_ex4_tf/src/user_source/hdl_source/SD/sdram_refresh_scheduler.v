`timescale 1ns / 1ps

module sdram_refresh_scheduler #(
    parameter integer REFRESH_INTERVAL_CYCLES = 3125
) (
    input  wire clk,
    input  wire rst,
    input  wire init_done,
    input  wire refresh_active,
    input  wire request_allowed,
    output reg  refresh_pending,
    output reg  refresh_request
);

reg [31:0] refresh_counter;

always @(posedge clk) begin
    if (rst || !init_done) begin
        refresh_counter <= 32'd0;
        refresh_pending <= 1'b0;
        refresh_request <= 1'b0;
    end else begin
        if ((REFRESH_INTERVAL_CYCLES <= 1) ||
            (refresh_counter >= REFRESH_INTERVAL_CYCLES - 1))
            refresh_counter <= 32'd0;
        else
            refresh_counter <= refresh_counter + 1'b1;

        if (refresh_active) begin
            refresh_pending <= 1'b0;
            refresh_request <= 1'b0;
        end else begin
            if ((REFRESH_INTERVAL_CYCLES <= 1) ||
                (refresh_counter >= REFRESH_INTERVAL_CYCLES - 1))
                refresh_pending <= 1'b1;
            if (refresh_pending && request_allowed)
                refresh_request <= 1'b1;
        end
    end
end

endmodule
