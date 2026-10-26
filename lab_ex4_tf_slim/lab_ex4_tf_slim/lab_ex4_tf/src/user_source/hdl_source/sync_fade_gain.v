`timescale 1ns/1ps

module sync_fade_gain #(
    parameter integer SYNC_STAGES = 2
) (
    input  wire       pix_clk,
    input  wire       pix_rst_n,
    input  wire       frame_start,
    input  wire [7:0] alpha_pix,
    input  wire       fade_active,

    input  wire       aud_clk,
    input  wire       aud_rst_n,
    output reg  [7:0] gain_aud
);
    reg [7:0] alpha_latch;
    reg       fade_latch;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            alpha_latch <= 8'd255;
            fade_latch <= 1'b0;
        end else if (frame_start) begin
            alpha_latch <= alpha_pix;
            fade_latch <= fade_active;
        end
    end

    (* async_reg = "true" *) reg [7:0] sync1, sync2;
    (* async_reg = "true" *) reg fsync1, fsync2;
    reg [7:0] seen_alpha;
    reg       seen_fade;

    always @(posedge aud_clk or negedge aud_rst_n) begin
        if (!aud_rst_n) begin
            sync1 <= 8'd255;
            sync2 <= 8'd255;
            fsync1 <= 1'b0;
            fsync2 <= 1'b0;
            seen_alpha <= 8'd255;
            seen_fade <= 1'b0;
            gain_aud <= 8'd255;
        end else begin
            sync1 <= alpha_latch;
            sync2 <= sync1;
            fsync1 <= fade_latch;
            fsync2 <= fsync1;

            if (sync2 != seen_alpha) begin
                seen_alpha <= sync2;
                gain_aud <= sync2;
            end else if (!fsync2 && seen_fade) begin
                seen_fade <= 1'b0;
                gain_aud <= 8'd255;
            end else if (fsync2) begin
                seen_fade <= 1'b1;
                gain_aud <= sync2;
            end
        end
    end
endmodule
