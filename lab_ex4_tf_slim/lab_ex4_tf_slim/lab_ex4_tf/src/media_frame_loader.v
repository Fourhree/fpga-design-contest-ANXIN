`timescale 1ns/1ps

module media_frame_loader #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer IMAGE_WORDS = 307200,
    parameter integer FIFO_DEPTH = 512,
    parameter integer BURST_SIZE = 128,
    parameter integer STALL_TIMEOUT = 65535,
    parameter integer WRITE_V_FLIP = 0,
    parameter integer DYNAMIC_GEOMETRY = 0,
    parameter integer FRAME_WIDTH = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer BURST_GAP_CYCLES = 12
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  load_start,
    input  wire [2:0]            image_index,
    input  wire [15:0]           image_width, image_height,
    input  wire                  image_bottom_up,
    output reg [95:0]            bank_widths, bank_heights,
    output reg [5:0]             bank_bottom_up,
    input  wire                  pixel_valid,
    input  wire [23:0]           pixel_rgb,
    input  wire                  frame_commit,
    input  wire [7:0]            decode_error,
    output wire                  load_busy,
    output reg                   load_done,
    output reg  [5:0]            image_complete,
    output reg  [7:0]            memory_error,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    input  wire                  read_request_busy,
    output wire                  write_request_busy,
    output reg                   app_wr_en,
    output reg  [ADDR_WIDTH-1:0] app_wr_addr,
    output reg  [3:0]            app_wr_mask,
    output reg  [31:0]           app_wr_data
);
    localparam ERR_NONE          = 8'h00;
    localparam ERR_NOT_ACTIVE    = 8'h41;
    localparam ERR_FIFO_OVERFLOW = 8'h42;
    localparam ERR_PIXEL_COUNT   = 8'h43;
    localparam ERR_DECODE        = 8'h44;
    localparam ERR_SHORT_FRAME   = 8'h45;
    localparam ERR_WRITE_STALL   = 8'h46;

    localparam integer PTR_WIDTH = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam [PTR_WIDTH:0] EFFECTIVE_BURST =
        (BURST_SIZE < FIFO_DEPTH) ? BURST_SIZE : FIFO_DEPTH;
    localparam [ADDR_WIDTH-1:0] BANK0_BASE = 0;
    localparam [ADDR_WIDTH-1:0] BANK1_BASE = IMAGE_WORDS;
    localparam [ADDR_WIDTH-1:0] BANK2_BASE = IMAGE_WORDS * 2;
    localparam [ADDR_WIDTH-1:0] BANK3_BASE = IMAGE_WORDS * 3;
    localparam [ADDR_WIDTH-1:0] BANK4_BASE = IMAGE_WORDS * 4;
    localparam [ADDR_WIDTH-1:0] BANK5_BASE = IMAGE_WORDS * 5;

    reg active;
    reg geometry_pending;
    reg receive_closed;
    reg [2:0] active_image;
    reg commit_seen;
    reg [31:0] pixels_received;
    reg [31:0] pixels_written;
    reg [31:0] stall_count;
    reg [ADDR_WIDTH-1:0] write_offset;
    reg [15:0] write_x;
    reg [15:0] active_width, active_height;
    reg active_flip;
    reg [31:0] expected_pixels;
    reg [31:0] last_pixel_index;
    reg counts_match;
    wire [15:0] start_width = DYNAMIC_GEOMETRY ? image_width : FRAME_WIDTH;
    wire [15:0] start_height = DYNAMIC_GEOMETRY ? image_height : FRAME_HEIGHT;
    wire [31:0] start_pixels = start_width * start_height;
    wire start_flip = DYNAMIC_GEOMETRY ? image_bottom_up : WRITE_V_FLIP;
    reg [7:0] burst_gap;
    reg [31:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;
    reg [PTR_WIDTH:0] fifo_count;
    reg burst_active;
    reg [PTR_WIDTH:0] burst_remaining;
    wire pop_allowed;
    wire push_allowed;
    wire start_burst;
    wire [PTR_WIDTH:0] next_burst_words;

    assign load_busy = active;
    // The inherited controller consumes a continuous App_wr_en burst and
    // handles busy/refresh internally. Those status outputs are not per-word
    // ready signals and must not split an active write burst.
    assign start_burst = active && controller_init_done && !burst_active &&
                         !read_request_busy && !controller_busy && !refresh_active && burst_gap == 0 &&
                         fifo_count != 0 &&
                         (fifo_count >= EFFECTIVE_BURST || commit_seen);
    // Pad the last physical burst to four words, with every byte masked.
    assign next_burst_words = (fifo_count >= EFFECTIVE_BURST) ?
                              EFFECTIVE_BURST : ((fifo_count+3) & ~3);
    assign pop_allowed = active && controller_init_done && burst_active;
    assign push_allowed = active && pixel_valid &&
                          (fifo_count < FIFO_DEPTH || pop_allowed);
    assign write_request_busy = burst_active || start_burst || app_wr_en || burst_gap != 0;

    function [ADDR_WIDTH-1:0] bank_base;
        input [2:0] index;
        begin
            case (index)
                3'd0: bank_base = BANK0_BASE;
                3'd1: bank_base = BANK1_BASE;
                3'd2: bank_base = BANK2_BASE;
                3'd3: bank_base = BANK3_BASE;
                3'd4: bank_base = BANK4_BASE;
                default: bank_base = BANK5_BASE;
            endcase
        end
    endfunction

    task fail_load;
        input [7:0] code;
        begin
            memory_error <= code;
            active <= 1'b0; geometry_pending<=1'b0; receive_closed<=1'b0;
            burst_active <= 1'b0;
            burst_remaining <= 0;
            load_done <= 1'b1;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            geometry_pending <= 1'b0;
            receive_closed <= 1'b0;
            active_image <= 3'd0;
            commit_seen <= 1'b0;
            pixels_received <= 32'd0;
            pixels_written <= 32'd0;
            stall_count <= 32'd0;
            write_offset <= 0; write_x <= 0; burst_gap <= 0;
            active_width<=0; active_height<=0; active_flip<=0;
            expected_pixels<=IMAGE_WORDS; last_pixel_index<=IMAGE_WORDS-1;
            bank_widths<=0; bank_heights<=0; bank_bottom_up<=0;
            counts_match <= 1'b0;
            wr_ptr <= {PTR_WIDTH{1'b0}};
            rd_ptr <= {PTR_WIDTH{1'b0}};
            fifo_count <= {(PTR_WIDTH+1){1'b0}};
            burst_active <= 1'b0;
            burst_remaining <= 0;
            load_done <= 1'b0;
            image_complete <= 6'd0;
            memory_error <= ERR_NONE;
            app_wr_en <= 1'b0;
            app_wr_addr <= {ADDR_WIDTH{1'b0}};
            app_wr_mask <= 4'b0000;
            app_wr_data <= 32'd0;
        end else begin
            load_done <= 1'b0;
            app_wr_en <= 1'b0;
            // Completion is evaluated only after the FIFO and final physical
            // burst have drained. Register the wide count comparisons first
            // so they do not also drive all four banks' metadata enables.
            counts_match <= pixels_received == expected_pixels &&
                            pixels_written == expected_pixels;
            if (burst_gap != 0) burst_gap <= burst_gap - 1'b1;

            if (load_start && !active) begin
                active <= 1'b1;
                geometry_pending<=1'b1;
                receive_closed<=1'b0;
                active_image <= image_index;
                commit_seen <= 1'b0;
                pixels_received <= 32'd0;
                pixels_written <= 32'd0;
                stall_count <= 32'd0;
                active_width<=start_width; active_height<=start_height; active_flip<=start_flip;
                expected_pixels<=start_pixels;
                last_pixel_index<=start_pixels-1'b1;
                counts_match <= 1'b0;
                write_offset <= 0;
                write_x <= 0; burst_gap <= 0;
                wr_ptr <= {PTR_WIDTH{1'b0}};
                rd_ptr <= {PTR_WIDTH{1'b0}};
                fifo_count <= {(PTR_WIDTH+1){1'b0}};
                burst_active <= 1'b0;
                burst_remaining <= 0;
                memory_error <= ERR_NONE;
                case (image_index)
                    3'd0: image_complete[0] <= 1'b0;
                    3'd1: image_complete[1] <= 1'b0;
                    3'd2: image_complete[2] <= 1'b0;
                    3'd3: image_complete[3] <= 1'b0;
                    3'd4: image_complete[4] <= 1'b0;
                    default: image_complete[5] <= 1'b0;
                endcase
            end

            if (active) begin
                if (geometry_pending) geometry_pending<=1'b0;
                if (decode_error != 0) begin
                    geometry_pending<=1'b0;
                    fail_load(ERR_DECODE);
                end else if (pixel_valid && receive_closed) begin
                    fail_load(ERR_PIXEL_COUNT);
                end else if (pixel_valid && !push_allowed) begin
                    fail_load(ERR_FIFO_OVERFLOW);
                end else begin
                    if (start_burst) begin
                        burst_active <= 1'b1;
                        burst_remaining <= next_burst_words;
                    end

                    if (push_allowed) begin
                        fifo_mem[wr_ptr] <= {8'h00, pixel_rgb};
                        wr_ptr <= wr_ptr + 1'b1;
                        pixels_received <= pixels_received + 1'b1;
                        // The frame size is stable for the whole transfer.
                        // Comparing against its precomputed final index keeps
                        // a 32-bit incrementer out of the FIFO write path.
                        if (pixels_received == last_pixel_index)
                            receive_closed<=1'b1;
                    end

                    if (pop_allowed) begin
                        app_wr_en <= 1'b1;
                        app_wr_addr <= bank_base(active_image) + write_offset;
                        // Keep storage contiguous even for odd row widths.
                        // Bottom-up orientation is applied by the display mapper.
                        write_offset <= write_offset + 1'b1;
                        app_wr_data <= fifo_mem[rd_ptr];
                        app_wr_mask <= fifo_count!=0 ? 4'b0000 : 4'b1111;
                        if (fifo_count!=0) begin
                            rd_ptr <= rd_ptr + 1'b1;
                            pixels_written <= pixels_written + 1'b1;
                        end
                        stall_count <= 32'd0;
                        if (burst_remaining == 1) begin
                            burst_active <= 1'b0;
                            burst_remaining <= 0;
                            burst_gap <= BURST_GAP_CYCLES;
                        end else begin
                            burst_remaining <= burst_remaining - 1'b1;
                        end
                    end else if (fifo_count != 0 &&
                                 (commit_seen || fifo_count >= EFFECTIVE_BURST)) begin
                        if (stall_count == STALL_TIMEOUT)
                            fail_load(ERR_WRITE_STALL);
                        else
                            stall_count <= stall_count + 1'b1;
                    end else begin
                        stall_count <= 32'd0;
                    end

                    case ({push_allowed, (pop_allowed && fifo_count!=0)})
                        2'b10: fifo_count <= fifo_count + 1'b1;
                        2'b01: fifo_count <= fifo_count - 1'b1;
                        default: fifo_count <= fifo_count;
                    endcase

                    if (frame_commit)
                        commit_seen <= 1'b1;

                    if (commit_seen && fifo_count == 0 && !pop_allowed &&
                        !burst_active && !app_wr_en && burst_gap == 0 && !controller_busy) begin
                        if (!counts_match) begin
                            fail_load(ERR_SHORT_FRAME);
                        end else begin
                            bank_widths[active_image*16 +: 16] <= active_width;
                            bank_heights[active_image*16 +: 16] <= active_height;
                            bank_bottom_up[active_image] <= active_flip;
                            case (active_image)
                                3'd0: image_complete[0] <= 1'b1;
                                3'd1: image_complete[1] <= 1'b1;
                                3'd2: image_complete[2] <= 1'b1;
                                3'd3: image_complete[3] <= 1'b1;
                                3'd4: image_complete[4] <= 1'b1;
                                default: image_complete[5] <= 1'b1;
                            endcase
                            active <= 1'b0;
                            geometry_pending<=1'b0;
                            receive_closed<=1'b0;
                            load_done <= 1'b1;
                        end
                    end
                end
                // START clears the FIFO and burst state. Geometry is checked
                // on the following cycle, before a burst can be issued. Keep
                // this wide comparison out of the per-pixel FIFO/count enable
                // path; a failure overrides the normal state updates below.
                if (geometry_pending && (expected_pixels==0 || expected_pixels>IMAGE_WORDS))
                    fail_load(ERR_PIXEL_COUNT);
            end else if (pixel_valid) begin
                memory_error <= ERR_NOT_ACTIVE;
            end
        end
    end
endmodule
