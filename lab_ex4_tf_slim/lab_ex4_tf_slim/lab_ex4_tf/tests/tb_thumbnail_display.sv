`timescale 1ns/1ps
module tb_thumbnail_display;
    parameter W=64, H=48, FULL=0, MEM_HALF_PERIOD=4;
    reg mem_clk=0,pix_clk=0,rst_n=0;
    always #MEM_HALF_PERIOD mem_clk=~mem_clk;
    always #20 pix_clk=~pix_clk;
    reg fs=0,de=0;
    reg [11:0] x=0,y=0;
    reg [1:0] mode=0;
    reg [2:0] focus=1;
    reg [5:0] complete=6'h3f;
    reg blocked=0;
    wire req,layout_de,border,rd,busy,pvalid,underflow;
    wire [11:0] qx,qy;
    wire [2:0] idx;
    wire [15:0] sx,sy;
    wire [20:0] addr;
    wire [23:0] rgb;
    reg [15:0] widths[0:5],heights[0:5];
    reg [5:0] flips=6'b000001;
    wire [2:0] mi=mode==2 ? focus : idx;
    wire [15:0] mx=mode==2 ? qx : sx;
    wire [15:0] logical_y=mode==2 ? qy : sy;
    wire [15:0] my=flips[mi] ? heights[mi]-1-logical_y : logical_y;
    wire mv=mode==2 ? req && complete[focus] && qx<widths[focus] && qy<heights[focus] : layout_de;
    thumbnail_layout #(.DISPLAY_WIDTH(W),.DISPLAY_HEIGHT(H)) layout (
        .in_de(req),.pixel_x(qx),.pixel_y(qy),.focus_index(focus),.image_complete(complete),
        .fullscreen(mode==1),.fullscreen_fit(1'b1),
        .current_width(widths[focus]),.current_height(heights[focus]),
        .image_width0(widths[0]),.image_height0(heights[0]),
        .image_width1(widths[1]),.image_height1(heights[1]),
        .image_width2(widths[2]),.image_height2(heights[2]),
        .image_width3(widths[3]),.image_height3(heights[3]),
        .image_width4(widths[4]),.image_height4(heights[4]),
        .image_width5(widths[5]),.image_height5(heights[5]),
        .thumb_de(layout_de),.source_index(idx),.source_x(sx),.source_y(sy),.focus_border(border));
    reg [15:0] rvalid=0;
    reg [20:0] addresses[0:15];
    integer p;
    always @(posedge mem_clk) begin
        rvalid<={rvalid[14:0],rd}; addresses[0]<=addr;
        for(p=1;p<16;p=p+1) addresses[p]<=addresses[p-1];
    end
    // Ordered 16-cycle SDRAM response, including repeated/skipped addresses.
    media_frame_reader #(.DISPLAY_WIDTH(W),.DISPLAY_HEIGHT(H)) reader (
        .mem_clk(mem_clk),.mem_rst_n(rst_n),.controller_init_done(1'b1),
        .controller_busy(blocked),.refresh_active(1'b0),.write_request_busy(1'b0),
        .read_request_busy(busy),.app_rd_en(rd),.app_rd_addr(addr),
        .sdram_rd_valid(rvalid[15]),.sdram_rd_data({11'd0,addresses[15]}),
        .pix_clk(pix_clk),.pix_rst_n(rst_n),.frame_start(fs),.active_index(focus),
        .pixel_consume(de),.pixel_x(x),.pixel_y(y),
        .request_valid(req),.request_x(qx),.request_y(qy),
        .coordinate_valid(mv),.source_index(mi),.source_x(mx),.source_y(my),
        .source_stride(widths[mi]),.focus_border(mode==0 && border),
        .pixel_rgb(rgb),.pixel_valid(pvalid),.underflow(underflow),
        .reader_busy(),.frame_read_done(),.reader_index(),.reader_error());
    function [23:0] expected;
        input integer xx,yy;
        integer bank, lx,ly,ax,ay;
        begin
            bank=focus; lx=xx; ly=yy;
            if(mode==0) begin
                bank=(yy>=2*(H/3) ? 4 : yy>=H/3 ? 2 : 0)+(xx>=W/2 ? 1 : 0);
                lx=xx%(W/2); ly=yy%(H/3);
                ax=lx*widths[bank]/(W/2); ay=ly*heights[bank]/(H/3);
            end else if(mode==1) begin
                ax=xx*widths[bank]/W; ay=yy*heights[bank]/H;
            end else begin ax=xx; ay=yy; end
            if(mode==0 && bank==focus &&
               (lx<2 || ly<2 || lx>=W/2-2 || ly>=H/3-2)) expected=24'hffff00;
            else if(!complete[bank] || ax>=widths[bank] || ay>=heights[bank]) expected=0;
            else expected=bank*307200+(flips[bank] ? heights[bank]-1-ay : ay)*widths[bank]+ax;
        end
    endfunction
    integer checks=0,xx,yy;
    reg test_pass=0;
    task display_frame;
        begin
            @(negedge pix_clk); fs=1; de=0;
            @(negedge pix_clk); fs=0;
            repeat(W+200) @(negedge pix_clk);
            for(yy=0;yy<H;yy=yy+1) begin
                for(xx=0;xx<W;xx=xx+1) begin
                    x=xx; y=yy; de=1;
                    @(posedge pix_clk); #1;
                    if(!pvalid || rgb!==expected(xx,yy))
                        $fatal(1,"mode %0d pixel (%0d,%0d): rgb %h expected %h valid %b",mode,xx,yy,rgb,expected(xx,yy),pvalid);
                    checks=checks+1;
                    @(negedge pix_clk);
                end
                de=0; repeat(160) @(negedge pix_clk);
            end
        end
    endtask
    initial begin
        widths[0]=3; heights[0]=2;
        widths[1]=800; heights[1]=384;
        widths[2]=320; heights[2]=960;
        widths[3]=1; heights[3]=1;
        widths[4]=640; heights[4]=480;
        widths[5]=16; heights[5]=8;
        repeat(8) @(negedge pix_clk); rst_n=1;
        display_frame();
        if(FULL) begin
            // At real output size this also exercises the optimized /640 and
            // /480 fit mapping, which the compact generic-size test does not.
            mode=1; focus=2; display_frame();
            if(underflow) $fatal(1,"Unexpected full-frame line underrun");
            test_pass=1; $display("PASS: full %0dx%0d thumbnail and fitted frames, %0d mapped pixels, no underrun",W,H,checks); $finish;
        end else begin
            mode=1; focus=2; display_frame();
            mode=2; focus=0; display_frame();
            mode=0; complete=6'b010101; display_frame();
            if(underflow) $fatal(1,"Unexpected line underrun");
            // Missing a deadline must black the entire row, never shift pixels.
            @(negedge pix_clk); blocked=1; fs=1;
            @(negedge pix_clk); fs=0;
            repeat(20) @(negedge pix_clk);
            for(xx=0;xx<W;xx=xx+1) begin
                de=1; x=xx; y=0;
                @(posedge pix_clk); #1;
                if(pvalid || rgb!==0) $fatal(1,"Late row exposed stale pixels");
                @(negedge pix_clk);
            end
            de=0; blocked=0;
            repeat(W+500) @(negedge pix_clk);
            if(!underflow) $fatal(1,"Missing deadline not reported");
            test_pass=1; $display("PASS: %0d pixels, four display cases, stale-frame rejection",checks); $finish;
        end
    end
    initial begin #200000000; $fatal(1,"Display timeout"); end
endmodule
