`timescale 1ns/1ps
module tb_adjusted_video_alignment;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    wire raw_hs,raw_vs,raw_de,raw_line;
    wire [11:0] raw_x,raw_y;
    color_bar timing_source (
        .clk(clk),.rst(!rst_n),.hs(raw_hs),.vs(raw_vs),.de(raw_de),
        .line_active(raw_line),.pixel_x(raw_x),.pixel_y(raw_y),.rgb_r(),.rgb_g(),.rgb_b()
    );
    reg hs_q=1,vs_q=1,de_q=0,line_q=0,raw_vs_q=0;
    reg [23:0] source_rgb=0;
    wire [9:0] reader_x;
    always @(posedge clk) begin
        if (!rst_n) begin
            hs_q<=1; vs_q<=1; de_q<=0; line_q<=0; raw_vs_q<=0; source_rgb<=0;
        end else begin
            hs_q<=raw_hs; vs_q<=raw_vs; de_q<=raw_de; line_q<=raw_line; raw_vs_q<=raw_vs;
            source_rgb<=raw_de ? {raw_x[7:0],raw_y[7:0],raw_x[7:0]^raw_y[7:0]} : 0;
        end
    end
    hdmi_video_position position (
        .clk(clk),.rst_n(rst_n),.hsync(hs_q),.de(de_q),.x(reader_x)
    );
    reg update_valid=0;
    wire ready;
    wire [7:0] brightness,contrast;
    param_config_service config_service (
        .ctrl_clk(clk),.ctrl_rst_n(rst_n),.update_valid(update_valid),
        .brightness_in(8'd144),.contrast_in(8'd160),.ready(ready),
        .pix_clk(clk),.pix_rst_n(rst_n),.frame_start(raw_vs_q&&!raw_vs),
        .brightness_frame(brightness),.contrast_frame(contrast)
    );
    wire hs,vs,de,line_active;
    wire [9:0] x;
    wire [23:0] rgb;
    brightness_contrast_adjust adjust (
        .clk(clk),.rst_n(rst_n),.rgb_in(source_rgb),.in_de(de_q),
        .in_hsync(hs_q),.in_vsync(vs_q),.in_line_active(line_q),.in_pixel_x(reader_x),
        .brightness(brightness),.contrast(contrast),.rgb_out(rgb),.out_de(de),
        .out_hsync(hs),.out_vsync(vs),.out_line_active(line_active),.out_pixel_x(x)
    );
    osd_overlay_24 osd (
        .clk(clk),.rst_n(rst_n),.vsync(vs),.de(de),.rgb_in(rgb),.pixel_x(x),
        .active_index(2'd0),.auto_enabled(1'b0),.error_code(8'd0),
        .brightness(brightness),.contrast(contrast),.volume(8'd255),.param_valid(1'b1),
        .rgb_out(),.de_out(),.osd_active()
    );
    function [7:0] reference_channel(input integer value,input integer b,input integer c);
        integer product,value_out;
        begin
            product=(value-128)*c;
            value_out=product/128+b;
            if(product<0 && product%128!=0) value_out=value_out-1;
            reference_channel=value_out<0 ? 0 : value_out>255 ? 255 : value_out;
        end
    endfunction
    integer pixels=0,expected_x,expected_y,b,c;
    reg [23:0] expected_rgb;
    reg prior_de=0,test_pass=0;
    always @(posedge clk) if (rst_n) begin
        update_valid<=0;
        prior_de<=de;
        if(de) begin
            expected_x=pixels%640;
            expected_y=(pixels/640)%480;
            b=pixels<307200 ? 128 : 144;
            c=pixels<307200 ? 128 : 160;
            expected_rgb={reference_channel(expected_x%256,b,c),
                reference_channel(expected_y%256,b,c),
                reference_channel((expected_x%256)^(expected_y%256),b,c)};
            if(x!==expected_x || rgb!==expected_rgb || line_active!==1)
                $fatal(1,"Raster mismatch at pixel %d x=%d expected %d rgb=%h expected %h",pixels,x,expected_x,rgb,expected_rgb);
            if(osd.u_osd.brightness_q!==b || osd.u_osd.contrast_q!==c ||
               osd.u_osd.volume_q!==8'd255)
                $fatal(1,"OSD and pixel parameters disagree in active video");
            // Request a new pair during active video. It must apply next frame.
            if(pixels==100) update_valid<=1;
            pixels=pixels+1;
        end
        if(prior_de&&!de && pixels%640!=0) $fatal(1,"Active line length changed");
        if(pixels==614400) begin
            test_pass=1;
            $display("PASS: 2 full 640x480 frames, pixel/DE/X/line alignment and OSD frame parameters");
            $finish;
        end
    end
    initial begin repeat(5) @(negedge clk); rst_n=1; end
    initial begin #12000000; $fatal(1,"Video alignment timeout"); end
endmodule
