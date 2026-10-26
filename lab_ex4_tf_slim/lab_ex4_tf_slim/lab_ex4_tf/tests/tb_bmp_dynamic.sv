`timescale 1ns/1ps
module tb_bmp_dynamic;
    reg sd_clk=0,mem_clk=0,rst=1,start=0;
    always #10 sd_clk=~sd_clk;
    always #5 mem_clk=~mem_clk;
    reg [7:0] bytes[0:4095];
    reg [31:0] length=0;
    wire req,done,ready,write_req,valid,commit,load_error;
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
    integer byte_pos;
    // Actual FAT file streamer, with a sector responder and a one-cluster EOC.
    always @(negedge sd_clk) begin
        sector_valid=0; sector_done=0;
        if(rst) begin busy=0; byte_pos=0; end
        else if(busy) begin
            if(byte_pos<512) begin
                sector_valid=1; sector_index=byte_pos;
                if(sector_lba==1)
                    sector_byte=(byte_pos>=8 && byte_pos<12) ? 8'hff : 0;
                else if((sector_lba-100)*512+byte_pos<4096)
                    sector_byte=bytes[(sector_lba-100)*512+byte_pos];
                else sector_byte=0;
                byte_pos=byte_pos+1;
            end else begin sector_done=1; busy=0; end
        end else if(req) begin busy=1; sector_lba=lba; byte_pos=0; end
    end
    bmp_fat_reader decoder (
        .clk(sd_clk),.rst(rst),.load_start(start),.load_abort(1'b0),
        .load_cluster(32'd2),.load_file_size(length),.sectors_per_cluster(8'd128),
        .fat_start_lba(32'd1),.data_start_lba(32'd100),.max_cluster(32'd1000),
        .bmp_width(16'd0),.bmp_height(16'd0),.decoded_width(width),.decoded_height(height),
        .decoded_bottom_up(bottom_up),.ready(ready),.bmp_error(bmp_error),.load_error(load_error),
        .write_req(write_req),.write_req_ack(ack),.bmp_data_wr_en(valid),.bmp_data(rgb),
        .frame_commit(commit),.sector_req(req),.sector_lba(lba),.sector_busy(busy),
        .sector_valid(sector_valid),.sector_done(sector_done),.sector_byte(sector_byte),
        .sector_error(8'd0),.sector_byte_index(sector_index));
    wire ls,pv,fc,flip;
    wire [2:0] index;
    wire [15:0] iw,ih;
    wire [23:0] prgb;
    wire [7:0] derr;
    media_pixel_cdc cdc (
        .sd_clk(sd_clk),.sd_rst_n(!rst),.mem_clk(mem_clk),.mem_rst_n(!rst),
        .source_start(write_req && !ack),.source_index(3'd2),
        .source_width(width),.source_height(height),.source_bottom_up(bottom_up),
        .source_pixel_valid(valid),.source_pixel_rgb(rgb),.source_commit(commit),.source_error(8'd0),
        .load_start(ls),.image_index(index),.image_width(iw),.image_height(ih),.image_bottom_up(flip),
        .pixel_valid(pv),.pixel_rgb(prgb),.frame_commit(fc),.decode_error(derr));
    wire wr,load_done,load_busy;
    wire [20:0] wa;
    wire [31:0] wd;
    wire [5:0] complete;
    wire [95:0] bank_widths,bank_heights;
    wire [5:0] bank_flips;
    wire [3:0] mask;
    wire [7:0] memory_error;
    media_frame_loader #(.DYNAMIC_GEOMETRY(1)) loader (
        .clk(mem_clk),.rst_n(!rst),.load_start(ls),.image_index(index),
        .image_width(iw),.image_height(ih),.image_bottom_up(flip),
        .bank_widths(bank_widths),.bank_heights(bank_heights),.bank_bottom_up(bank_flips),.pixel_valid(pv),.pixel_rgb(prgb),
        .frame_commit(fc),.decode_error(derr),.load_busy(load_busy),.load_done(load_done),
        .image_complete(complete),.memory_error(memory_error),.controller_init_done(1'b1),
        .controller_busy(1'b0),.refresh_active(1'b0),.read_request_busy(1'b0),.write_request_busy(),
        .app_wr_en(wr),.app_wr_addr(wa),.app_wr_mask(mask),.app_wr_data(wd));
    reg [23:0] memory[0:4095];
    integer writes=0,physical_writes=0,masked_writes=0,starts=0;
    always @(posedge mem_clk) begin
        if(ls) starts=starts+1;
        if(wr) begin
            physical_writes=physical_writes+1;
            if(mask==0) begin
                if(wa<2*307200 || wa>=2*307200+4096) $fatal(1,"Write escaped image bank: %d",wa);
                memory[wa-2*307200]=wd[23:0]; writes=writes+1;
            end else if(mask==4'hf) masked_writes=masked_writes+1;
            else $fatal(1,"Partial byte mask is not a whole padding word: %h",mask);
        end
    end
    task le32;
        input integer at; input [31:0] value;
        begin bytes[at]=value[7:0]; bytes[at+1]=value[15:8];
            bytes[at+2]=value[23:16]; bytes[at+3]=value[31:24]; end
    endtask
    integer a,b,c,logical_y,stride,off;
    reg [23:0] color;
    task make_bmp;
        input integer w,h,top_down;
        begin
            for(a=0;a<4096;a=a+1) bytes[a]=0;
            stride=((w*3+3)/4)*4; length=54+stride*h;
            bytes[0]="B"; bytes[1]="M"; le32(2,length); le32(10,54); le32(14,40);
            le32(18,w); le32(22,top_down ? -h : h); bytes[26]=1; bytes[28]=24;
            for(b=0;b<h;b=b+1) begin
                logical_y=top_down ? b : h-1-b;
                for(c=0;c<w;c=c+1) begin
                    color=24'h102000+logical_y*w+c; off=54+b*stride+c*3;
                    bytes[off]=color[7:0]; bytes[off+1]=color[15:8]; bytes[off+2]=color[23:16];
                end
                for(c=w*3;c<stride;c=c+1) bytes[54+b*stride+c]=8'ha5;
            end
        end
    endtask
    task kick;
        begin
            @(negedge sd_clk); start=1;
            @(negedge sd_clk); start=0;
        end
    endtask
    integer base_writes,base_physical,base_masked,base_starts,i,checks=0;
    task good_image;
        input integer w,h,top_down;
        begin
            make_bmp(w,h,top_down); base_writes=writes; base_physical=physical_writes;
            base_masked=masked_writes; base_starts=starts;
            kick(); @(posedge load_done); #1;
            if(memory_error || !complete[2] || writes-base_writes!=w*h || starts-base_starts!=1)
                $fatal(1,"Load %dx%d failed: err %h writes %d",w,h,memory_error,writes-base_writes);
            if(bank_widths[47:32]!=w || bank_heights[47:32]!=h) $fatal(1,"Geometry lost crossing clocks");
            if(bank_flips[2]!==!top_down) $fatal(1,"Orientation metadata lost");
            if(physical_writes-base_physical!=((w*h+3)/4)*4 ||
               masked_writes-base_masked!=((4-(w*h)%4)%4))
                $fatal(1,"Physical write padding for %dx%d: total %d masked %d",w,h,
                    physical_writes-base_physical,masked_writes-base_masked);
            for(i=0;i<w*h;i=i+1) begin
                logical_y=top_down ? i/w : h-1-i/w;
                if(memory[i]!==24'h102000+logical_y*w+i%w) $fatal(1,"Orientation/padding pixel %d: %h",i,memory[i]);
                checks=checks+1;
            end
            repeat(20) @(negedge sd_clk);
        end
    endtask
    task reject_image;
        begin
            base_starts=starts; kick(); @(posedge load_error); #1;
            if(bmp_error==0 || starts!=base_starts) $fatal(1,"Invalid BMP opened loader");
            repeat(20) @(negedge sd_clk);
        end
    endtask
    reg test_pass=0;
    initial begin
        repeat(10) @(negedge sd_clk); rst=0;
        good_image(3,2,0); good_image(2,3,1); good_image(1,1,0);
        good_image(17,5,0); good_image(320,2,1);
        make_bmp(3,2,0); le32(22,0); reject_image();
        make_bmp(3,2,0); le32(18,32'hffffffff); reject_image();
        make_bmp(3,2,0); le32(30,1); reject_image();
        make_bmp(3,2,0); le32(2,length-1); reject_image();
        make_bmp(3,2,0); le32(18,1000); le32(22,1000);
        length=3000054; le32(2,length); reject_image();
        test_pass=1; $display("PASS: dynamic BMP/FAT/CDC/loader %0d pixels, padding, orientation, five invalid headers",checks); $finish;
    end
    initial begin #10000000; $fatal(1,"BMP timeout"); end
endmodule
