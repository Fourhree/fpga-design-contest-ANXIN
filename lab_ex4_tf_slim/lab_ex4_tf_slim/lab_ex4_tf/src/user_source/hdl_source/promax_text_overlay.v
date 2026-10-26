`timescale 1ns/1ps

module promax_text_overlay #(
    parameter integer PARAM_X = 8,
    parameter integer PARAM_Y = 40,
    parameter integer SUBTITLE_Y = 72,
    parameter integer H_ACTIVE = 640,
    parameter integer SHOW_PARAMS = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,
    input  wire        subtitle_enable,
    input  wire [95:0] subtitle_text,
    input  wire [5:0]  subtitle_length,
    input  wire [7:0]  brightness,
    input  wire [7:0]  volume,
    input  wire [31:0] period_ms,
    input  wire        auto_enabled,
    input  wire        source_scale_2x,
    output wire [23:0] rgb_out,
    output wire        overlay_active
);
    localparam integer CELL_W = 12;
    localparam integer CELL_H = 16;
    localparam integer SUBTITLE_CELL_W = 18;
    localparam integer SUBTITLE_CELL_H = 18;
    localparam integer PARAM_CHARS = 32;
    localparam integer SCROLL_CYCLE = H_ACTIVE + 12 * SUBTITLE_CELL_W;
    reg [95:0] subtitle_text_frame;
    reg [34:0] subtitle_ascii_frame [0:11];
    reg [255:0] subtitle_chinese_frame [0:11];
    reg [5:0] subtitle_length_frame;
    reg subtitle_enable_frame;
    wire [9:0] subtitle_width = subtitle_length_frame * SUBTITLE_CELL_W;

    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    reg [9:0] scroll_pos;
    reg signed [10:0] subtitle_start_x;
    wire [9:0] next_scroll_pos = scroll_pos == SCROLL_CYCLE-1 ? 10'd0 : scroll_pos + 1'b1;
    integer latch_char, latch_row;
    reg [7:0] brightness_frame;
    reg [7:0] volume_frame;
    reg [31:0] period_frame;
    reg auto_frame;
    reg source_scale_2x_frame;
    wire frame_start = vs_q && !vsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
            scroll_pos <= 10'd0;
            subtitle_start_x <= 11'sd0;
            subtitle_text_frame <= 96'd0;
            for (latch_char = 0; latch_char < 12; latch_char = latch_char + 1) begin
                subtitle_ascii_frame[latch_char] <= 35'd0;
                subtitle_chinese_frame[latch_char] <= 256'd0;
            end
            subtitle_length_frame <= 6'd0;
            subtitle_enable_frame <= 1'b0;
            brightness_frame <= 8'd255;
            volume_frame <= 8'd255;
            period_frame <= 32'd5000;
            auto_frame <= 1'b0;
            source_scale_2x_frame <= 1'b0;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start) begin
                brightness_frame <= brightness;
                volume_frame <= volume;
                period_frame <= period_ms;
                auto_frame <= auto_enabled;
                source_scale_2x_frame <= source_scale_2x;
                subtitle_text_frame <= subtitle_text;
                subtitle_length_frame <= subtitle_length > 12 ? 6'd12 : subtitle_length;
                subtitle_enable_frame <= subtitle_enable;
                // Decode glyphs once per frame, outside the live pixel path.
                for (latch_char = 0; latch_char < 12; latch_char = latch_char + 1) begin
                    for (latch_row = 0; latch_row < 7; latch_row = latch_row + 1)
                        subtitle_ascii_frame[latch_char][latch_row*5 +: 5] <=
                            glyph_row(subtitle_text[latch_char*8 +: 8], latch_row);
                    for (latch_row = 0; latch_row < 16; latch_row = latch_row + 1)
                        subtitle_chinese_frame[latch_char][latch_row*16 +: 16] <=
                            chinese_glyph_row(subtitle_text[latch_char*8 +: 4], latch_row);
                end
                // Move left exactly one pixel per frame, never during active video.
                scroll_pos <= next_scroll_pos;
                // Precompute the signed origin instead of wrapping every pixel.
                subtitle_start_x <= next_scroll_pos < 12*SUBTITLE_CELL_W ?
                    -$signed({1'b0, next_scroll_pos}) : SCROLL_CYCLE-next_scroll_pos;
            end
        end
    end

    function [7:0] decimal_hundreds;
        input [7:0] value;
        begin
            decimal_hundreds = "0" + value / 100;
        end
    endfunction

    localparam [255:0] CN_GLYPH_0 = 256'b0000000110000000000100011000110000011001100110000000110110010000000010011001000000000001100000000111111111111110000000111100000000000111111000000000010110110000000011011001100000111001100011100110000110000010000000011000000000000001100000000000000000000000;
    localparam [255:0] CN_GLYPH_1 = 256'b0000000000101000011111110010100000010100111111100001010000101000011111100010100001010110111111100101011000000000010101100000000001100110011111000100001001000100011111100111110001000010010001000100001001000100011111100111110001000010010000000000000000000000;
    localparam [255:0] CN_GLYPH_2 = 256'b0000000100000000000000010000000000000001000000000011111111111000001000010000100000100001000010000011111111111000001000010000100000100001000010000011111111111000001111111111100000100001000000000000000100000010000000011111111000000000000000000000000000000000;
    localparam [255:0] CN_GLYPH_3 = 256'b0000000000000000001111111111110000000000001110000000000001100000000000011000000000000001100000000111111111111110011111111111100000000001100000000000000110000000000000011000000000000001100000000000000110000000000001110000000000000000000000000000000000000000;
    localparam [255:0] CN_GLYPH_4 = 256'b0000000000000000001111111111110000000001100000000000000110000000000000011000000000000001100000000000000110000000000000011000000000000001100000000000000110000000000000011000000000000001100000000111111111111110000000000000000000000000000000000000000000000000;
    localparam [255:0] CN_GLYPH_5 = 256'b0000110011000000000010001000000000011001100000000001000111111110001100110100000000110110010000000101000001111100010100000100000000010000010000000001000001000000000100000111111000010000010000000001000001000000000100000100000000010000010000000000000000000000;
    localparam [255:0] CN_GLYPH_6 = 256'b0000000100000000000000011000000001111111111111000110000000000100011000000000010000011111111110000000011000110000000011000001100000011111111011000000000110000000000111111111100000000001100000000000000110000000011111111111111000000000000000000000000000000000;
    localparam [255:0] CN_GLYPH_7 = 256'b0001000001000000000100000100100000010000010011000001010001001000011101011111111001010010011100000101000001110000000100000111000000010000111100000001000010110000000100001011000000010001101100000001001100110010000101100001111000000000000000000000000000000000;
    localparam [255:0] CN_GLYPH_8 = 256'b0000110000000000000010000011111001111111101001000001100000100100000100000010010000111111001001000111000100101100010111110010010000010001001000100001000100100010000111110010001000010001001011100001000100100000000100110010000000000000001000000000000000000000;

    function [15:0] chinese_glyph_row;
        input [3:0] glyph_id;
        input [3:0] row;
        reg [255:0] glyph_bits;
        begin
            case (glyph_id)
                4'd0: glyph_bits = CN_GLYPH_0;
                4'd1: glyph_bits = CN_GLYPH_1;
                4'd2: glyph_bits = CN_GLYPH_2;
                4'd3: glyph_bits = CN_GLYPH_3;
                4'd4: glyph_bits = CN_GLYPH_4;
                4'd5: glyph_bits = CN_GLYPH_5;
                4'd6: glyph_bits = CN_GLYPH_6;
                4'd7: glyph_bits = CN_GLYPH_7;
                4'd8: glyph_bits = CN_GLYPH_8;
                default: glyph_bits = 256'b0;
            endcase
            chinese_glyph_row = glyph_bits[255-row*16 -: 16];
        end
    endfunction

    function [7:0] decimal_tens;
        input [7:0] value;
        begin
            decimal_tens = "0" + (value % 100) / 10;
        end
    endfunction

    function [7:0] decimal_ones;
        input [7:0] value;
        begin
            decimal_ones = "0" + value % 10;
        end
    endfunction

    function [7:0] param_char;
        input integer index;
        reg [7:0] bright_percent;
        reg [7:0] period_seconds;
        begin
            case (brightness_frame)
                8'd255: bright_percent = 8'd100;
                8'd192: bright_percent = 8'd75;
                8'd128: bright_percent = 8'd50;
                default: bright_percent = 8'd25;
            endcase
            if (period_frame >= 30000)
                period_seconds = 8'd30;
            else if (period_frame >= 10000)
                period_seconds = 8'd10;
            else if (period_frame >= 5000)
                period_seconds = 8'd5;
            else
                period_seconds = 8'd2;

            case (index)
                0: param_char = "B";  1: param_char = "R";
                2: param_char = "T";
                3: param_char = decimal_hundreds(bright_percent);
                4: param_char = decimal_tens(bright_percent);
                5: param_char = decimal_ones(bright_percent);
                6: param_char = " ";  7: param_char = "V";
                8: param_char = "O";  9: param_char = "L";
                10: param_char = decimal_hundreds(volume_frame);
                11: param_char = decimal_tens(volume_frame);
                12: param_char = decimal_ones(volume_frame);
                13: param_char = " ";  14: param_char = "P";
                15: param_char = decimal_tens(period_seconds);
                16: param_char = decimal_ones(period_seconds);
                17: param_char = "S"; 18: param_char = " ";
                19: param_char = "M"; 20: param_char = ":";
                21: param_char = auto_frame ? "A" : "M";
                22: param_char = source_scale_2x_frame ? "1" : "6";
                23: param_char = source_scale_2x_frame ? "2" : "4";
                24: param_char = source_scale_2x_frame ? "8" : "0";
                25: param_char = source_scale_2x_frame ? "0" : "X";
                26: param_char = source_scale_2x_frame ? "X" : "4";
                27: param_char = source_scale_2x_frame ? "9" : "8";
                28: param_char = source_scale_2x_frame ? "6" : "0";
                29: param_char = source_scale_2x_frame ? "0" : " ";
                default: param_char = " ";
            endcase
        end
    endfunction

    function [4:0] glyph_row;
        input [7:0] character;
        input [2:0] row;
        begin
            glyph_row = 5'b00000;
            case (character)
                "0": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10011;3:glyph_row=5'b10101;4:glyph_row=5'b11001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "1": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b01100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "2": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00001;3:glyph_row=5'b00010;4:glyph_row=5'b00100;5:glyph_row=5'b01000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "3": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b00001;2:glyph_row=5'b00001;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "4": case(row) 0:glyph_row=5'b00010;1:glyph_row=5'b00110;2:glyph_row=5'b01010;3:glyph_row=5'b10010;4:glyph_row=5'b11111;5:glyph_row=5'b00010;6:glyph_row=5'b00010;default:glyph_row=0;endcase
                "5": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "6": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "7": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b01000;default:glyph_row=0;endcase
                "8": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "9": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01111;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "A": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "B": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "C": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b01111;default:glyph_row=0;endcase
                "D": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "E": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "F": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "G": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10000;3:glyph_row=5'b10111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "H": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "I": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "J": case(row) 0:glyph_row=5'b00111;1:glyph_row=5'b00010;2:glyph_row=5'b00010;3:glyph_row=5'b00010;4:glyph_row=5'b10010;5:glyph_row=5'b10010;6:glyph_row=5'b01100;default:glyph_row=0;endcase
                "K": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10010;2:glyph_row=5'b10100;3:glyph_row=5'b11000;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "L": case(row) 0:glyph_row=5'b10000;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "M": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11011;2:glyph_row=5'b10101;3:glyph_row=5'b10101;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "N": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11001;2:glyph_row=5'b10101;3:glyph_row=5'b10011;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "O": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "P": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "Q": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10101;5:glyph_row=5'b10010;6:glyph_row=5'b01101;default:glyph_row=0;endcase
                "R": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "S": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "T": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "U": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "V": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b01010;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "W": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10101;4:glyph_row=5'b10101;5:glyph_row=5'b10101;6:glyph_row=5'b01010;default:glyph_row=0;endcase
                "X": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b01010;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "Y": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "Z": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                ":": case(row) 1:glyph_row=5'b00100;2:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                ".": case(row) 5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                ",": case(row) 5:glyph_row=5'b00100;6:glyph_row=5'b01000;default:glyph_row=0;endcase
                "!": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                "?": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                "-": case(row) 3:glyph_row=5'b11111;default:glyph_row=0;endcase
                "_": case(row) 6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "/": case(row) 0:glyph_row=5'b00001;1:glyph_row=5'b00010;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction

    reg [9:0] param_local_x;
    reg [5:0] param_cell;
    reg [3:0] param_col;
    wire signed [10:0] subtitle_stream_x = $signed({1'b0, pixel_x}) - subtitle_start_x;
    reg [7:0] selected_char;
    reg [4:0] selected_row;
    reg param_pixel;
    wire [11:0] subtitle_cell_pixels;
    wire subtitle_pixel = |subtitle_cell_pixels;
    wire [3:0] chinese_row_index = line_y-SUBTITLE_Y-2;
    wire [2:0] ascii_row_index = (line_y-SUBTITLE_Y-2) >> 1;

    genvar cell_index;
    generate for (cell_index = 0; cell_index < 12; cell_index = cell_index + 1) begin: g_subtitle
        wire [4:0] col = subtitle_stream_x-cell_index*SUBTITLE_CELL_W;
        wire [3:0] ascii_col = (col-5'd4) >> 1;
        wire [4:0] ascii_row = subtitle_ascii_frame[cell_index][ascii_row_index*5 +: 5];
        wire [15:0] chinese_row = subtitle_chinese_frame[cell_index][chinese_row_index*16 +: 16];
        wire ascii_hit = col >= 4 && col < 14 && line_y >= SUBTITLE_Y+2 &&
            line_y < SUBTITLE_Y+16 && ascii_row[4-ascii_col];
        wire chinese_hit = col >= 1 && col < 17 && line_y >= SUBTITLE_Y+2 &&
            line_y < SUBTITLE_Y+18 && chinese_row[16-col];
        assign subtitle_cell_pixels[cell_index] = enable && subtitle_enable_frame && de &&
            pixel_x < H_ACTIVE && cell_index < subtitle_length_frame &&
            line_y >= SUBTITLE_Y && line_y < SUBTITLE_Y+SUBTITLE_CELL_H &&
            subtitle_stream_x >= cell_index*SUBTITLE_CELL_W &&
            subtitle_stream_x < (cell_index+1)*SUBTITLE_CELL_W &&
            (subtitle_text_frame[cell_index*8+7] ? chinese_hit : ascii_hit);
    end endgenerate

    always @* begin
        param_local_x = pixel_x - PARAM_X;
        param_cell = 0;
        param_col = 0;
        selected_char = " ";
        selected_row = 5'b00000;
        param_pixel = 1'b0;

        if (SHOW_PARAMS && enable && de && pixel_x >= PARAM_X &&
            pixel_x < PARAM_X + PARAM_CHARS*CELL_W &&
            line_y >= PARAM_Y && line_y < PARAM_Y + CELL_H) begin
            param_cell = param_local_x / CELL_W;
            param_col = (param_local_x - param_cell*CELL_W) >> 1;
            if (param_col < 5 && ((line_y-PARAM_Y) >> 1) < 7) begin
                selected_char = param_char(param_cell);
                selected_row = glyph_row(selected_char, (line_y-PARAM_Y) >> 1);
                param_pixel = selected_row[4-param_col];
            end
        end

    end

    assign overlay_active = param_pixel || subtitle_pixel;
    assign rgb_out = overlay_active ? 24'hfff080 : rgb_in;
endmodule
