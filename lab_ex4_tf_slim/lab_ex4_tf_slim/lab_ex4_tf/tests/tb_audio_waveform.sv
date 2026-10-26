`timescale 1ns/1ps

module tb_audio_waveform;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg vsync = 1'b1;
    reg de = 1'b0;
    reg [9:0] pixel_x = 10'd0;
    reg enable = 1'b1;
    reg pcm_valid = 1'b0;
    reg signed [15:0] pcm_left = 16'sd0;
    wire [23:0] rgb_out;
    wire waveform_active;
    integer i;

    promax_audio_waveform dut (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de),
        .rgb_in(24'h123456), .pixel_x(pixel_x), .enable(enable),
        .pcm_tap_valid(pcm_valid), .pcm_tap_left(pcm_left),
        .rgb_out(rgb_out), .waveform_active(waveform_active)
    );

    task send_sample;
        input signed [15:0] value;
        begin
            @(negedge clk);
            pcm_left = value;
            pcm_valid = 1'b1;
        end
    endtask

    task publish_frame;
        begin
            @(negedge clk);
            pcm_valid = 1'b0;
            vsync = 1'b0;
            repeat (2) @(negedge clk);
            vsync = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    task check_pixel;
        input [9:0] x;
        input [11:0] y;
        input expected_active;
        begin
            pixel_x = x;
            dut.line_y = y;
            #1;
            if (waveform_active !== expected_active)
                $fatal(1, "Unexpected active state at (%0d,%0d)", x, y);
            if (rgb_out !== (expected_active ? 24'h1f6b32 : 24'h123456))
                $fatal(1, "Unexpected color at (%0d,%0d): %h", x, y,
                       rgb_out);
        end
    endtask

    task check_pixel_color;
        input [9:0] x;
        input [11:0] y;
        input expected_active;
        input [23:0] expected_color;
        begin
            pixel_x = x;
            dut.line_y = y;
            #1;
            if (waveform_active !== expected_active || rgb_out !== expected_color)
                $fatal(1, "Unexpected pixel at (%0d,%0d): active=%b rgb=%h",
                       x, y, waveform_active, rgb_out);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // A single full-scale impulse must not produce a visible noise block.
        for (i = 0; i < 32; i = i + 1)
            send_sample(i == 11 ? -16'sh8000 : 16'sd0);
        publish_frame;
        if (dut.height_history[0] !== 6'd0)
            $fatal(1, "An isolated impulse reached the display");

        // Sustained quarter-scale audio creates a 16-pixel column at the
        // right edge; every other history slot is still empty.
        for (i = 0; i < 32; i = i + 1)
            send_sample(16'sh2000);
        publish_frame;
        if (dut.height_history[1] !== 6'd12)
            $fatal(1, "Expected rightmost height 12 units, got %0d",
                   dut.height_history[1]);

        de = 1'b1;
        check_pixel(10'd560, 12'd440, 1'b1); // newest column top
        check_pixel(10'd571, 12'd463, 1'b1); // newest column bottom-right
        check_pixel(10'd572, 12'd463, 1'b0); // four-pixel gap
        check_pixel(10'd560, 12'd439, 1'b0); // unlit area above column
        check_pixel(10'd544, 12'd463, 1'b0); // older slot is still empty

        // A quiet frame inserts an invisible slot while preserving the
        // previous column's height through the right and middle regions.
        de = 1'b0;
        for (i = 0; i < 32; i = i + 1)
            send_sample(16'sd1024);
        publish_frame;
        if (dut.height_history[2] !== 6'd0)
            $fatal(1, "Noise-floor samples created a new column");
        de = 1'b1;
        check_pixel(10'd544, 12'd442, 1'b1);
        check_pixel(10'd544, 12'd441, 1'b1);
        check_pixel(10'd544, 12'd439, 1'b0);
        check_pixel(10'd560, 12'd463, 1'b0);

        // Full-scale input reaches the complete 64-pixel height.  The
        // negative endpoint uses the same safe unsigned magnitude path.
        de = 1'b0;
        for (i = 0; i < 32; i = i + 1)
            send_sample(16'sh7fff);
        publish_frame;
        if (dut.height_history[3] !== 6'd32)
            $fatal(1, "Positive full scale did not reach full height");
        for (i = 0; i < 32; i = i + 1)
            send_sample(-16'sh8000);
        publish_frame;
        if (dut.height_history[4] !== 6'd32)
            $fatal(1, "Full-scale history did not shift into the next slot");
        de = 1'b1;
        check_pixel(10'd560, 12'd400, 1'b1); // newest full-height column
        check_pixel(10'd544, 12'd400, 1'b1); // stable through the middle
        check_pixel(10'd544, 12'd399, 1'b0); // top edge, no baseline

        // Low-level background plus one full-scale transient remains below
        // the averaged display threshold.
        de = 1'b0;
        for (i = 0; i < 32; i = i + 1)
            send_sample(i == 31 ? 16'sh7fff : 16'sd3000);
        publish_frame;
        if (dut.height_history[5] !== 6'd0)
            $fatal(1, "A transient spike created a visible column");

        // Exercise the full waterfall age curve with a uniform history.
        for (i = 0; i < 32; i = i + 1)
            dut.height_history[i] = 6'd32;
        dut.write_pointer = 5'd1;
        dut.valid_count = 6'd32;
        de = 1'b1;
        check_pixel(10'd272, 12'd400, 1'b1); // age 18: full height held
        check_pixel_color(10'd160, 12'd403, 1'b0, 24'h123456);
        check_pixel_color(10'd160, 12'd404, 1'b1, 24'h184f44);
        check_pixel(10'd64, 12'd463, 1'b0); // fully faded at left edge

        // Disabling the overlay clears all retained energy immediately.
        @(negedge clk);
        de = 1'b0;
        enable = 1'b0;
        @(negedge clk);
        if (dut.valid_count !== 6'd0)
            $fatal(1, "Disable did not invalidate the waterfall history");

        // RAM contents intentionally are not reset.  The valid mask must
        // prevent those stale values from producing a pixel after re-enable.
        enable = 1'b1;
        de = 1'b1;
        check_pixel(10'd560, 12'd400, 1'b0);
        check_pixel(10'd544, 12'd463, 1'b0);

        $display("PASS: waterfall volume columns shift, fade smoothly, and reject noise");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Waterfall volume test timeout");
    end
endmodule
