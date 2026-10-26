`timescale 1ns/1ps

// Diagnostic: use the same timing, one-cycle registration, position tracker
// and OSD as the board top. No SD card is needed to display status text.
module tb_osd_display;
    reg clk = 0;
    always #20 clk = ~clk;
    reg rst_n = 0;
    wire raw_hs, raw_vs, raw_de, raw_line;
    reg hs = 1, vs = 1, de = 0;
    wire [9:0] x;
    wire [23:0] rgb_out;
    wire [23:0] status_rgb;
    wire de_out, osd_active;
    integer frames = 0;
    integer pixels = 0;
    integer subtitle_pixels = 0, timer_pixels = 0;
    integer min_x = 1024, max_x = 0, min_y = 4096, max_y = 0;
    reg prev_vs = 1;
    reg test_pass = 0;

    color_bar timing (
        .clk(clk), .rst(~rst_n), .hs(raw_hs), .vs(raw_vs),
        .de(raw_de), .line_active(raw_line), .pixel_x(), .pixel_y(),
        .rgb_r(), .rgb_g(), .rgb_b()
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs <= 1; vs <= 1; de <= 0;
        end else begin
            hs <= raw_hs; vs <= raw_vs; de <= raw_de;
        end
    end
    hdmi_video_position position (
        .clk(clk), .rst_n(rst_n), .hsync(hs), .de(de), .x(x)
    );
    osd_overlay_24 #(.OSD_X(8), .OSD_Y(8)) dut (
        .clk(clk), .rst_n(rst_n), .vsync(vs), .de(de),
        .rgb_in(24'h123456), .pixel_x(x), .active_index(2'd0),
        .auto_enabled(1'b0), .error_code(8'd0),
        .brightness(8'd128), .contrast(8'd192), .volume(8'd255),
        .param_valid(1'b1),
        .rgb_out(status_rgb), .de_out(de_out), .osd_active(osd_active)
    );
    dynamic_text_overlay dynamic_dut (
        .clk(clk), .rst_n(rst_n), .vsync(vs), .de(de), .pixel_x(x),
        .rgb_in(status_rgb), .active_index(2'd0), .auto_enabled(1'b0),
        .rgb_out(rgb_out)
    );

    // Sample before the edge, exactly as the HDMI encoder consumes RGB.
    always @(posedge clk) begin
        if (rst_n) begin
            if (prev_vs && !vs) begin
                if (frames == 2) begin
                    if (pixels < 200 || min_x != 8 || max_x != 52 ||
                        min_y != 8 || max_y != 30)
                        $fatal(1, "OSD missing/misaligned: pixels=%0d x=%0d..%0d y=%0d..%0d",
                               pixels, min_x, max_x, min_y, max_y);
                    if (subtitle_pixels < 100 || timer_pixels < 100)
                        $fatal(1, "Dynamic overlay missing in actual video: subtitle=%0d timer=%0d",
                               subtitle_pixels, timer_pixels);
                    $display("PASS: actual timing produces %0d B/C/V percentage OSD pixels, x=%0d..%0d y=%0d..%0d",
                             pixels, min_x, max_x, min_y, max_y);
                    $display("PASS: actual HDMI timing also produces %0d subtitle and %0d timer glyph pixels/frame",
                             subtitle_pixels, timer_pixels);
                    test_pass = 1;
                    $finish;
                end
                frames = frames + 1;
                pixels = 0; min_x = 1024; max_x = 0; min_y = 4096; max_y = 0;
                subtitle_pixels = 0; timer_pixels = 0;
            end
            prev_vs = vs;
            if (de_out !== de)
                $fatal(1, "OSD changed DE alignment");
            if (osd_active) begin
                if (!de || rgb_out !== 24'hffff00)
                    $fatal(1, "OSD hit is not an active yellow video pixel");
                pixels = pixels + 1;
                if (x < min_x) min_x = x;
                if (x > max_x) max_x = x;
                if (dut.line_y < min_y) min_y = dut.line_y;
                if (dut.line_y > max_y) max_y = dut.line_y;
            end else if (!dynamic_dut.u_subtitle.overlay_active &&
                         !dynamic_dut.u_timer.ts_active && rgb_out !== 24'h123456)
                $fatal(1, "Non-OSD RGB changed");
            if (dynamic_dut.u_subtitle.overlay_active) begin
                if (!de || rgb_out !== 24'hfff080 ||
                    dynamic_dut.line_y < 74 || dynamic_dut.line_y > 87)
                    $fatal(1, "Subtitle changed video alignment");
                subtitle_pixels = subtitle_pixels + 1;
            end
            if (dynamic_dut.u_timer.ts_active) begin
                if (!de || rgb_out !== 24'hE0F0FF || x < 500 || x >= 540 ||
                    dynamic_dut.line_y < 8 || dynamic_dut.line_y > 19)
                    $fatal(1, "Timer changed video alignment");
                timer_pixels = timer_pixels + 1;
            end
        end
    end
    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1;
        #60000000;
        $fatal(1, "Video frame timeout");
    end
endmodule
