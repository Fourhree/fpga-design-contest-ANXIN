`timescale 1ns/1ps

// Stretch a row-major BMP stream using nearest-neighbour sampling. Only one
// destination row is stored, so the source need not fit an SDRAM image bank.
// in_ready pauses the buffered FAT byte stream while a row is repeated/output.
module bmp_stream_stretch #(
    parameter integer DEST_WIDTH = 640,
    parameter integer DEST_HEIGHT = 480,
    parameter integer OUTPUT_GAP = 6
)(
    input clk, rst, start,
    input [15:0] source_width, source_height,
    input bottom_up,
    input in_valid,
    input [23:0] in_rgb,
    output in_ready,
    output reg out_valid,
    output reg [23:0] out_rgb,
    output reg output_done
);
    localparam RECEIVE=3'd0, FILL=3'd1, READ_ROW=3'd2,
               SEND=3'd3, GAP=3'd4, INIT_WIDTH=3'd5,
               INIT_HEIGHT=3'd6, INIT_Y=3'd7;
    localparam X_FRAC_BITS=$clog2(DEST_WIDTH+1);
    localparam Y_FRAC_BITS=$clog2(DEST_HEIGHT+1);
    reg [2:0] state;
    reg [23:0] line_pixels [0:DEST_WIDTH-1];
    reg [23:0] held_pixel, line_read;
    reg [15:0] width, input_x, input_y, held_x, selected_row_y;
    reg [15:0] init_x_remainder, init_y_remainder;
    reg source_bottom_up;
    reg held_last;
    reg [15:0] want_x, want_y, x_step, y_step;
    reg [X_FRAC_BITS-1:0] x_fraction, x_remainder;
    reg [Y_FRAC_BITS-1:0] y_fraction, y_remainder;
    reg [9:0] fill_x, emit_x;
    reg [8:0] emit_y;
    reg [7:0] gap_count;
    wire [X_FRAC_BITS:0] x_sum = {1'b0,x_remainder}+{1'b0,x_fraction};
    wire [Y_FRAC_BITS:0] y_sum = {1'b0,y_remainder}+{1'b0,y_fraction};
    wire [16:0] next_want_x = {1'b0,want_x}+{1'b0,x_step}+(x_sum>=DEST_WIDTH);
    wire [16:0] next_want_y = {1'b0,want_y}+{1'b0,y_step}+(y_sum>=DEST_HEIGHT);
    assign in_ready = state == RECEIVE;

    // Synchronous row RAM read/write allows inference of FPGA block memory.
    always @(posedge clk) begin
        if (state == FILL) line_pixels[fill_x] <= held_pixel;
        if (state == READ_ROW) line_read <= line_pixels[emit_x];
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state<=RECEIVE; width<=0; input_x<=0; input_y<=0;
            init_x_remainder<=0; init_y_remainder<=0; source_bottom_up<=0;
            held_pixel<=0; held_x<=0; held_last<=0; selected_row_y<=0;
            want_x<=0; want_y<=0; x_step<=0; y_step<=0;
            x_fraction<=0; y_fraction<=0; x_remainder<=0; y_remainder<=0;
            fill_x<=0; emit_x<=0; emit_y<=0; gap_count<=0;
            out_valid<=0; out_rgb<=0; output_done<=0;
        end else begin
            out_valid<=0;
            if (start) begin
                state<=INIT_WIDTH; width<=source_width;
                init_x_remainder<=source_width; init_y_remainder<=source_height;
                source_bottom_up<=bottom_up;
                input_x<=0; input_y<=0; want_x<=0; fill_x<=0;
                emit_x<=0; emit_y<=0; output_done<=0; gap_count<=0;
                x_step<=0; y_step<=0; x_fraction<=0; y_fraction<=0;
                x_remainder<=0; want_y<=0; y_remainder<=0;
            end else case (state)
                // Setup takes at most 241 clocks at 640x480, once per load.
                // Iterative constant subtraction avoids a wide combinational
                // divider after the BMP signed-height conversion at 100 MHz.
                INIT_WIDTH: if (init_x_remainder>=DEST_WIDTH) begin
                    init_x_remainder<=init_x_remainder-DEST_WIDTH;
                    x_step<=x_step+1'b1;
                end else begin
                    x_fraction<=init_x_remainder; state<=INIT_HEIGHT;
                end
                INIT_HEIGHT: if (init_y_remainder>=DEST_HEIGHT) begin
                    init_y_remainder<=init_y_remainder-DEST_HEIGHT;
                    y_step<=y_step+1'b1;
                end else begin
                    y_fraction<=init_y_remainder; state<=INIT_Y;
                end
                INIT_Y: begin
                    // Bottom-up samples ceil((d+1)*H/480)-1 in file order.
                    want_y<=source_bottom_up ? y_step-(y_fraction==0) : 0;
                    y_remainder<=source_bottom_up ?
                        (y_fraction==0 ? DEST_HEIGHT-1 : y_fraction-1'b1) : 0;
                    state<=RECEIVE;
                end
                RECEIVE: if (in_valid) begin
                    if (input_x==width-1) begin input_x<=0; input_y<=input_y+1'b1; end
                    else input_x<=input_x+1'b1;
                    if (!output_done && input_y==want_y && input_x==want_x && fill_x<DEST_WIDTH) begin
                        held_pixel<=in_rgb; held_x<=input_x;
                        held_last<=input_x==width-1;
                        selected_row_y<=input_y;
                        state<=FILL;
                    end else if (!output_done && input_y==want_y && input_x==width-1) begin
                        emit_x<=0; state<=READ_ROW;
                    end
                end
                FILL: begin
                    fill_x<=fill_x+1'b1;
                    want_x<=next_want_x;
                    x_remainder<=x_sum>=DEST_WIDTH ? x_sum-DEST_WIDTH : x_sum;
                    if (fill_x==DEST_WIDTH-1 || next_want_x!=held_x) begin
                        if (held_last) begin emit_x<=0; state<=READ_ROW; end
                        else state<=RECEIVE;
                    end
                end
                READ_ROW: state<=SEND;
                SEND: begin
                    out_rgb<=line_read; out_valid<=1;
                    gap_count<=OUTPUT_GAP-1;
                    if (emit_x==DEST_WIDTH-1) begin
                        emit_x<=0; emit_y<=emit_y+1'b1;
                        want_y<=next_want_y;
                        y_remainder<=y_sum>=DEST_HEIGHT ? y_sum-DEST_HEIGHT : y_sum;
                        if (emit_y==DEST_HEIGHT-1) begin
                            output_done<=1; state<=RECEIVE;
                        end else if (next_want_y==selected_row_y) state<=GAP;
                        else begin
                            fill_x<=0; want_x<=0; x_remainder<=0; state<=RECEIVE;
                        end
                    end else begin emit_x<=emit_x+1'b1; state<=GAP; end
                end
                GAP: if (gap_count==0) state<=READ_ROW;
                     else gap_count<=gap_count-1'b1;
                default: state<=RECEIVE;
            endcase
        end
    end
endmodule
