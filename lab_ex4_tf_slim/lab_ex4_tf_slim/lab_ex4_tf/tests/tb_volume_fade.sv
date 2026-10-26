`timescale 1ns/1ps

module tb_volume_fade;
    reg pix_clk = 0;
    reg aud_clk = 0;
    reg rst_n = 0;
    reg frame_start = 0;
    reg [7:0] alpha = 8'd255;
    reg fade_active = 0;
    reg signed [15:0] pcm_left = 0;
    reg signed [15:0] pcm_right = 0;
    reg [7:0] volume = 8'd255;
    reg in_valid = 0;
    wire [7:0] fade_gain;
    wire in_ready;
    wire out_valid;
    wire signed [15:0] scaled_left;
    wire signed [15:0] scaled_right;
    reg test_pass = 0;

    always #5 pix_clk = ~pix_clk;
    always #7 aud_clk = ~aud_clk;

    sync_fade_gain sync_gain (
        .pix_clk(pix_clk), .pix_rst_n(rst_n), .frame_start(frame_start),
        .alpha_pix(alpha), .fade_active(fade_active),
        .aud_clk(aud_clk), .aud_rst_n(rst_n), .gain_aud(fade_gain)
    );

    pcm_gain_scale scaler (
        .clk(aud_clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_ready(in_ready),
        .pcm_left_in(pcm_left), .pcm_right_in(pcm_right),
        .boost_3x(1'b0),
        .volume(volume), .fade_gain(fade_gain),
        .out_valid(out_valid), .out_ready(1'b1),
        .pcm_left_out(scaled_left), .pcm_right_out(scaled_right)
    );

    task latch_frame(input [7:0] next_alpha, input next_active);
        begin
            @(negedge pix_clk);
            alpha = next_alpha;
            fade_active = next_active;
            frame_start = 1;
            @(negedge pix_clk);
            frame_start = 0;
            repeat (6) @(negedge aud_clk);
        end
    endtask

    task scale_and_check(
        input signed [15:0] left_in,
        input signed [15:0] right_in,
        input [7:0] level,
        input signed [15:0] left_expected,
        input signed [15:0] right_expected
    );
        begin
            @(negedge aud_clk);
            pcm_left = left_in;
            pcm_right = right_in;
            volume = level;
            in_valid = 1'b1;
            while (!in_ready) @(negedge aud_clk);
            @(negedge aud_clk);
            in_valid = 1'b0;
            wait (out_valid);
            #1;
            if (scaled_left !== left_expected || scaled_right !== right_expected)
                $fatal(1, "Gain scaling failed: left=%0d/%0d right=%0d/%0d",
                       scaled_left, left_expected, scaled_right, right_expected);
        end
    endtask

    initial begin
        repeat (4) @(negedge pix_clk);
        rst_n = 1;
        repeat (4) @(negedge aud_clk);

        scale_and_check(16'sd1000, -16'sd1000, 8'd128, 16'sd501, -16'sd501);

        latch_frame(8'd128, 1'b1);
        if (fade_gain !== 8'd128)
            $fatal(1, "Fade gain did not track alpha: gain=%0d", fade_gain);
        scale_and_check(16'sd1000, -16'sd1000, 8'd128, 16'sd251, -16'sd251);

        latch_frame(8'd0, 1'b1);
        if (fade_gain !== 8'd0) $fatal(1, "Fade-to-zero gain failed");
        scale_and_check(16'sd1000, -16'sd1000, 8'd128, 16'sd0, 16'sd0);

        latch_frame(8'd255, 1'b0);
        if (fade_gain !== 8'd255) $fatal(1, "Unity fade gain did not restore");
        scale_and_check(-16'sd32768, 16'sd32767, 8'd255,
                        -16'sd32768, 16'sd32767);

        test_pass = 1;
        $display("PASS: exact PCM*gain/255 scaling and frame-synchronous fade gain");
        $finish;
    end

    initial begin #10000; $fatal(1, "Volume/fade timeout"); end
endmodule
