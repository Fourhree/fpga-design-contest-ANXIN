`timescale 1ns/1ps

// Two-stage elastic PCM gain pipeline. Both WAV and generated-tone samples
// pass through this block after source selection. Registering between volume
// and fade multiplication keeps each 25 MHz path to one multiply/divide stage.
module pcm_gain_scale (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               in_valid,
    output wire               in_ready,
    input  wire signed [15:0] pcm_left_in,
    input  wire signed [15:0] pcm_right_in,
    input  wire               boost_3x,
    input  wire               boost_8x,
    input  wire        [7:0]  volume,
    input  wire        [7:0]  fade_gain,
    output reg                out_valid,
    input  wire               out_ready,
    output reg signed [15:0]  pcm_left_out,
    output reg signed [15:0]  pcm_right_out
);
    reg stage1_valid;
    reg signed [15:0] stage1_left;
    reg signed [15:0] stage1_right;
    reg [7:0] stage1_fade;
    reg stage1_boost_3x;
    reg stage1_boost_8x;

    function signed [15:0] apply_gain;
        input signed [15:0] sample;
        input        [7:0]  gain;
        reg signed [31:0] product;
        reg        [31:0] magnitude;
        reg        [32:0] folded;
        reg        [31:0] quotient;
        begin
            product = sample * $signed({1'b0, gain});
            magnitude = product < 0 ? -product : product;
            // Exact unsigned /255 over the 24-bit product range.
            folded = magnitude + 1'b1;
            folded = folded + (folded >> 8);
            folded = folded + (folded >> 16);
            quotient = folded >> 8;
            apply_gain = product < 0 ? -$signed(quotient[15:0]) : quotient[15:0];
        end
    endfunction

    function signed [15:0] apply_gain_boost;
        input signed [15:0] sample;
        input        [7:0]  gain;
        input               boost3;
        input               boost8;
        reg signed [31:0] product;
        reg        [31:0] magnitude;
        reg        [32:0] folded;
        reg        [31:0] quotient;
        begin
            product = sample * $signed({1'b0, gain});
            if (boost8)
                product = product <<< 3;
            else if (boost3)
                product = product + (product <<< 1);
            magnitude = product < 0 ? -product : product;
            folded = magnitude + 1'b1;
            folded = folded + (folded >> 8);
            folded = folded + (folded >> 16);
            quotient = folded >> 8;
            if (quotient > 32'd32767)
                apply_gain_boost = product < 0 ? 16'sh8000 : 16'sh7fff;
            else
                apply_gain_boost = product < 0 ? -$signed(quotient[15:0]) : quotient[15:0];
        end
    endfunction

    wire advance_output = !out_valid || out_ready;
    assign in_ready = !stage1_valid || advance_output;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage1_valid <= 1'b0;
            stage1_left <= 16'sd0;
            stage1_right <= 16'sd0;
            stage1_fade <= 8'd255;
            stage1_boost_3x <= 1'b0;
            stage1_boost_8x <= 1'b0;
            out_valid <= 1'b0;
            pcm_left_out <= 16'sd0;
            pcm_right_out <= 16'sd0;
        end else begin
            if (advance_output) begin
                out_valid <= stage1_valid;
                if (stage1_valid) begin
                    pcm_left_out <= apply_gain_boost(stage1_left, stage1_fade,
                                                     stage1_boost_3x,
                                                     stage1_boost_8x);
                    pcm_right_out <= apply_gain_boost(stage1_right, stage1_fade,
                                                      stage1_boost_3x,
                                                      stage1_boost_8x);
                end
            end

            if (in_ready) begin
                stage1_valid <= in_valid;
                if (in_valid) begin
                    stage1_left <= apply_gain(pcm_left_in, volume);
                    stage1_right <= apply_gain(pcm_right_in, volume);
                    stage1_fade <= fade_gain;
                    stage1_boost_3x <= boost_3x;
                    stage1_boost_8x <= boost_8x;
                end
            end
        end
    end
endmodule
