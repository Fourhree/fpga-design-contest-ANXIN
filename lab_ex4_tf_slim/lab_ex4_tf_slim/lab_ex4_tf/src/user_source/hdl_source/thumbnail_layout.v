`timescale 1ns/1ps

// Maps a display pixel to one of six image banks.  The module is deliberately
// combinational: it can sit directly between the timing generator and the
// frame reader without adding a video-clock latency.
module thumbnail_layout #(
    parameter integer DISPLAY_WIDTH  = 640,
    parameter integer DISPLAY_HEIGHT = 480,
    parameter integer THUMB_WIDTH    = DISPLAY_WIDTH / 2,
    parameter integer THUMB_HEIGHT   = DISPLAY_HEIGHT / 3,
    parameter integer COORD_WIDTH    = 16,
    // The deployed top-level loader normalizes project images to 640x480.
    // Keep the generic path as the default for standalone users and tests,
    // while allowing that build to remove per-pixel multiply/divide logic.
    parameter integer NORMALIZED_MEDIA = 0
) (
    input  wire                   in_de,
    input  wire [11:0]            pixel_x,
    input  wire [11:0]            pixel_y,
    input  wire [2:0]             focus_index,
    input  wire [5:0]             image_complete,
    input  wire                   fullscreen,
    input  wire                   fullscreen_fit,
    input  wire [15:0]            current_width,
    input  wire [15:0]            current_height,
    input  wire [15:0]            image_width0,
    input  wire [15:0]            image_height0,
    input  wire [15:0]            image_width1,
    input  wire [15:0]            image_height1,
    input  wire [15:0]            image_width2,
    input  wire [15:0]            image_height2,
    input  wire [15:0]            image_width3,
    input  wire [15:0]            image_height3,
    input  wire [15:0]            image_width4,
    input  wire [15:0]            image_height4,
    input  wire [15:0]            image_width5,
    input  wire [15:0]            image_height5,
    output reg                    thumb_de,
    output reg  [2:0]             source_index,
    output reg  [COORD_WIDTH-1:0] source_x,
    output reg  [COORD_WIDTH-1:0] source_y,
    output reg                    focus_border
);
    integer cell_x, cell_y, local_x, local_y;
    integer mapped_x, mapped_y, selected_width, selected_height;
    integer cell_width, cell_height;
    // Exact for this design's bounded products (coordinate < destination,
    // source dimension <= 65535). Factoring 320=64*5 and 240=16*15 avoids
    // the long generic constant-divider chains produced by the tool.
    function [31:0] divide_320;
        input [31:0] value;
        reg [63:0] scaled;
        begin scaled=(value>>6)*64'd419431; divide_320=scaled>>21; end
    endfunction
    function [31:0] divide_240;
        input [31:0] value;
        reg [63:0] scaled;
        begin scaled=(value>>4)*64'd1118482; divide_240=scaled>>24; end
    endfunction
    function [31:0] divide_160;
        input [31:0] value;
        reg [63:0] scaled;
        begin scaled=(value>>5)*64'd1677722; divide_160=scaled>>23; end
    endfunction
    function [31:0] divide_640;
        input [31:0] value;
        reg [63:0] scaled;
        begin scaled=(value>>7)*64'd419431; divide_640=scaled>>21; end
    endfunction
    function [31:0] divide_480;
        input [31:0] value;
        reg [63:0] scaled;
        begin scaled=(value>>5)*64'd1118482; divide_480=scaled>>24; end
    endfunction

    always @* begin
        thumb_de     = 1'b0;
        source_index = focus_index;
        source_x     = {COORD_WIDTH{1'b0}};
        source_y     = {COORD_WIDTH{1'b0}};
        focus_border = 1'b0;
        cell_x=0; cell_y=0; local_x=0; local_y=0;
        mapped_x=0; mapped_y=0; selected_width=0; selected_height=0;
        cell_width=THUMB_WIDTH; cell_height=THUMB_HEIGHT;

        if (fullscreen) begin
            // Full-screen mode bypasses layout and reads the selected bank.
            selected_width  = (current_width  == 0) ? DISPLAY_WIDTH  : current_width;
            selected_height = (current_height == 0) ? DISPLAY_HEIGHT : current_height;
            if (NORMALIZED_MEDIA)
                source_x= pixel_x;
            else if (fullscreen_fit && DISPLAY_WIDTH==640)
                source_x=divide_640(pixel_x*selected_width);
            else source_x=fullscreen_fit ? (pixel_x*selected_width)/DISPLAY_WIDTH : pixel_x;
            if (NORMALIZED_MEDIA)
                source_y= pixel_y;
            else if (fullscreen_fit && DISPLAY_HEIGHT==480)
                source_y=divide_480(pixel_y*selected_height);
            else source_y=fullscreen_fit ? (pixel_y*selected_height)/DISPLAY_HEIGHT : pixel_y;
            thumb_de = in_de && image_complete[focus_index] &&
                       (fullscreen_fit || ((pixel_x < selected_width) && (pixel_y < selected_height)));
        end else if (in_de && pixel_x < DISPLAY_WIDTH && pixel_y < DISPLAY_HEIGHT) begin
            cell_width  = (THUMB_WIDTH  < 1) ? 1 : THUMB_WIDTH;
            cell_height = (THUMB_HEIGHT < 1) ? 1 : THUMB_HEIGHT;
            cell_x = (pixel_x >= cell_width) ? 1 : 0;
            cell_y = (pixel_y >= cell_height*2) ? 2 :
                     (pixel_y >= cell_height) ? 1 : 0;
            source_index = (cell_y << 1) | cell_x;
            local_x = pixel_x - cell_x * cell_width;
            local_y = pixel_y - cell_y * cell_height;

            case (source_index)
                3'd0: begin selected_width = image_width0; selected_height = image_height0; end
                3'd1: begin selected_width = image_width1; selected_height = image_height1; end
                3'd2: begin selected_width = image_width2; selected_height = image_height2; end
                3'd3: begin selected_width = image_width3; selected_height = image_height3; end
                3'd4: begin selected_width = image_width4; selected_height = image_height4; end
                default: begin selected_width = image_width5; selected_height = image_height5; end
            endcase
            if (selected_width == 0)  selected_width  = DISPLAY_WIDTH;
            if (selected_height == 0) selected_height = DISPLAY_HEIGHT;

            // Nearest-neighbour scaling.  The explicit integer division keeps
            // the mapping synthesizable and supports arbitrary source sizes.
            // All project media is normalized to 640x480.  Use exact
            // shift/add mappings for that common case so a display pixel
            // never traverses the generic multiplier/divider chain.  Keep
            // the generic path for any future non-standard image.
            mapped_x = NORMALIZED_MEDIA ?
                       (local_x << 1) :
                       (THUMB_WIDTH==320 && selected_width==DISPLAY_WIDTH) ?
                       (local_x << 1) :
                       THUMB_WIDTH==320 ? divide_320(local_x*selected_width) :
                       (local_x*selected_width)/cell_width;
            mapped_y = NORMALIZED_MEDIA ?
                       (local_y + (local_y << 1)) :
                       (THUMB_HEIGHT==160 && selected_height==DISPLAY_HEIGHT) ?
                       (local_y + (local_y << 1)) :
                       THUMB_HEIGHT==160 ? divide_160(local_y*selected_height) :
                       THUMB_HEIGHT==240 ? divide_240(local_y*selected_height) :
                       (local_y*selected_height)/cell_height;
            if (mapped_x >= selected_width)  mapped_x = selected_width - 1;
            if (mapped_y >= selected_height) mapped_y = selected_height - 1;
            source_x = mapped_x;
            source_y = mapped_y;
            thumb_de = image_complete[source_index] &&
                       (local_x < cell_width) && (local_y < cell_height);
            focus_border = (source_index == focus_index) &&
                           (local_x < 2 || local_y < 2 ||
                            local_x >= cell_width-2 || local_y >= cell_height-2);
        end
    end
endmodule
