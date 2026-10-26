`timescale 1ns/1ps
module tb_dynamic_text;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg vs = 1, de = 0;
    reg [9:0] x = 0;
    reg [1:0] image_index = 0;
    reg auto_enabled = 0;
    wire [23:0] rgb;
    reg test_pass = 0;
    reg timer_done = 0;
    reg previous_pixels [0:11519];
    integer row, col, f, hits, address, n;
    reg [9:0] frame_position;
    reg [95:0] frame_text;

    dynamic_text_overlay dut (
        .clk(clk), .rst_n(rst_n), .vsync(vs), .de(de), .pixel_x(x),
        .rgb_in(24'h123456), .active_index(image_index),
        .auto_enabled(auto_enabled), .rgb_out(rgb)
    );

    task frame_boundary;
        begin
            @(negedge clk); de = 0; vs = 0;
            repeat (3) @(negedge clk);
            vs = 1;
            repeat (2) @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);
        for (f = 0; f < 3; f = f + 1) begin
            if (f == 1) begin image_index = 0; auto_enabled = 0; end
            if (f == 2) begin image_index = 3; auto_enabled = 1; end
            frame_boundary;
            if (dut.u_subtitle.scroll_pos !== f+1)
                $fatal(1, "Scroll must advance exactly one pixel per frame");
            frame_position = dut.u_subtitle.scroll_pos;
            frame_text = dut.u_subtitle.subtitle_text_frame;
            if (frame_text[7:0] != "P" || frame_text[39:32] != (f == 2 ? "4" : "1") ||
                frame_text[55:48] != (f == 2 ? "A" : "M"))
                $fatal(1, "Subtitle does not follow image/mode at frame boundary");
            hits = 0;
            for (row = 0; row < 92; row = row + 1) begin
                // Changing inputs during a frame must not tear the text.
                if (f == 0 && row == 20) begin image_index = 2; auto_enabled = 1; end
                for (col = 0; col < 640; col = col + 1) begin
                    de = 1; x = col;
                    #1;
                    if (dut.line_y != row || dut.u_subtitle.line_y != row)
                        $fatal(1, "Overlay row is not aligned with DE");
                    if (dut.u_subtitle.scroll_pos != frame_position ||
                        dut.u_subtitle.subtitle_text_frame != frame_text)
                        $fatal(1, "Position or text changed within the frame");
                    if (!dut.u_subtitle.overlay_active && !dut.u_timer.ts_active && rgb !== 24'h123456)
                        $fatal(1, "Background/band or latency changed a non-text pixel");
                    if (dut.u_subtitle.overlay_active) begin
                        if (rgb !== 24'hfff080) $fatal(1, "Subtitle glyph is not visible");
                        hits = hits + 1;
                    end
                    if (row >= 72 && row < 90) begin
                        address = (row-72)*640 + col;
                        if (f == 1 && col < 639 &&
                            dut.u_subtitle.overlay_active !== previous_pixels[address+1])
                            $fatal(1, "Raster did not move left by one pixel at row=%0d x=%0d", row, col);
                        if (f == 0) previous_pixels[address] = dut.u_subtitle.overlay_active;
                    end
                    @(negedge clk);
                end
                de = 0;
                #1;
                if (rgb !== 24'h123456) $fatal(1, "Blanking RGB changed");
                repeat (2) @(negedge clk);
            end
            if (hits < 100) $fatal(1, "Subtitle glyphs are missing");
        end
        // Complete the entire scroll cycle using blank frames.
        for (n = 3; n < 856; n = n + 1) begin
            frame_boundary;
            if (dut.u_subtitle.scroll_pos !== ((n+1) % 856))
                $fatal(1, "Incorrect one-pixel scroll/wrap at frame %0d", n);
        end
        // First P at x=4 on wrap: confirms no artificial eight-pixel margin.
        for (row = 0; row < 74; row = row + 1) begin
            de = 1; x = 0; @(negedge clk);
            de = 0; repeat (2) @(negedge clk);
        end
        de = 1; x = 4; #1;
        if (rgb !== 24'hfff080) $fatal(1, "Subtitle still has an artificial left margin");
        de = 0;
        wait(timer_done);
        $display("PASS: timer, frame-latched dynamic text, one-pixel raster scrolling, wrap and transparent background");
        test_pass = 1;
        $finish;
    end

    // Accelerate only the timer unit, and verify all 6000 seconds through 99:59.
    reg timer_reset = 0, timer_vs = 1;
    reg [9:0] timer_x = 502;
    wire [23:0] timer_rgb;
    wire timer_hit;
    integer seconds, cycles;
    reg [15:0] displayed_digits;
    timestamp_osd #(.PIXEL_HZ(10)) timer_unit (
        .pix_clk(clk), .pix_rst_n(timer_reset), .sys_rst_n(timer_reset),
        .enable(1'b1), .vsync(timer_vs), .de(1'b1),
        .pixel_x(timer_x), .pixel_y(12'd8), .rgb_in(24'h123456),
        .rgb_out(timer_rgb), .ts_active(timer_hit)
    );
    initial begin
        repeat (4) @(negedge clk);
        timer_reset = 1;
        repeat (2) @(negedge clk); // synchronized timer reset release
        displayed_digits = 0;
        for (seconds = 1; seconds <= 6000; seconds = seconds + 1) begin
            for (cycles = 0; cycles < 10; cycles = cycles + 1) begin
                @(negedge clk);
                if ({timer_unit.mm_tens,timer_unit.mm_ones,timer_unit.ss_tens,timer_unit.ss_ones} !== displayed_digits)
                    $fatal(1, "Displayed timer changed outside a frame boundary");
            end
            if (timer_unit.second_ones != seconds%10 ||
                timer_unit.second_tens != (seconds%60)/10 ||
                timer_unit.minute_ones != (seconds/60)%10 ||
                timer_unit.minute_tens != ((seconds/60)/10)%10)
                $fatal(1, "Timer second/minute rollover failed at %0d seconds", seconds);
            if (seconds == 1 || seconds == 60 || seconds == 6000) begin
                timer_vs = 0;
                @(negedge clk);
                displayed_digits = {timer_unit.mm_tens,timer_unit.mm_ones,timer_unit.ss_tens,timer_unit.ss_ones};
                if (timer_unit.mm_tens != ((seconds/60)/10)%10 ||
                    timer_unit.mm_ones != (seconds/60)%10 ||
                    timer_unit.ss_tens != (seconds%60)/10 || timer_unit.ss_ones != seconds%10)
                    $fatal(1, "Frame-latched timer digits are incorrect");
                timer_vs = 1;
                // One cycle spent on frame latch; consume nine more to align next tick.
                repeat (9) @(negedge clk);
                seconds = seconds + 1;
            end
        end
        // Reset returns to 00:00; zero's top stroke is doubled horizontally.
        timer_reset = 0; @(negedge clk); timer_reset = 1;
        repeat (4) @(negedge clk);
        timer_x = 502; #1;
        if (!timer_hit || timer_rgb !== 24'hE0F0FF) $fatal(1, "Timer glyph missing");
        timer_x = 503; #1;
        if (!timer_hit) $fatal(1, "Timer font horizontal scaling failed");
        timer_x = 500; #1;
        if (timer_hit || timer_rgb !== 24'h123456) $fatal(1, "Timer painted a background");
        timer_done = 1;
    end
    initial begin
        #10000000;
        $fatal(1, "Dynamic text test timeout");
    end
endmodule
