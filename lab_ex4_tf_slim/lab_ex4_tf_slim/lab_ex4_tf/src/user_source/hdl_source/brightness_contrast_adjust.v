`timescale 1ns/1ps

// Seven-stage pixel pipeline: centered impulse suppression, brightness/
// contrast and clipping.  The first stage delays the timing by one pixel so
// the filter can inspect both neighbours of the pixel it is correcting.
// Brightness 192 (75%) is unity: RGB*brightness/192. Values above 192
// brighten the image and saturate at 255 before the contrast transform.
// RGB and the entire HDMI timing bundle have the same seven-clock latency.
// Controls come from the frame configuration service; each pixel carries
// its sampled parameters through the arithmetic pipeline.
module brightness_contrast_adjust (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [23:0] rgb_in,
    input  wire        in_de,
    input  wire        in_hsync,
    input  wire        in_vsync,
    input  wire        in_line_active,
    input  wire [9:0]  in_pixel_x,
    input  wire [7:0]  brightness,
    input  wire [7:0]  contrast,
    output reg  [23:0] rgb_out,
    output wire        out_de,
    output wire        out_hsync,
    output wire        out_vsync,
    output wire        out_line_active,
    output wire [9:0]  out_pixel_x
);
    reg [23:0] filtered_rgb0;
    reg [7:0] brightness_r0, contrast_r0;
    reg [23:0] history1, history2;
    reg [1:0] history_count;
    reg input_de_q, input_hsync_q, input_vsync_q, input_line_q;
    reg [9:0] input_x_q;
    reg [15:0] brightness_product_r1;
    reg [15:0] brightness_product_g1;
    reg [15:0] brightness_product_b1;
    reg [7:0] contrast_r1;
    reg signed [8:0] center_r2, center_g2, center_b2;
    reg [7:0] contrast_r2;
    reg signed [17:0] contrast_product_r3;
    reg signed [17:0] contrast_product_g3;
    reg signed [17:0] contrast_product_b3;
    reg signed [9:0] result_r4, result_g4, result_b4;
    reg [5:0] de_pipe, hs_pipe, vs_pipe, line_pipe;
    reg [9:0] x1, x2, x3, x4, x5, x6;

    function [7:0] absdiff8;
        input [7:0] a;
        input [7:0] b;
        begin
            absdiff8 = a >= b ? a - b : b - a;
        end
    endfunction

    function [7:0] median8;
        input [7:0] a;
        input [7:0] b;
        input [7:0] c;
        begin
            if (a > b)
                median8 = b > c ? b : (a > c ? c : a);
            else
                median8 = a > c ? a : (b > c ? c : b);
        end
    endfunction

    // Correct the middle sample only when its two neighbours agree and the
    // middle sample is a large outlier.  Delaying the timing by one pixel
    // keeps the corrected sample at its original screen coordinate.
    function [7:0] suppress_impulse;
        input [7:0] older;
        input [7:0] previous;
        input [7:0] current;
        begin
            if (absdiff8(older, current) <= 8'd40 &&
                absdiff8(previous, older) >= 8'd48 &&
                absdiff8(previous, current) >= 8'd48)
                suppress_impulse = median8(older, previous, current);
            else
                suppress_impulse = previous;
        end
    endfunction

    wire history_ready = in_de && input_de_q && in_pixel_x >= 10'd2 &&
                         history_count == 2'd2;
    wire [23:0] impulse_filtered = history_ready ? {
        suppress_impulse(history2[23:16], history1[23:16], rgb_in[23:16]),
        suppress_impulse(history2[15:8],  history1[15:8],  rgb_in[15:8]),
        suppress_impulse(history2[7:0],   history1[7:0],   rgb_in[7:0])
    } : history1;

    function [7:0] clamp8;
        input signed [9:0] value;
        begin
            if (value < 0)
                clamp8 = 8'd0;
            else if (value > 255)
                clamp8 = 8'd255;
            else
                clamp8 = value[7:0];
        end
    endfunction

    // 683/131072 approximates 1/192 with about 0.05% error. Expressing the
    // constant multiply as shifts/adds avoids a generic divider in TD.
    function [9:0] divide_192;
        input [15:0] value;
        reg [25:0] wide;
        reg [25:0] scaled;
        begin
            wide = {10'd0, value};
            scaled = (wide << 9) + (wide << 7) + (wide << 5) +
                     (wide << 3) + (wide << 1) + wide;
            divide_192 = scaled >> 17;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            filtered_rgb0 <= 24'd0;
            brightness_r0 <= 8'd192;
            contrast_r0 <= 8'd128;
            history1 <= 24'd0;
            history2 <= 24'd0;
            history_count <= 2'd0;
            input_de_q <= 1'b0;
            input_hsync_q <= 1'b1;
            input_vsync_q <= 1'b1;
            input_line_q <= 1'b0;
            input_x_q <= 10'd0;
            brightness_product_r1 <= 16'd0;
            brightness_product_g1 <= 16'd0;
            brightness_product_b1 <= 16'd0;
            contrast_r1 <= 8'd128;
            center_r2 <= 9'sd0; center_g2 <= 9'sd0; center_b2 <= 9'sd0;
            contrast_r2 <= 8'd128;
            contrast_product_r3 <= 18'sd0;
            contrast_product_g3 <= 18'sd0;
            contrast_product_b3 <= 18'sd0;
            result_r4 <= 10'sd0; result_g4 <= 10'sd0; result_b4 <= 10'sd0;
            rgb_out <= 24'd0;
            de_pipe <= 6'b000000; line_pipe <= 6'b000000;
            hs_pipe <= 6'b111111; vs_pipe <= 6'b111111;
            x1 <= 0; x2 <= 0; x3 <= 0; x4 <= 0; x5 <= 0; x6 <= 0;
        end else begin
            // Stage 0: output the previous pixel after checking it against
            // the current pixel. During the first blanking clock, history1
            // flushes the final active pixel without treating black as a
            // neighbour.
            filtered_rgb0 <= input_de_q ? impulse_filtered : 24'd0;
            brightness_r0 <= brightness;
            contrast_r0 <= contrast;
            input_de_q <= in_de;
            input_hsync_q <= in_hsync;
            input_vsync_q <= in_vsync;
            input_line_q <= in_line_active;
            input_x_q <= in_pixel_x;
            if (!in_de) begin
                history_count <= 2'd0;
            end else if (in_pixel_x == 10'd0) begin
                history1 <= rgb_in;
                history2 <= rgb_in;
                history_count <= 2'd1;
            end else begin
                history2 <= history1;
                history1 <= rgb_in;
                if (history_count != 2'd2)
                    history_count <= history_count + 1'b1;
            end
            // Stage 1: per-channel brightness multiplier; 192 is unity.
            brightness_product_r1 <= filtered_rgb0[23:16] * brightness_r0;
            brightness_product_g1 <= filtered_rgb0[15:8]  * brightness_r0;
            brightness_product_b1 <= filtered_rgb0[7:0]   * brightness_r0;
            contrast_r1 <= contrast_r0;
            // Stage 2: divide by 192, saturate, then center around 128.
            center_r2 <= $signed({1'b0, clamp8($signed(divide_192(brightness_product_r1)))}) - 9'sd128;
            center_g2 <= $signed({1'b0, clamp8($signed(divide_192(brightness_product_g1)))}) - 9'sd128;
            center_b2 <= $signed({1'b0, clamp8($signed(divide_192(brightness_product_b1)))}) - 9'sd128;
            contrast_r2 <= contrast_r1;
            // Stage 3: centered contrast multiplier, /128 via arithmetic shift.
            contrast_product_r3 <= center_r2 * $signed({1'b0, contrast_r2});
            contrast_product_g3 <= center_g2 * $signed({1'b0, contrast_r2});
            contrast_product_b3 <= center_b2 * $signed({1'b0, contrast_r2});
            // Stage 4: restore the midpoint and saturate to the RGB range.
            result_r4 <= (contrast_product_r3 >>> 7) + 10'sd128;
            result_g4 <= (contrast_product_g3 >>> 7) + 10'sd128;
            result_b4 <= (contrast_product_b3 >>> 7) + 10'sd128;
            // Stage 5: clip rather than wrapping, and keep blanking black.
            rgb_out <= de_pipe[4] ?
                {clamp8(result_r4), clamp8(result_g4), clamp8(result_b4)} : 24'd0;
            de_pipe <= {de_pipe[4:0], input_de_q};
            hs_pipe <= {hs_pipe[4:0], input_hsync_q};
            vs_pipe <= {vs_pipe[4:0], input_vsync_q};
            line_pipe <= {line_pipe[4:0], input_line_q};
            x1 <= input_x_q; x2 <= x1; x3 <= x2; x4 <= x3; x5 <= x4; x6 <= x5;
        end
    end

    assign out_de = de_pipe[5];
    assign out_hsync = hs_pipe[5];
    assign out_vsync = vs_pipe[5];
    assign out_line_active = line_pipe[5];
    assign out_pixel_x = x6;
endmodule
