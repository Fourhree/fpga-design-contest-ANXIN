`timescale 1ns/1ps

module frame_blend #(
    parameter integer ALPHA_STEP = 32
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start_effect,
    input  wire        frame_start,
    input  wire [11:0] rgb_a,
    input  wire [11:0] rgb_b,
    output reg  [11:0] rgb_out,
    output reg  [7:0]  alpha,
    output reg         effect_active
);
    integer mix_r;
    integer mix_g;
    integer mix_b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alpha <= 8'd0;
            effect_active <= 1'b0;
        end else begin
            if (start_effect) begin
                alpha <= 8'd0;
                effect_active <= 1'b1;
            end else if (frame_start && effect_active) begin
                if (alpha + ALPHA_STEP >= 255) begin
                    alpha <= 8'd255;
                    effect_active <= 1'b0;
                end else begin
                    alpha <= alpha + ALPHA_STEP;
                end
            end
        end
    end
    always @* begin
        mix_r = (rgb_a[11:8] * (255-alpha) + rgb_b[11:8] * alpha + 127) / 255;
        mix_g = (rgb_a[7:4] * (255-alpha) + rgb_b[7:4] * alpha + 127) / 255;
        mix_b = (rgb_a[3:0] * (255-alpha) + rgb_b[3:0] * alpha + 127) / 255;
        rgb_out = {mix_r[3:0], mix_g[3:0], mix_b[3:0]};
    end
endmodule
