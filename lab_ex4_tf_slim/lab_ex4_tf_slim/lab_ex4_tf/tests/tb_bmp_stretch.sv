`timescale 1ns/1ps
// Real FAT byte stream -> BMP decode/stretch -> clock crossing -> frame bank.
module tb_bmp_stretch;
    parameter integer CASE_GROUP=-1;
    reg sd_clk=0, mem_clk=0, rst=1, start=0, abort_load=0;
    always #5 sd_clk=~sd_clk;
    always #4 mem_clk=~mem_clk;
    integer w=1,h=1,top_down=0,stride=4,file_length=58;
    reg [31:0] header_width=1,header_height=1;
    wire req,ready,write_req,valid,commit,load_error;
    wire [31:0] lba;
    wire [2:0] bmp_error;
    wire [15:0] width,height;
    wire bottom_up;
    wire [23:0] rgb;
    reg ack=0;
    always @(posedge sd_clk) if(rst) ack<=0; else ack<=write_req;
    reg busy=0,sector_valid=0,sector_done=0;
    reg [7:0] sector_byte=0;
    reg [8:0] sector_index=0;
    reg [31:0] sector_lba;
    integer byte_pos,offset,cluster,entry;
    reg [31:0] next_cluster;
    reg [7:0] injected_error=0;
    reg [7:0] delivered_error=0;
    function [23:0] color(input integer x,input integer y);
        color={8'(y),8'(x),8'(x+3*y)};
    endfunction
    function [7:0] image_byte(input integer at);
        integer row,col,logical_y;
        reg [23:0] pixel;
        begin
            case(at)
                0: image_byte="B";
                1: image_byte="M";
                2,3,4,5: image_byte=file_length>>((at-2)*8);
                10: image_byte=54;
                14: image_byte=40;
                18,19,20,21: image_byte=header_width>>((at-18)*8);
                22,23,24,25: image_byte=header_height>>((at-22)*8);
                26: image_byte=1;
                28: image_byte=24;
                default: begin
                    image_byte=0;
                    if(at>=54 && at<file_length) begin
                        row=(at-54)/stride; col=(at-54)%stride;
                        logical_y=top_down ? row : h-1-row;
                        if(col<w*3) begin
                            pixel=color(col/3,logical_y);
                            image_byte=pixel>>((col%3)*8);
                        end else image_byte=8'ha5;
                    end
                end
            endcase
        end
    endfunction
    // FAT contains sequential clusters; final partial sectors are padded.
    // Back-to-back sector bytes stress buffering when the scaler stops input.
    always @(negedge sd_clk) begin
        sector_valid=0; sector_done=0;
        if(rst) begin busy=0; byte_pos=0; delivered_error=0; end
        else if(busy) begin
            if(byte_pos<512) begin
                sector_valid=1; sector_index=byte_pos;
                if(sector_lba<100) begin
                    cluster=(sector_lba-1)*128+byte_pos/4;
                    next_cluster=(cluster-1)*65536>=file_length ? 32'h0fffffff : cluster+1;
                    sector_byte=next_cluster>>((byte_pos%4)*8);
                end else sector_byte=image_byte((sector_lba-100)*512+byte_pos);
                byte_pos=byte_pos+1;
            end else begin sector_done=1; busy=0; delivered_error=injected_error; end
        end else if(req) begin busy=1; sector_lba=lba; byte_pos=0; delivered_error=0; end
    end
    bmp_fat_reader #(.STRETCH_TO_DISPLAY(1)) decoder (
        .clk(sd_clk),.rst(rst),.load_start(start),.load_abort(abort_load),
        .load_cluster(32'd2),.load_file_size(file_length),.sectors_per_cluster(8'd128),
        .fat_start_lba(32'd1),.data_start_lba(32'd100),.max_cluster(32'd100000),
        // Fixed display dimensions must not filter the input header size.
        .bmp_width(16'd640),.bmp_height(16'd480),.decoded_width(width),.decoded_height(height),
        .decoded_bottom_up(bottom_up),.ready(ready),.bmp_error(bmp_error),.load_error(load_error),
        .write_req(write_req),.write_req_ack(ack),.bmp_data_wr_en(valid),.bmp_data(rgb),
        .frame_commit(commit),.sector_req(req),.sector_lba(lba),.sector_busy(busy),
        .sector_valid(sector_valid),.sector_done(sector_done),.sector_byte(sector_byte),
        .sector_error(delivered_error),.sector_byte_index(sector_index));
    wire ls,pv,fc,flip;
    wire [1:0] index;
    wire [15:0] iw,ih;
    wire [23:0] prgb;
    wire [7:0] derr;
    media_pixel_cdc cdc (
        .sd_clk(sd_clk),.sd_rst_n(!rst),.mem_clk(mem_clk),.mem_rst_n(!rst),
        .source_start(write_req && !ack),.source_index(2'd2),
        .source_width(width),.source_height(height),.source_bottom_up(bottom_up),
        .source_pixel_valid(valid),.source_pixel_rgb(rgb),.source_commit(commit),
        .source_error(load_error ? 8'h01 : 8'd0),
        .load_start(ls),.image_index(index),.image_width(iw),.image_height(ih),.image_bottom_up(flip),
        .pixel_valid(pv),.pixel_rgb(prgb),.frame_commit(fc),.decode_error(derr));
    wire wr,load_done;
    wire [20:0] wa;
    wire [31:0] wd;
    wire [3:0] complete,mask;
    wire [63:0] bank_widths,bank_heights;
    wire [3:0] bank_flips;
    wire [7:0] memory_error;
    media_frame_loader #(.DYNAMIC_GEOMETRY(1)) loader (
        .clk(mem_clk),.rst_n(!rst),.load_start(ls),.image_index(index),
        .image_width(iw),.image_height(ih),.image_bottom_up(flip),
        .bank_widths(bank_widths),.bank_heights(bank_heights),.bank_bottom_up(bank_flips),
        .pixel_valid(pv),.pixel_rgb(prgb),.frame_commit(fc),.decode_error(derr),
        .load_busy(),.load_done(load_done),.image_complete(complete),.memory_error(memory_error),
        .controller_init_done(1'b1),.controller_busy(1'b0),.refresh_active(1'b0),
        .read_request_busy(1'b0),.write_request_busy(),
        .app_wr_en(wr),.app_wr_addr(wa),.app_wr_mask(mask),.app_wr_data(wd));
    integer writes=0,frame_writes=0,commits=0,frames=0,dx,dy,sx,sy;
    always @(posedge mem_clk) begin
        if(wr) begin
            if(mask!=0 || wa!=2*307200+frame_writes) $fatal(1,"Bank overflow/order: %d",wa);
            dx=frame_writes%640; dy=frame_writes/640;
            sx=dx*w/640; sy=(top_down ? dy : 479-dy)*h/480;
            if(wd[23:0]!==color(sx,sy))
                $fatal(1,"Stretch %dx%d top=%d dest(%d,%d): got %h expected %h src(%d,%d)",
                       w,h,top_down,dx,dy,wd[23:0],color(sx,sy),sx,sy);
            frame_writes=frame_writes+1; writes=writes+1;
        end
        if(fc) commits=commits+1;
    end
    task kick;
        begin @(negedge sd_clk); start=1; @(negedge sd_clk); start=0; end
    endtask
    task good_image(input integer ww,hh,orientation);
        begin
            w=ww; h=hh; top_down=orientation; stride=((w*3+3)/4)*4;
            file_length=54+stride*h; header_width=w; header_height=top_down ? -h : h;
            frame_writes=0; kick(); @(posedge load_done); #1;
            if(memory_error || !complete[2] || frame_writes!=307200 ||
               bank_widths[47:32]!=640 || bank_heights[47:32]!=480 ||
               bank_flips[2]!==!top_down || commits!=frames+1)
                $fatal(1,"Frame completion failed %dx%d: error %h, writes %d",w,h,memory_error,frame_writes);
            frames=frames+1;
            $display("PASS: %dx%d top_down=%0d -> 640x480, all 307200 pixels",w,h,top_down);
            repeat(30) @(negedge sd_clk);
        end
    endtask
    reg test_pass=0;
    initial begin
        repeat(10) @(negedge sd_clk); rst=0;
        if(CASE_GROUP<0 || CASE_GROUP==0) begin
            good_image(1,1,0); good_image(3,2,1); good_image(257,193,0);
        end
        if(CASE_GROUP<0 || CASE_GROUP==1) begin
            good_image(320,240,1); good_image(640,480,0);
        end
        if(CASE_GROUP<0 || CASE_GROUP==2) begin
            good_image(800,600,0); good_image(1024,768,1); good_image(480,640,0);
        end
        if(CASE_GROUP<0 || CASE_GROUP==3) good_image(1920,1080,0);
        // Invalid dimensions still fail before opening the SDRAM bank.
        header_width=0; kick(); @(posedge load_error); #1;
        if(bmp_error==0 || write_req || commits!=frames) $fatal(1,"Invalid header accepted");
        repeat(30) @(negedge sd_clk);
        header_width=w; injected_error=8'h10; kick(); @(posedge load_error); #1;
        if(bmp_error!=2 || commits!=frames) $fatal(1,"SD error committed frame");
        test_pass=1;
        $display("PASS: stretch/FAT/CDC/SDRAM %0d frames, %0d pixels, invalid header and SD error",frames,writes);
        $finish;
    end
    initial begin #1000000000; $fatal(1,"Stretch timeout"); end
endmodule
