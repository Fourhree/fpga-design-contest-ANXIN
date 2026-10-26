`timescale 1ns/1ps

module tb_audio_source_mux;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg [1:0] mode = 0;
    reg wav_valid = 1, wav_active = 1, arp_valid = 1, out_ready = 1;
    wire wav_ready, arp_ready, out_valid;
    wire signed [15:0] out_left, out_right;
    integer i;
    integer previous;
    reg test_pass = 0;
    audio_source_mux dut (
        .clk(clk), .rst_n(rst_n),
        .wav_valid(wav_valid), .wav_ready(wav_ready),
        .wav_left(16'sd111), .wav_right(-16'sd112), .wav_active(wav_active),
        .arp_valid(arp_valid), .arp_ready(arp_ready),
        .arp_left(16'sd221), .arp_right(-16'sd222),
        .source_mode(mode), .out_valid(out_valid), .out_ready(out_ready),
        .out_left(out_left), .out_right(out_right)
    );
    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1;

        // The first valid WAV sample is passed at full level; startup must not
        // fade the beginning of speech into silence.
        wait (dut.wav_path_active);
        @(negedge clk);
        if (!out_valid || !wav_ready || arp_ready || out_left != 111 || out_right != -112)
            $fatal(1, "WAV startup sample was not passed cleanly: valid=%b ready=%b arp=%b left=%0d right=%0d ramp=%0d",
                   out_valid, wav_ready, arp_ready, out_left, out_right, dut.wav_ramp);
        repeat (35) @(negedge clk);
        if (out_left != 111 || out_right != -112)
            $fatal(1, "WAV did not reach full level");

        // wav_active is only a stream-level indication. Between 48 kHz WAV
        // samples wav_valid is low, so no PCM sample may be invented at the
        // much faster pixel-clock rate.
        wav_valid = 0;
        @(negedge clk);
        if (out_valid || !wav_ready || !arp_ready)
            $fatal(1, "WAV valid gap generated an extra PCM sample");
        wav_valid = 1;
        @(negedge clk);
        if (!out_valid || !wav_ready || arp_ready)
            $fatal(1, "WAV did not resume after valid gap");

        // A source transition during backpressure must not change the held
        // PCM word before the downstream consumer accepts it.
        out_ready = 0;
        wav_active = 0;
        repeat (4) begin
            @(negedge clk);
            if (!out_valid || out_left != 111 || out_right != -112)
                $fatal(1, "source changed while PCM was backpressured");
        end
        out_ready = 1;
        @(negedge clk);

        mode = 1; @(negedge clk);
        if (!out_valid || wav_ready || !arp_ready || out_left != 221 || out_right != -222)
            $fatal(1, "test-tone selection failed");

        // Automatic slideshow transitions may briefly deassert wav_active
        // while the next group's file is selected. The held WAV sample must
        // fade monotonically to zero while the HDMI cadence stays active.
        mode = 0; wav_active = 0;
        previous = 32767;
        repeat (36) begin
            @(negedge clk);
            if (!out_valid || wav_ready || !arp_ready || out_left > previous ||
                out_left < 0 || out_left > 111)
                $fatal(1, "automatic switch fade-out discontinuity: previous=%0d current=%0d",
                       previous, out_left);
            previous = out_left;
        end
        if (out_left != 0 || out_right != 0)
            $fatal(1, "automatic switch did not settle at silence");

        arp_valid = 0; @(negedge clk);
        if (out_valid || !arp_ready)
            $fatal(1, "silence cadence ignored pacing source valid");
        arp_valid = 1; wav_active = 1;
        wait (dut.wav_path_active);
        previous = -32768;
        repeat (36) begin
            @(negedge clk);
            if (!out_valid || !wav_ready || arp_ready || out_left < previous ||
                out_left < 0 || out_left > 111)
                $fatal(1, "WAV resume discontinuity: previous=%0d current=%0d",
                       previous, out_left);
            previous = out_left;
        end
        if (out_left != 111 || out_right != -112)
            $fatal(1, "WAV did not resume at full level");
        $display("PASS: WAV, test-tone and silence source modes");
        test_pass = 1;
        $finish;
    end
endmodule
