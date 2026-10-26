`timescale 1ns/1ps
module tb_brightness_contrast;
    reg clk=0, pix_clk=0, rst_n=0;
    always #5 clk=~clk;
    always #17 pix_clk=~pix_clk;
    // Raw board pads: both OFF (logical 00) switches read as 11.
    reg key4_n=1, sw1=1, sw2=1;
    wire [7:0] menu_volume, menu_b, menu_c;
    wire update_valid;
    wire menu_event;
    wire [1:0] menu_kind;
    wire [3:0] menu_level;
    integer event_count=0;
    integer menu_event_count=0;
    reg test_pass=0;
    param_menu_controller #(.CLKS_PER_MS(1), .DEBOUNCE_MS(3),
        .LONG_HOLD_MS(30)) menu (
        .clk(clk), .rst_n(rst_n), .key4_n(key4_n), .sw1(sw1), .sw2(sw2),
        .input_inhibit(1'b0),
        .service_ready(1'b1), .live_volume(8'd0), .live_period_ms(32'd5000),
        .cfg_update_valid(update_valid), .cfg_brightness(menu_b), .cfg_contrast(menu_c),
        .cfg_period_ms(), .cfg_volume(menu_volume), .menu_event(menu_event),
        .menu_kind(menu_kind), .menu_level(menu_level)
    );
    always @(posedge clk) if (update_valid) event_count=event_count+1;
    always @(posedge clk) if (menu_event) menu_event_count=menu_event_count+1;

    reg service_update=0, frame_start=0;
    reg [7:0] service_b=128, service_c=128;
    wire service_ready;
    wire [7:0] frame_b, frame_c;
    param_config_service service (
        .ctrl_clk(clk), .ctrl_rst_n(rst_n), .update_valid(service_update),
        .brightness_in(service_b), .contrast_in(service_c), .ready(service_ready),
        .pix_clk(pix_clk), .pix_rst_n(rst_n), .frame_start(frame_start),
        .brightness_frame(frame_b), .contrast_frame(frame_c)
    );
    reg [23:0] rgb=0;
    reg [7:0] brightness=128, contrast=128;
    reg pixel_de=1, pixel_hs=1, pixel_vs=1, pixel_line=1;
    reg [9:0] pixel_x=0;
    wire [23:0] adjusted;
    wire adjusted_de;
    wire adjusted_hs, adjusted_vs, adjusted_line;
    wire [9:0] adjusted_x;
    brightness_contrast_adjust pixels (
        .clk(clk), .rst_n(rst_n), .rgb_in(rgb), .in_de(pixel_de),
        .in_hsync(pixel_hs), .in_vsync(pixel_vs), .in_line_active(pixel_line),
        .in_pixel_x(pixel_x), .brightness(brightness), .contrast(contrast),
        .rgb_out(adjusted), .out_de(adjusted_de), .out_hsync(adjusted_hs),
        .out_vsync(adjusted_vs), .out_line_active(adjusted_line),
        .out_pixel_x(adjusted_x)
    );
    // Integer reference with explicit floor division for negative products.
    function [7:0] reference_channel(input integer value, input integer b, input integer c);
        integer product, value_out;
        begin
            product=(value-128)*c;
            value_out=product/128+b;
            if (product<0 && product%128!=0) value_out=value_out-1;
            reference_channel=value_out<0 ? 0 : value_out>255 ? 255 : value_out;
        end
    endfunction
    reg [23:0] expected_rgb[0:3];
    reg [13:0] expected_timing[0:3];
    integer slot;
    reg check_stream=0;
    always @(posedge clk) begin
        if (!rst_n) begin
            for(slot=0;slot<4;slot=slot+1) begin
                expected_rgb[slot]=0;
                expected_timing[slot]={1'b1,1'b1,1'b0,1'b0,10'd0};
            end
        end else begin
            for(slot=3;slot>0;slot=slot-1) begin
                expected_rgb[slot]=expected_rgb[slot-1];
                expected_timing[slot]=expected_timing[slot-1];
            end
            expected_rgb[0]=pixel_de ?
                {reference_channel(rgb[23:16],brightness,contrast),
                 reference_channel(rgb[15:8],brightness,contrast),
                 reference_channel(rgb[7:0],brightness,contrast)} : 24'd0;
            expected_timing[0]={pixel_hs,pixel_vs,pixel_line,pixel_de,pixel_x};
            #1;
            if (check_stream && (adjusted!==expected_rgb[3] ||
                {adjusted_hs,adjusted_vs,adjusted_line,adjusted_de,adjusted_x}!==expected_timing[3]))
                $fatal(1,"Pixel/parameter/timing pipeline misalignment at x=%d",adjusted_x);
        end
    end
    task tick(input integer count);
        repeat(count) @(negedge clk);
    endtask
    task short_press;
        key4_n=0; tick(12); key4_n=1; tick(12);
    endtask
    task long_press;
        key4_n=0; tick(55); key4_n=1; tick(12);
    endtask
    task commit_frame;
        @(negedge pix_clk); frame_start=1;
        @(negedge pix_clk); frame_start=0;
        tick(8);
    endtask
    task check_pixel(input [23:0] value, input [7:0] b, input [7:0] c,
                     input [23:0] expected);
        @(negedge clk); rgb=value; brightness=b; contrast=c; pixel_de=1;
        repeat(4) @(posedge clk);
        #2;
        if (adjusted!==expected || adjusted_de!==1)
            $fatal(1,"Pixel adjustment failed: got %h, expected %h",adjusted,expected);
    endtask
    integer i;
    initial begin
        tick(4); rst_n=1; tick(12);
        if (menu_b!==128 || menu_c!==128 || menu_volume!==255)
            $fatal(1,"Bad parameter defaults");
        // A contact bounce shorter than the debounce interval is ignored.
        key4_n=0; tick(1); key4_n=1; tick(12);
        if (event_count!=0) $fatal(1,"Debounce generated an event");
        short_press();
        if (menu_b!==128 || menu_c!==144 || event_count!=1)
            $fatal(1,"00 short press did not increase contrast");
        long_press();
        if (menu_c!==128 || event_count!=2)
            $fatal(1,"Long press must decrease once, with no release increment");
        sw1=0; sw2=0; tick(12); short_press();
        if (menu_b!==144 || menu_c!==128) $fatal(1,"11 did not select brightness");
        long_press();
        if (menu_b!==128) $fatal(1,"Brightness long press failed");
        // Physical SW1=1/SW2=0 selects volume (logical active-low mode 01).
        sw1=1; sw2=0; tick(12); short_press();
        if (menu_volume!==0 || menu_kind!==1 || menu_level!==0 || event_count!=4)
            $fatal(1,"Volume short press did not wrap 255 to 0");
        long_press();
        if (menu_volume!==255 || menu_kind!==1 || menu_level!==4 || event_count!=4)
            $fatal(1,"Volume long press did not wrap 0 to 255");
        short_press(); if (menu_volume!==0)   $fatal(1,"Volume step 255->0 failed");
        short_press(); if (menu_volume!==64)  $fatal(1,"Volume step 0->64 failed");
        short_press(); if (menu_volume!==128) $fatal(1,"Volume step 64->128 failed");
        short_press(); if (menu_volume!==192) $fatal(1,"Volume step 128->192 failed");
        short_press(); if (menu_volume!==255) $fatal(1,"Volume step 192->255 failed");
        long_press(); if (menu_volume!==192) $fatal(1,"Volume step 255->192 failed");
        long_press(); if (menu_volume!==128) $fatal(1,"Volume step 192->128 failed");
        long_press(); if (menu_volume!==64)  $fatal(1,"Volume step 128->64 failed");
        long_press(); if (menu_volume!==0)   $fatal(1,"Volume step 64->0 failed");
        long_press(); if (menu_volume!==255) $fatal(1,"Volume step 0->255 failed");
        if (menu_event_count!=16) $fatal(1,"Unexpected KEY4 menu event count");

        sw1=0; sw2=1; tick(12); short_press(); long_press();
        if (event_count!=4 || menu_event_count!=16)
            $fatal(1,"Physical 01 must not change parameters");
        sw1=0; sw2=0; tick(12);
        repeat(10) short_press();
        if (menu_b!==255) $fatal(1,"Upper saturation failed");
        repeat(18) long_press();
        if (menu_b!==0) $fatal(1,"Lower saturation failed");

        service_b=144; service_c=160; service_update=1; tick(1); service_update=0;
        // Mutating the source afterwards must not corrupt the held pair.
        service_b=200; service_c=220; tick(25);
        if (service_ready!==0 || frame_b!==128 || frame_c!==128)
            $fatal(1,"Configuration changed before a frame boundary");
        commit_frame();
        if (frame_b!==144 || frame_c!==160 || service_ready!==1)
            $fatal(1,"Atomic frame-boundary application/ack failed");
        commit_frame();
        if (frame_b!==144 || frame_c!==160) $fatal(1,"No update must keep old pair");

        for(i=0;i<256;i=i+1)
            check_pixel({i[7:0],i[7:0],i[7:0]},128,128,{i[7:0],i[7:0],i[7:0]});
        check_pixel(24'h4080c0,144,128,24'h5090d0);
        check_pixel(24'h4080c0,128,192,24'h2080e0);
        check_pixel(24'h00ff35,128,0,24'h808080);
        check_pixel(24'hffffff,255,128,24'hffffff);
        check_pixel(24'h000000,0,128,24'h000000);
        // Continuous active/blanking pixels, line wrap, and parameters changed
        // on successive pixels test the exact four-clock data/timing latency.
        @(negedge clk); check_stream=1;
        for(i=0;i<2400;i=i+1) begin
            rgb=$random;
            brightness=$random; contrast=$random;
            pixel_x=i%800;
            pixel_de=pixel_x<640 && i<1600;
            pixel_line=i<1600;
            pixel_hs=!(pixel_x>=656 && pixel_x<752);
            pixel_vs=i<1600;
            tick(1);
        end
        tick(6); check_stream=0;
        test_pass=1;
        $display("PASS: KEY4 B/C/volume selection, five-step volume loop, atomic frame config, pixel adjustment");
        $finish;
    end
    initial begin #200000; $fatal(1,"Test timeout"); end
endmodule
