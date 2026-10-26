`timescale 1ns/1ps
// Request the NEXT display row, retain an ordered address/return tag stream,
// then display from a dual-clock ping-pong line RAM. No pixel-clock events
// are encoded as toggles: every mapped coordinate crosses in the command FIFO.
module media_frame_reader #(
    parameter integer ADDR_WIDTH=21, IMAGE_WORDS=307200,
    parameter integer DISPLAY_WIDTH=640, DISPLAY_HEIGHT=480,
    parameter integer FIFO_DEPTH=512, FIFO_MARGIN=8, BURST_SIZE=128,
    parameter integer BURST_GAP_CYCLES=12, MAX_INFLIGHT_BURSTS=2,
    parameter integer DIAG_RETURN_PATTERN=0, DIAG_SYNTH_STREAM=0
)(
    input mem_clk, mem_rst_n, controller_init_done, controller_busy,
    input refresh_active, write_request_busy,
    output read_request_busy, output app_rd_en,
    output [ADDR_WIDTH-1:0] app_rd_addr,
    input sdram_rd_valid, input [31:0] sdram_rd_data,
    input pix_clk, pix_rst_n, frame_start, input [2:0] active_index,
    input pixel_consume, input [11:0] pixel_x, pixel_y,
    output request_valid, output [11:0] request_x, request_y,
    input coordinate_valid, input [2:0] source_index,
    input [15:0] source_x, source_y, source_stride,
    input focus_border,
    output reg [23:0] pixel_rgb, output reg pixel_valid,
    output reg underflow,
    output reader_busy, output reg frame_read_done,
    output reg [2:0] reader_index, output reg [7:0] reader_error
);
    localparam CMD_DEPTH=1024;
    localparam META_DEPTH=512;
    localparam LINE_ADDR_WIDTH=$clog2(2*DISPLAY_WIDTH);
    wire reset = !mem_rst_n || !pix_rst_n;
    reg [2:0] frame_delay;
    reg [15:0] epoch;
    reg fetching;
    reg [9:0] fetch_x;
    reg [8:0] fetch_y;
    reg request_pending;
    reg [15:0] request_epoch;
    reg [9:0] request_x_q;
    reg [8:0] request_y_q;
    reg armed;
    reg map_valid;
    reg [15:0] map_epoch, map_source_x, map_source_y, map_source_stride;
    reg [9:0] map_x;
    reg [8:0] map_y;
    reg [2:0] map_source_index;
    reg map_coordinate_valid, map_border;
    wire line_ready;
    wire cmd_full, cmd_empty, cmd_raw_valid, cmd_raw_re;
    wire [63:0] cmd_raw, cmd;
    wire cmd_valid;
    wire [1:0] buffered_words;
    reg [1:0] word_beat;
    wire [9:0] cmd_used;
    reg command_valid;
    reg [63:0] command_q;
    // The six image banks and the normal 640-pixel stride are constants in
    // this project.  Avoid two live multipliers in the SDRAM address path;
    // the generic stride fallback remains available for non-standard media.
    function [ADDR_WIDTH-1:0] image_base;
        input [2:0] index;
        begin
            case (index)
                3'd0: image_base = {ADDR_WIDTH{1'b0}};
                3'd1: image_base = IMAGE_WORDS;
                3'd2: image_base = IMAGE_WORDS * 2;
                3'd3: image_base = IMAGE_WORDS * 3;
                3'd4: image_base = IMAGE_WORDS * 4;
                default: image_base = IMAGE_WORDS * 5;
            endcase
        end
    endfunction
    wire [31:0] row_offset_640 = ({16'd0, map_source_y} << 9) +
                                 ({16'd0, map_source_y} << 7);
    wire [31:0] row_offset = map_source_stride == 16'd640 ?
                             row_offset_640 :
                             map_source_y * map_source_stride;
    wire [31:0] offset = row_offset + map_source_x;
    wire address_valid = map_coordinate_valid && offset < IMAGE_WORDS && map_source_stride != 0;
    wire [ADDR_WIDTH-1:0] address = image_base(map_source_index) +
                                    offset[ADDR_WIDTH-1:0];
    wire [63:0] mapped_command = {6'd0,map_epoch,map_y,map_x,map_border,address_valid,
                                 {{(21-ADDR_WIDTH){1'b0}},
                                  (address_valid ? address : {ADDR_WIDTH{1'b0}})}};
    wire command_ready = !command_valid || !cmd_full;
    wire map_ready = !map_valid || command_ready;
    wire request_ready = !request_pending || map_ready;
    // Register the requested coordinate before the layout multipliers. This
    // removes the fetch-counter -> scaler setup path and keeps the coordinate
    // stable for a full pixel clock while its mapped response is generated.
    assign request_valid = request_pending;
    assign request_x = {2'd0,request_x_q};
    assign request_y = {3'd0,request_y_q};

    // The controller commits focus at frame_start. Wait three clocks before
    // issuing row zero so the frame's geometry/mode snapshot is stable.
    always @(posedge pix_clk or posedge reset) begin
        if (reset) begin
            frame_delay<=0; epoch<=0; fetching<=0; fetch_x<=0;
            fetch_y<=0; request_pending<=0; request_epoch<=0;
            request_x_q<=0; request_y_q<=0;
            armed<=0; underflow<=0; map_valid<=0;
            map_epoch<=0; map_x<=0; map_y<=0; map_source_index<=0;
            map_source_x<=0; map_source_y<=0; map_source_stride<=0;
            map_coordinate_valid<=0; map_border<=0;
            command_valid<=0; command_q<=0;
        end else begin
            frame_delay <= {frame_delay[1:0],frame_start};
            // The second elastic register isolates the mapped address from
            // the asynchronous FIFO RAM input. Data and valid only advance
            // together when the downstream stage has room.
            if (command_ready) begin
                command_valid <= map_valid;
                if (map_valid) command_q <= mapped_command;
            end
            if (frame_delay[2]) begin
                epoch<=epoch+1'b1; fetching<=1; fetch_x<=0; fetch_y<=0;
                request_pending<=0; armed<=1; map_valid<=0; command_valid<=0;
            end else if (armed && pixel_consume && pixel_x==0 && pixel_y<DISPLAY_HEIGHT-1) begin
                if (fetching || request_pending || map_valid || command_valid)
                    underflow<=1;
                fetching<=1; fetch_x<=0; fetch_y<=pixel_y+1'b1;
                request_pending<=0; map_valid<=0;
            end else begin
                if (map_ready) begin
                    map_valid<=request_pending;
                    if (request_pending) begin
                        map_epoch<=request_epoch; map_x<=request_x_q; map_y<=request_y_q;
                        map_source_index<=source_index;
                        map_source_x<=source_x; map_source_y<=source_y;
                        map_source_stride<=source_stride;
                        map_coordinate_valid<=coordinate_valid; map_border<=focus_border;
                    end
                end
                if (request_ready) begin
                    request_pending<=fetching;
                    if (fetching) begin
                        request_epoch<=epoch; request_x_q<=fetch_x; request_y_q<=fetch_y;
                        if (fetch_x==DISPLAY_WIDTH-1) fetching<=0;
                        else fetch_x<=fetch_x+1'b1;
                    end
                end
                if (!request_ready && fetching) underflow<=1;
            end
            if (armed && pixel_consume && !line_ready) underflow<=1;
        end
    end
    rfifo_32_32_512 #(.DATA_WIDTH_W(64),.DATA_WIDTH_R(64),
        .ADDR_WIDTH_W(10),.ADDR_WIDTH_R(10),.AL_FULL_NUM(1016),.AL_EMPTY_NUM(2)) u_commands (
        .rst(reset),.clkw(pix_clk),.clkr(mem_clk),
        .we(command_valid && !cmd_full),.di(command_q),.re(cmd_raw_re),
        .dout(cmd_raw),.valid(cmd_raw_valid),.full_flag(cmd_full),
        .empty_flag(cmd_empty),.afull(),.aempty(),.wrusedw(),.rdusedw(cmd_used));
    fifo_prefetch_2 #(.DATA_WIDTH(64)) u_command_prefetch (
        .clk(mem_clk),.rst(reset),.raw_empty(cmd_empty),.raw_valid(cmd_raw_valid),
        .raw_data(cmd_raw),.raw_read_en(cmd_raw_re),.consume(app_rd_en && word_beat==3),
        .out_valid(cmd_valid),.out_empty(),.out_data(cmd),.buffered_words(buffered_words));

    // The vendor controller samples one aligned address per four App cycles.
    // Fetch all four native words and retain only the requested pixel.
    reg [37:0] metadata[0:META_DEPTH-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [8:0] meta_wr, meta_rd;
    reg [37:0] return_tag;
    reg [9:0] inflight;
    reg burst_active;
    reg [15:0] burst_left;
    reg [15:0] prepared_burst;
    reg prepared_valid;
    reg [11:0] available_q;
    reg [7:0] gap;
    wire [11:0] available = {2'd0,cmd_used} + buffered_words;
    // A full burst is resident before the controller gets ownership. The
    // final partial burst is allowed only when it reaches the end of a row.
    wire [15:0] row_remaining = (DISPLAY_WIDTH - cmd[32:23])*4;
    wire [15:0] next_burst = row_remaining < BURST_SIZE ? row_remaining : BURST_SIZE;
    wire start_burst = !burst_active && gap==0 && cmd_valid && prepared_valid &&
        available_q*4 >= prepared_burst && inflight+prepared_burst < META_DEPTH-4 &&
        controller_init_done && !controller_busy && !refresh_active && !write_request_busy;
    assign app_rd_en = burst_active && cmd_valid;
    assign app_rd_addr = {cmd[ADDR_WIDTH-1:2],word_beat};
    // Do not hold ownership while merely waiting for a command; writes can
    // run in that time. Returns must drain before ownership passes to writes.
    assign read_request_busy = burst_active || gap!=0 || inflight!=0;
    assign reader_busy = read_request_busy || cmd_valid || !cmd_empty;
    wire returning = sdram_rd_valid && inflight!=0;
    wire [37:0] tag = return_tag;
    wire [9:0] return_x = tag[11:2];
    wire [8:0] return_y = tag[20:12];
    wire [15:0] return_epoch = tag[36:21];
    reg [23:0] line_ram[0:(1<<LINE_ADDR_WIDTH)-1] /* fehdl force_ram=1, ram_style="bram" */;
    wire [LINE_ADDR_WIDTH-1:0] line_write_addr=(return_y[0] ? DISPLAY_WIDTH : 0)+return_x;
    wire [LINE_ADDR_WIDTH-1:0] line_read_addr=(pixel_y[0] ? DISPLAY_WIDTH : 0)+pixel_x;
    reg [24:0] ready0_mem, ready1_mem;
    reg ready0_valid_mem, ready1_valid_mem;
    always @(posedge mem_clk) begin
        if (app_rd_en) metadata[meta_wr]<={word_beat==cmd[1:0],cmd[57:21]};
        return_tag<=metadata[returning ? meta_rd+9'd1 : meta_rd];
        if (returning && tag[37])
            line_ram[line_write_addr] <=
                tag[1] ? 24'hffff00 : tag[0] ? sdram_rd_data[23:0] : 24'd0;
    end
    always @(posedge mem_clk or posedge reset) begin
        if (reset) begin
            meta_wr<=0; meta_rd<=0; inflight<=0; burst_active<=0; word_beat<=0;
            burst_left<=0; prepared_burst<=0; prepared_valid<=0; available_q<=0;
            gap<=0; frame_read_done<=0; reader_index<=0;
            reader_error<=0; ready0_mem<=0; ready1_mem<=0;
            ready0_valid_mem<=0; ready1_valid_mem<=0;
        end else begin
            frame_read_done<=0;
            prepared_burst<=next_burst;
            prepared_valid<=cmd_valid;
            available_q<=available;
            if (gap!=0) gap<=gap-1'b1;
            if (start_burst) begin burst_active<=1; burst_left<=prepared_burst; end
            if (app_rd_en) begin
                word_beat<=word_beat+1'b1;
                meta_wr<=meta_wr+1'b1;
                reader_index<=active_index;
                if (burst_left==1) begin burst_active<=0; gap<=BURST_GAP_CYCLES; end
                else burst_left<=burst_left-1'b1;
            end
            case ({app_rd_en,returning})
                2'b10: inflight<=inflight+1'b1;
                2'b01: inflight<=inflight-1'b1;
                default: ;
            endcase
            if (returning) begin
                meta_rd<=meta_rd+1'b1;
                if (tag[37] && return_x==DISPLAY_WIDTH-1) begin
                    if (return_y[0]) begin ready1_mem<={return_epoch,return_y}; ready1_valid_mem<=1; end
                    else begin ready0_mem<={return_epoch,return_y}; ready0_valid_mem<=1; end
                    if (return_y==DISPLAY_HEIGHT-1) frame_read_done<=1;
                end
            end
            if (burst_active && !cmd_valid) reader_error<=8'h62;
        end
    end
    // Completed-line tags stay stable for two line periods. Data has already
    // been written when the tags enter this two-stage synchronizer.
    reg [24:0] ready0_s1,ready0_s2,ready1_s1,ready1_s2;
    reg [1:0] valid_s1,valid_s2;
    reg row_ready;
    wire tag_match = pixel_y[0] ?
        valid_s2[1] && ready1_s2=={epoch,pixel_y[8:0]} :
        valid_s2[0] && ready0_s2=={epoch,pixel_y[8:0]};
    assign line_ready = pixel_x==0 ? tag_match : row_ready;
    reg [23:0] ram_rgb;
    always @(posedge pix_clk) begin
        if (pixel_consume && pixel_x<DISPLAY_WIDTH)
            ram_rgb <= line_ram[line_read_addr];
    end
    // RAM read and valid have one pixel clock latency; pixel_rgb is the RAM
    // register directly. The top delays sync/DE by that same clock.
    always @* pixel_rgb = pixel_valid ? ram_rgb : 24'd0;
    always @(posedge pix_clk or posedge reset) begin
        if (reset) begin
            ready0_s1<=0; ready0_s2<=0; ready1_s1<=0; ready1_s2<=0;
            valid_s1<=0; valid_s2<=0; pixel_valid<=0; row_ready<=0;
        end else begin
            ready0_s1<=ready0_mem; ready0_s2<=ready0_s1;
            ready1_s1<=ready1_mem; ready1_s2<=ready1_s1;
            valid_s1<={ready1_valid_mem,ready0_valid_mem}; valid_s2<=valid_s1;
            if (pixel_consume && pixel_x==0) row_ready<=tag_match;
            pixel_valid<=pixel_consume && line_ready;
        end
    end
endmodule
