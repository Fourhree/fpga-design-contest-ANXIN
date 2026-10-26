`timescale 1ns/1ps

module promax_audio_waveform #(
    parameter integer WAVE_X = 64,
    parameter integer WAVE_Y = 400,
    parameter integer WAVE_WIDTH = 512,
    parameter integer WAVE_HEIGHT = 64,
    parameter integer DECIMATE = 12
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,
    input  wire        pcm_tap_valid,
    input  wire signed [15:0] pcm_tap_left,
    output wire [23:0] rgb_out,
    output wire        waveform_active
);
    localparam integer COLUMN_COUNT = 32;
    localparam integer COLUMN_GAP = 4;
    localparam integer COLUMN_PITCH = WAVE_WIDTH / COLUMN_COUNT;
    localparam integer COLUMN_WIDTH = COLUMN_PITCH - COLUMN_GAP;
    localparam [15:0] DISPLAY_NOISE_FLOOR = 16'd6144;
    localparam integer FADE_START_AGE = 18;
    localparam [4:0] LEVEL_WINDOW_LAST = 5'd31;

    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = vs_q && !vsync;

    // Average absolute level over 32 valid samples so isolated PCM spikes
    // cannot set a column's height.
    reg [15:0] frame_peak;
    reg [20:0] level_sum;
    reg [4:0] level_sample_count;
    reg [5:0] height_history [0:COLUMN_COUNT-1];
    reg [4:0] write_pointer;
    reg [5:0] valid_count;
    wire [15:0] pcm_magnitude = pcm_tap_left[15] ?
        (~pcm_tap_left + 1'b1) : pcm_tap_left;
    wire [20:0] level_sum_with_sample = level_sum + pcm_magnitude;
    wire [20:0] scaled_level_sum = level_sum_with_sample +
                                    (level_sum_with_sample >> 1);
    wire [15:0] block_level = scaled_level_sum[20:5];

    // Store heights in two-pixel units to keep the history compact for LUT RAM.
    function [5:0] magnitude_to_units;
        input [15:0] magnitude;
        begin
            if (magnitude <= DISPLAY_NOISE_FLOOR)
                magnitude_to_units = 6'd0;
            else if (magnitude >= 16'd32256)
                magnitude_to_units = 6'd32;
            else
                magnitude_to_units = {1'b0, magnitude[14:10]};
        end
    endfunction

    function [5:0] fade_loss_for_age;
        input [4:0] age;
        begin
            case (age)
                5'd22, 5'd23, 5'd24: fade_loss_for_age = 6'd1;
                5'd25: fade_loss_for_age = 6'd2;
                5'd26: fade_loss_for_age = 6'd3;
                5'd27: fade_loss_for_age = 6'd5;
                5'd28: fade_loss_for_age = 6'd8;
                5'd29: fade_loss_for_age = 6'd13;
                5'd30: fade_loss_for_age = 6'd21;
                5'd31: fade_loss_for_age = 6'd32;
                default: fade_loss_for_age = 6'd0;
            endcase
        end
    endfunction

    function [1:0] opacity_for_age;
        input [4:0] age;
        begin
            case (age)
                5'd22, 5'd23, 5'd24: opacity_for_age = 2'd2;
                5'd25, 5'd26, 5'd27: opacity_for_age = 2'd1;
                5'd28, 5'd29, 5'd30: opacity_for_age = 2'd0;
                5'd31: opacity_for_age = 2'd0;
                default: opacity_for_age = 2'd3;
            endcase
        end
    endfunction

    function [7:0] blend_channel;
        input [7:0] background;
        input [7:0] foreground;
        input [1:0] opacity;
        reg [9:0] weighted_sum;
        begin
            case (opacity)
                2'd3: begin
                    blend_channel = foreground;
                end
                2'd2: begin
                    weighted_sum = ({2'b00, foreground} << 1) +
                                   {2'b00, foreground} +
                                   {2'b00, background};
                    blend_channel = weighted_sum[9:2];
                end
                2'd1: begin
                    weighted_sum = {2'b00, foreground} +
                                   {2'b00, background};
                    blend_channel = weighted_sum[8:1];
                end
                default: begin
                    weighted_sum = {2'b00, foreground} +
                                   {2'b00, background} +
                                   ({2'b00, background} << 1);
                    blend_channel = weighted_sum[9:2];
                end
            endcase
        end
    endfunction

    wire [5:0] captured_units = magnitude_to_units(frame_peak);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
            frame_peak <= 16'd0;
            level_sum <= 21'd0;
            level_sample_count <= 5'd0;
            write_pointer <= 5'd0;
            valid_count <= 6'd0;
        end else begin
            de_q <= de;
            vs_q <= vsync;

            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (!enable) begin
                frame_peak <= 16'd0;
                level_sum <= 21'd0;
                level_sample_count <= 5'd0;
                write_pointer <= 5'd0;
                valid_count <= 6'd0;
            end else begin
                if (frame_start) begin
                // The circular history avoids a 31-stage parallel register
                // shift. Column age supplies screen position and fade amount.
                    height_history[write_pointer] <= captured_units;
                    write_pointer <= write_pointer + 1'b1;
                    if (valid_count < COLUMN_COUNT)
                        valid_count <= valid_count + 1'b1;
                    frame_peak <= 16'd0;
                end

                if (pcm_tap_valid) begin
                    if (level_sample_count == LEVEL_WINDOW_LAST) begin
                        level_sum <= 21'd0;
                        level_sample_count <= 5'd0;
                        if (!frame_start && block_level > frame_peak)
                            frame_peak <= block_level;
                    end else begin
                        level_sum <= level_sum_with_sample;
                        level_sample_count <= level_sample_count + 1'b1;
                    end
                end
            end
        end
    end

    integer column_index;
    integer column_offset;
    integer history_age;
    integer column_top;
    reg [4:0] history_index;
    reg [5:0] stored_units;
    reg [5:0] visible_units;
    reg [5:0] fade_loss;
    reg [1:0] opacity_level;
    reg column_pixel;

    always @* begin
        column_index = 0;
        column_offset = 0;
        history_age = 0;
        column_top = WAVE_Y + WAVE_HEIGHT;
        fade_loss = 6'd0;
        opacity_level = 2'd3;
        history_index = 5'd0;
        stored_units = 6'd0;
        visible_units = 6'd0;
        column_pixel = 1'b0;

        if (enable && de &&
            pixel_x >= WAVE_X && pixel_x < WAVE_X+WAVE_WIDTH &&
            line_y >= WAVE_Y && line_y < WAVE_Y+WAVE_HEIGHT) begin
            column_index = (pixel_x-WAVE_X) / COLUMN_PITCH;
            column_offset = (pixel_x-WAVE_X) -
                            column_index*COLUMN_PITCH;
            history_age = COLUMN_COUNT - 1 - column_index;
            history_index = write_pointer - 1'b1 - history_age;

            // valid_count masks uninitialized or stale RAM contents after
            // reset/disable, preventing random pixels from reaching video.
            if (history_age < valid_count) begin
                stored_units = height_history[history_index];
                if (history_age > FADE_START_AGE) begin
                    fade_loss = fade_loss_for_age(history_age[4:0]);
                    opacity_level = opacity_for_age(history_age[4:0]);
                    if (stored_units > fade_loss)
                        visible_units = stored_units - fade_loss;
                end else begin
                    visible_units = stored_units;
                end
            end

            column_top = WAVE_Y + WAVE_HEIGHT -
                         {visible_units, 1'b0};
            column_pixel = column_offset < COLUMN_WIDTH &&
                           visible_units != 0 &&
                           line_y >= column_top;
        end
    end

    assign waveform_active = column_pixel;
    assign rgb_out = column_pixel ?
                     {blend_channel(rgb_in[23:16], 8'd31, opacity_level),
                      blend_channel(rgb_in[15:8], 8'd107, opacity_level),
                      blend_channel(rgb_in[7:0], 8'd50, opacity_level)} :
                     rgb_in;

endmodule
