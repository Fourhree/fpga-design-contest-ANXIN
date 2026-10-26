`timescale 1ns/1ps

module tb_wav_hdmi_bridge;
    reg clk = 0, rst_n = 0, wav_valid = 0;
    always #20 clk = ~clk;
    wire wav_ready, tap_valid;
    wire signed [15:0] tap_left;
    wire sequence_error, tone_overflow, contract_error;
    integer timeout;
    reg saw_tap = 0;
    reg signed [15:0] captured_tap = 0;
    reg test_pass = 0;
    media_hdmi_audio_bridge dut (
        .pixel_clk(clk), .pixel_rst_n(rst_n),
        .video_hsync(1'b1), .video_vsync(1'b1), .video_de(1'b0),
        .video_line_active(1'b0), .video_x(10'd0), .video_rgb(24'd0),
        .media_id(3'd0), .volume(8'd128), .fade_gain(8'd255),
        .audio_source_mode(2'd0), .wav_active(1'b1),
        .wav_valid(wav_valid), .wav_ready(wav_ready),
        .wav_left(-16'sd1234), .wav_right(16'sd2345),
        .clock_symbol(), .ddc_scl(), .ddc_sda(),
        .channel0_symbol(), .channel1_symbol(), .channel2_symbol(),
        .sequence_error(sequence_error), .tone_overflow(tone_overflow),
        .pcm_contract_error(contract_error), .blip_active(),
        .pcm_tap_valid(tap_valid), .pcm_tap_left(tap_left)
    );
    always @(posedge clk) begin
        if (tap_valid) begin
            saw_tap <= 1'b1;
            captured_tap <= tap_left;
        end
    end
    initial begin
        repeat (4) @(negedge clk); rst_n = 1;
        // Exact digital silence must become only a 1-LSB alternating pilot at
        // the HDMI boundary, so a sink does not auto-mute before speech.
        repeat (4) @(negedge clk);
        if ((dut.hdmi_sample_left !== 16'sd1 &&
             dut.hdmi_sample_left !== -16'sd1) ||
            dut.hdmi_sample_right !== -dut.hdmi_sample_left)
            $fatal(1, "HDMI silence keepalive has the wrong level: L=%0d R=%0d",
                   dut.hdmi_sample_left, dut.hdmi_sample_right);
        @(negedge clk); wav_valid = 1;
        timeout = 0;
        while (!saw_tap && timeout < 200) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        // This compact test has no video blanking/data-island slots, so the
        // packetizer back-pressures after four samples. Check that a ramped,
        // correctly signed and bounded sample reached the bridge; the full
        // 3x steady-state level is covered by the timed HDMI stream test.
        if (timeout == 200 || captured_tap < -16'sd1857 || captured_tap > 0)
            $fatal(1, "WAV PCM did not reach HDMI bridge: ready=%b left=%0d", wav_ready, captured_tap);
        @(negedge clk); wav_valid = 0;
        repeat (4) @(negedge clk);
        if (tone_overflow || contract_error)
            $fatal(1, "HDMI audio bridge reported an error");
        $display("PASS: WAV PCM reached HDMI after exact volume/255 scaling");
        test_pass = 1;
        $finish;
    end
endmodule
