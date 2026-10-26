`timescale 1ns/1ps

module status_osd_overlay #(
    parameter integer OSD_X = 544,
    parameter integer OSD_Y = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,
    input  wire [2:0]  active_index,
    input  wire        auto_enabled,
    input  wire [7:0]  error_code,
    input  wire [7:0]  brightness,
    input  wire [7:0]  contrast,
    input  wire [7:0]  volume,
    input  wire        param_valid,
    input  wire        in_de,
    input  wire [11:0] in_rgb,
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    output reg  [11:0] out_rgb,
    output reg         out_de,
    output wire        osd_pixel
);
    localparam [4:0] CHAR_COLON   = 5'd13;
    localparam [4:0] CHAR_PERCENT = 5'd14;

    localparam [2:0] CJK_LIANG = 3'd0;
    localparam [2:0] CJK_DU    = 3'd1;
    localparam [2:0] CJK_DUI   = 3'd2;
    localparam [2:0] CJK_BI    = 3'd3;
    localparam [2:0] CJK_YIN   = 3'd4;
    localparam [2:0] CJK_LIANG2= 3'd5;

    reg [2:0] index_q;
    reg auto_q;
    reg [7:0] error_q;
    reg [7:0] brightness_q;
    reg [7:0] contrast_q;
    reg [7:0] volume_q;
    reg [6:0] brightness_pct;
    reg [6:0] contrast_pct;
    reg [6:0] volume_pct;
    reg param_valid_q;
    reg osd_hit;
    reg [4:0] char_value;
    reg [3:0] glyph_y;
    reg [6:0] local_x;
    reg [5:0] ascii_start;
    reg [2:0] ascii_col;
    reg [2:0] ascii_x;
    reg [1:0] text_row;
    reg [6:0] row_percent;
    reg [4:0] ascii_bits;
    reg [2:0] cjk_value;
    reg       cjk_valid;
    reg [15:0] cjk_bits;

    function [6:0] percent_of;
        input [7:0] value;
        reg [15:0] wide_value;
        reg [15:0] scaled;
        reg [16:0] quotient_sum;
        begin
            // Rounded value * 100 / 255. The constant multiply is expressed
            // as shifts/adds, and division by 255 uses an exact 16-bit fold.
            wide_value = {8'd0, value};
            scaled = (wide_value << 6) + (wide_value << 5) +
                     (wide_value << 2) + 16'd127;
            quotient_sum = {1'b0, scaled} + 17'd1 + (scaled >> 8);
            percent_of = quotient_sum >> 8;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            index_q <= 3'd0;
            auto_q <= 1'b0;
            error_q <= 8'd0;
            brightness_q <= 8'd192;
            contrast_q <= 8'd128;
            volume_q <= 8'd255;
            brightness_pct <= 7'd75;
            contrast_pct <= 7'd50;
            volume_pct <= 7'd100;
            param_valid_q <= 1'b0;
        end else if (frame_start) begin
            index_q <= active_index;
            auto_q <= auto_enabled;
            error_q <= error_code;
            brightness_q <= brightness;
            contrast_q <= contrast;
            volume_q <= volume;
            brightness_pct <= percent_of(brightness);
            contrast_pct <= percent_of(contrast);
            volume_pct <= percent_of(volume);
            param_valid_q <= param_valid;
        end
    end

    function [4:0] font_row;
        input [4:0] value;
        input [2:0] row;
        begin
            case (value)
                5'd0: case(row) 0:font_row=5'b11111;1:font_row=5'b10001;2:font_row=5'b10001;3:font_row=5'b10001;4:font_row=5'b10001;5:font_row=5'b10001;default:font_row=5'b11111; endcase
                5'd1: case(row) 0:font_row=5'b00100;1:font_row=5'b01100;2:font_row=5'b00100;3:font_row=5'b00100;4:font_row=5'b00100;5:font_row=5'b00100;default:font_row=5'b11111; endcase
                5'd2: case(row) 0:font_row=5'b11111;1:font_row=5'b00001;2:font_row=5'b00001;3:font_row=5'b11111;4:font_row=5'b10000;5:font_row=5'b10000;default:font_row=5'b11111; endcase
                5'd3: case(row) 0:font_row=5'b11111;1:font_row=5'b00001;2:font_row=5'b00001;3:font_row=5'b11111;4:font_row=5'b00001;5:font_row=5'b00001;default:font_row=5'b11111; endcase
                5'd4: case(row) 0:font_row=5'b10001;1:font_row=5'b10001;2:font_row=5'b10001;3:font_row=5'b11111;4:font_row=5'b00001;5:font_row=5'b00001;default:font_row=5'b00001; endcase
                5'd5: case(row) 0:font_row=5'b11111;1:font_row=5'b10000;2:font_row=5'b10000;3:font_row=5'b11111;4:font_row=5'b00001;5:font_row=5'b00001;default:font_row=5'b11111; endcase
                5'd6: case(row) 0:font_row=5'b11111;1:font_row=5'b10000;2:font_row=5'b10000;3:font_row=5'b11111;4:font_row=5'b10001;5:font_row=5'b10001;default:font_row=5'b11111; endcase
                5'd7: case(row) 0:font_row=5'b11111;1:font_row=5'b00001;2:font_row=5'b00010;3:font_row=5'b00100;4:font_row=5'b01000;5:font_row=5'b01000;default:font_row=5'b01000; endcase
                5'd8: case(row) 0:font_row=5'b11111;1:font_row=5'b10001;2:font_row=5'b10001;3:font_row=5'b11111;4:font_row=5'b10001;5:font_row=5'b10001;default:font_row=5'b11111; endcase
                5'd9: case(row) 0:font_row=5'b11111;1:font_row=5'b10001;2:font_row=5'b10001;3:font_row=5'b11111;4:font_row=5'b00001;5:font_row=5'b00001;default:font_row=5'b11111; endcase
                CHAR_COLON: case(row) 1:font_row=5'b00100;2:font_row=5'b00100;4:font_row=5'b00100;5:font_row=5'b00100;default:font_row=5'b00000; endcase
                CHAR_PERCENT: case(row) 0:font_row=5'b11001;1:font_row=5'b11010;2:font_row=5'b00100;3:font_row=5'b01000;4:font_row=5'b10110;5:font_row=5'b00110;default:font_row=5'b00000; endcase
                default: font_row = 5'b00000;
            endcase
        end
    endfunction

    function [15:0] cjk_font_row;
        input [2:0] value;
        input [3:0] row;
        begin
            case (value)
                CJK_LIANG: case (row)
                    0:cjk_font_row=16'h7ffc; 1:cjk_font_row=16'h0000;
                    2:cjk_font_row=16'h1ff0; 3:cjk_font_row=16'h1010;
                    4:cjk_font_row=16'h1ff0; 5:cjk_font_row=16'h0000;
                    6:cjk_font_row=16'h7ffe; 7:cjk_font_row=16'h4002;
                    8:cjk_font_row=16'h8fe4; 9:cjk_font_row=16'h0820;
                    10:cjk_font_row=16'h0820; 11:cjk_font_row=16'h1022;
                    12:cjk_font_row=16'h2022; 13:cjk_font_row=16'hc01e;
                    default:cjk_font_row=16'h0000;
                endcase
                CJK_DU: case (row)
                    0:cjk_font_row=16'h3ffe; 1:cjk_font_row=16'h2220;
                    2:cjk_font_row=16'h2220; 3:cjk_font_row=16'h3ffc;
                    4:cjk_font_row=16'h2220; 5:cjk_font_row=16'h2220;
                    6:cjk_font_row=16'h23e0; 7:cjk_font_row=16'h2000;
                    8:cjk_font_row=16'h2ff0; 9:cjk_font_row=16'h2410;
                    10:cjk_font_row=16'h4220; 11:cjk_font_row=16'h41c0;
                    12:cjk_font_row=16'h8630; 13:cjk_font_row=16'h380e;
                    default:cjk_font_row=16'h0000;
                endcase
                CJK_DUI: case (row)
                    0:cjk_font_row=16'h0010; 1:cjk_font_row=16'h7e10;
                    2:cjk_font_row=16'h02fe; 3:cjk_font_row=16'h0210;
                    4:cjk_font_row=16'h2410; 5:cjk_font_row=16'h1490;
                    6:cjk_font_row=16'h0850; 7:cjk_font_row=16'h0850;
                    8:cjk_font_row=16'h1410; 9:cjk_font_row=16'h1210;
                    10:cjk_font_row=16'h2210; 11:cjk_font_row=16'h4010;
                    12:cjk_font_row=16'h0050; 13:cjk_font_row=16'h0020;
                    default:cjk_font_row=16'h0000;
                endcase
                CJK_BI: case (row)
                    0:cjk_font_row=16'h2080; 1:cjk_font_row=16'h2084;
                    2:cjk_font_row=16'h2088; 3:cjk_font_row=16'h2090;
                    4:cjk_font_row=16'h3ea0; 5:cjk_font_row=16'h20c0;
                    6:cjk_font_row=16'h2080; 7:cjk_font_row=16'h2080;
                    8:cjk_font_row=16'h2080; 9:cjk_font_row=16'h2082;
                    10:cjk_font_row=16'h2682; 11:cjk_font_row=16'h3882;
                    12:cjk_font_row=16'h207e; default:cjk_font_row=16'h0000;
                endcase
                CJK_YIN: case (row)
                    0:cjk_font_row=16'h3ff8; 1:cjk_font_row=16'h0000;
                    2:cjk_font_row=16'h0820; 3:cjk_font_row=16'h0440;
                    4:cjk_font_row=16'hfffe; 5:cjk_font_row=16'h0000;
                    6:cjk_font_row=16'h1ff0; 7:cjk_font_row=16'h1010;
                    8:cjk_font_row=16'h1010; 9:cjk_font_row=16'h1ff0;
                    10:cjk_font_row=16'h1010; 11:cjk_font_row=16'h1010;
                    12:cjk_font_row=16'h1ff0; 13:cjk_font_row=16'h1010;
                    default:cjk_font_row=16'h0000;
                endcase
                CJK_LIANG2: case (row)
                    0:cjk_font_row=16'h1010; 1:cjk_font_row=16'h1ff0;
                    2:cjk_font_row=16'h1010; 3:cjk_font_row=16'hfffe;
                    4:cjk_font_row=16'h0000; 5:cjk_font_row=16'h1ff0;
                    6:cjk_font_row=16'h1110; 7:cjk_font_row=16'h1ff0;
                    8:cjk_font_row=16'h1110; 9:cjk_font_row=16'h1ff0;
                    10:cjk_font_row=16'h0100; 11:cjk_font_row=16'h1ff0;
                    12:cjk_font_row=16'h0100; 13:cjk_font_row=16'h7ffc;
                    default:cjk_font_row=16'h0000;
                endcase
                default: cjk_font_row = 16'h0000;
            endcase
        end
    endfunction

    always @* begin
        osd_hit = 1'b0;
        char_value = 5'd0;
        glyph_y = (pixel_y - OSD_Y) & 4'hf;
        local_x = pixel_x - OSD_X;
        text_row = (pixel_y - OSD_Y) >> 4;
        row_percent = brightness_pct;
        ascii_start = 6'd32;
        ascii_col = 3'd0;
        ascii_x = 3'd0;
        ascii_bits = 5'b00000;
        cjk_value = CJK_LIANG;
        cjk_valid = 1'b0;
        cjk_bits = 16'h0000;

        case (text_row)
            2'd0: row_percent = brightness_pct;
            2'd1: begin
                row_percent = contrast_pct;
                ascii_start = 6'd48;
            end
            default: row_percent = volume_pct;
        endcase

        if (pixel_x >= OSD_X && pixel_x < OSD_X + 88 &&
            pixel_y >= OSD_Y && pixel_y < OSD_Y + 48 && param_valid_q) begin
            if (local_x < ascii_start) begin
                case (text_row)
                    2'd0: begin
                        cjk_valid = local_x < 7'd32;
                        cjk_value = local_x[4] ? CJK_DU : CJK_LIANG;
                    end
                    2'd1: begin
                        cjk_valid = local_x < 7'd48;
                        case (local_x[5:4])
                            2'd0: cjk_value = CJK_DUI;
                            2'd1: cjk_value = CJK_BI;
                            default: cjk_value = CJK_DU;
                        endcase
                    end
                    default: begin
                        cjk_valid = local_x < 7'd32;
                        cjk_value = local_x[4] ? CJK_LIANG2 : CJK_YIN;
                    end
                endcase
                cjk_bits = cjk_font_row(cjk_value, glyph_y);
                if (cjk_valid)
                    osd_hit = cjk_bits[15 - local_x[3:0]];
            end else if (local_x < ascii_start + 7'd40) begin
                ascii_col = (local_x - ascii_start) >> 3;
                ascii_x = (local_x - ascii_start) & 3'h7;
                case (ascii_col)
                    0: char_value = CHAR_COLON;
                    1: char_value = row_percent == 7'd100 ? 5'd1 : 5'd0;
                    2: char_value = (row_percent % 100) / 10;
                    3: char_value = row_percent % 10;
                    4: char_value = CHAR_PERCENT;
                    default: char_value = 5'd0;
                endcase
                ascii_bits = font_row(char_value, glyph_y[3:1]);
                if (ascii_x < 5 && glyph_y < 14)
                    osd_hit = ascii_bits[4 - ascii_x];
            end
        end

        out_de = in_de;
        out_rgb = in_rgb;
        if (in_de && osd_hit)
            out_rgb = 12'h000;
    end

    assign osd_pixel = osd_hit && in_de;
endmodule
