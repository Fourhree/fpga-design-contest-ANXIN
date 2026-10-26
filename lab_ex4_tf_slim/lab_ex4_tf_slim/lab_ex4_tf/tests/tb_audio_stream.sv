`timescale 1ns/1ps

module tb_audio_stream;
    reg clk = 0;
    always #20 clk = ~clk;
    reg rst_n = 0;
    wire [9:0] x;
    reg [1:0] media_id = 0;
    wire de, hs, vs, line_active;
    wire de0, hs0, vs0, line_active0;
    video_timing_data timing (
        .video_clk(clk), .rst(~rst_n), .read_req(), .read_req_ack(1'b1),
        .hs(hs0), .vs(vs0), .de(de0), .line_active(line_active0)
    );
    video_delay delay (
        .video_clk(clk), .rst(~rst_n), .read_en(), .read_data(24'h204080),
        .hs(hs0), .vs(vs0), .de(de0), .line_active(line_active0),
        .hs_r(hs), .vs_r(vs), .de_r(de), .line_active_r(line_active), .vout_data()
    );
    hdmi_video_position position (
        .clk(clk), .rst_n(rst_n), .hsync(hs), .de(de), .x(x)
    );
    wire sequence_error, overflow, contract_error;
    wire pcm_valid;
    wire signed [15:0] pcm_left;
    integer sample_count = 0;
    integer nonzero_count = 0;
    integer audio_packets = 0;
    integer acr_packets = 0;
    integer samples_before;
    integer packets_before;
    integer note_before;
    integer video_starts = 0, guards = 0, blank_packets = 0;
    reg [2:0] last_mode = 0;
    reg test_pass = 0;

    media_hdmi_audio_bridge dut (
        .pixel_clk(clk), .pixel_rst_n(rst_n),
        .video_hsync(hs), .video_vsync(vs), .video_de(de),
        .video_line_active(line_active),
        .video_x(x), .video_rgb(24'h204080),
        .media_id(media_id), .volume(8'd192), .fade_gain(8'd255),
        .audio_source_mode(2'd1), .wav_active(1'b0), .wav_valid(1'b0), .wav_ready(),
        .wav_left(16'sd0), .wav_right(16'sd0),
        .clock_symbol(), .ddc_scl(), .ddc_sda(),
        .channel0_symbol(), .channel1_symbol(), .channel2_symbol(),
        .sequence_error(sequence_error), .tone_overflow(overflow),
        .pcm_contract_error(contract_error), .blip_active(),
        .pcm_tap_valid(pcm_valid), .pcm_tap_left(pcm_left)
    );
    // Use the board video pipeline and default note/cue lengths.

    always @(posedge clk) begin
        if (!rst_n) begin
            last_mode <= 0;
        end else begin
            last_mode <= dut.u_symbol_core.mode;
            if (dut.u_symbol_core.mode == 2) guards = guards + 1;
            if (dut.u_symbol_core.mode == 1 && last_mode != 1) begin
                if (last_mode != 2) $fatal(1, "active video missing leading guards");
                video_starts = video_starts + 1;
            end
            if (!line_active && (dut.u_symbol_core.video_preamble || dut.u_symbol_core.mode == 2))
                $fatal(1, "video preamble/guard emitted in vertical blanking");
            if (pcm_valid) begin
                sample_count = sample_count + 1;
                if (pcm_left != 0) nonzero_count = nonzero_count + 1;
            end
            if (dut.u_symbol_core.packet_ready) begin
                case (dut.u_symbol_core.packet_header[7:0])
                    8'h02: audio_packets = audio_packets + 1;
                    8'h01: begin
                        acr_packets = acr_packets + 1;
                        if (dut.u_symbol_core.packet_body[55:0] !== 56'h001800a8610000)
                            $fatal(1, "invalid ACR reached HDMI scheduler");
                    end
                endcase
                if (!line_active) blank_packets = blank_packets + 1;
            end
            if (sequence_error || overflow || contract_error)
                $fatal(1, "audio stream error: sequence=%b overflow=%b contract=%b",
                       sequence_error, overflow, contract_error);
        end
    end

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (420000 * 16) @(negedge clk);
        samples_before = sample_count;
        packets_before = audio_packets;
        note_before = dut.u_tone.note_index;
        media_id = 1;
        repeat (420000 * 9) @(negedge clk);
        if (sample_count - samples_before < 1500 || audio_packets - packets_before < 375)
            $fatal(1, "audio stopped after media switch");
        if (acr_packets < 60 || nonzero_count < 2500 || dut.u_tone.blip_countdown != 0)
            $fatal(1, "audio clock or melody did not continue");
        if (note_before == 0 || blank_packets == 0 || video_starts == 0 || guards != video_starts * 2)
            $fatal(1, "board timing, video guards, blanking audio or default melody progression failed");
        $display("PASS: sustained HDMI audio: %0d PCM samples, %0d audio packets, %0d ACR packets",
                 sample_count, audio_packets, acr_packets);
        test_pass = 1;
        $finish;
    end
endmodule
