`timescale 1ns/1ps

// Player-owned boundary between registered video and the self-contained HDMI
// data-island/audio symbol chain. The EG4 DDR PHY remains in the board Top.
module media_hdmi_audio_bridge (
    input  wire        pixel_clk,
    input  wire        pixel_rst_n,
    input  wire        video_hsync,
    input  wire        video_vsync,
    input  wire        video_de,
    input  wire        video_line_active,
    input  wire [9:0]  video_x,
    input  wire [23:0] video_rgb,
    input  wire [2:0]  media_id,
    input  wire [7:0]  volume,
    input  wire [7:0]  fade_gain,
    input  wire [1:0]  audio_source_mode,
    input  wire        wav_active,
    input  wire        wav_valid,
    output wire        wav_ready,
    input  wire signed [15:0] wav_left,
    input  wire signed [15:0] wav_right,
    output wire [9:0]  clock_symbol,
    output wire        ddc_scl,
    inout  wire        ddc_sda,
    output wire [9:0]  channel0_symbol,
    output wire [9:0]  channel1_symbol,
    output wire [9:0]  channel2_symbol,
    output wire        sequence_error,
    output wire        tone_overflow,
    output wire        pcm_contract_error,
    output wire        blip_active,
    output wire        pcm_tap_valid,
    output wire signed [15:0] pcm_tap_left
);
    wire tone_valid;
    wire tone_ready;
    wire signed [15:0] tone_left;
    wire signed [15:0] tone_right;
    wire wav_buffered_valid;
    wire wav_buffered_ready;
    wire signed [15:0] wav_buffered_left;
    wire signed [15:0] wav_buffered_right;
    wire source_valid;
    wire signed [15:0] source_left;
    wire signed [15:0] source_right;
    wire signed [15:0] gained_left;
    wire signed [15:0] gained_right;
    wire gain_in_ready;
    wire gained_valid;
    wire gained_ready;
    wire sample_valid;
    wire sample_ready;
    wire signed [15:0] sample_left;
    wire signed [15:0] sample_right;
    reg keepalive_phase;
    wire pcm_is_digital_silence = (sample_left == 16'sd0) &&
                                  (sample_right == 16'sd0);
    // Some HDMI sinks keep their analogue output muted while PCM is exactly
    // zero, then lose the start of speech while waking.  A post-gain 1-LSB
    // Nyquist pilot keeps that path awake without changing audible content.
    wire signed [15:0] hdmi_sample_left = pcm_is_digital_silence ?
        (keepalive_phase ? 16'sd1 : -16'sd1) : sample_left;
    wire signed [15:0] hdmi_sample_right = pcm_is_digital_silence ?
        (keepalive_phase ? -16'sd1 : 16'sd1) : sample_right;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n)
            keepalive_phase <= 1'b0;
        else if (sample_valid && sample_ready)
            keepalive_phase <= ~keepalive_phase;
    end

    reg video_hsync_q;
    reg video_vsync_q;
    reg video_de_q;
    reg video_line_active_q;
    reg [9:0] video_x_q;
    reg [23:0] video_rgb_q;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            video_hsync_q <= 1'b1;
            video_vsync_q <= 1'b1;
            video_de_q <= 1'b0;
            video_line_active_q <= 1'b0;
            video_x_q <= 10'd0;
            video_rgb_q <= 24'h000000;
        end else begin
            video_hsync_q <= video_hsync;
            video_vsync_q <= video_vsync;
            video_de_q <= video_de;
            video_line_active_q <= video_line_active;
            video_x_q <= video_x;
            video_rgb_q <= video_de ? video_rgb : 24'h000000;
        end
    end

    pcm_media_tone #(.FIXED_FULL_SCALE_VOLUME(1)) u_tone (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .media_id(media_id), .volume(8'd255),
        .sample_valid(tone_valid), .sample_ready(tone_ready),
        .sample_left(tone_left), .sample_right(tone_right),
        .overflow(tone_overflow), .blip_active(blip_active)
    );

    // HDMI packets can briefly back-pressure the PCM path while waiting for
    // a data-island slot. Buffer WAV samples here so those stalls never reach
    // the fixed 48 kHz file-reader cadence.
    pcm_elastic_fifo #(.ADDR_WIDTH(5)) u_wav_elastic_fifo (
        .clk(pixel_clk), .rst_n(pixel_rst_n), .clear(!wav_active),
        .in_valid(wav_valid), .in_ready(wav_ready),
        .in_left(wav_left), .in_right(wav_right),
        .out_valid(wav_buffered_valid), .out_ready(wav_buffered_ready),
        .out_left(wav_buffered_left), .out_right(wav_buffered_right)
    );

    audio_source_mux u_source_mux (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .wav_valid(wav_buffered_valid), .wav_ready(wav_buffered_ready),
        .wav_left(wav_buffered_left), .wav_right(wav_buffered_right),
        .wav_active(wav_active),
        .arp_valid(tone_valid), .arp_ready(tone_ready),
        .arp_left(tone_left), .arp_right(tone_right),
        .source_mode(audio_source_mode),
        .out_valid(source_valid), .out_ready(gain_in_ready),
        .out_left(source_left), .out_right(source_right)
    );

    pcm_gain_scale u_pcm_gain (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .in_valid(source_valid), .in_ready(gain_in_ready),
        .pcm_left_in(source_left), .pcm_right_in(source_right),
        .boost_3x(audio_source_mode == 2'd0 && media_id != 3'd5),
        .boost_8x(audio_source_mode == 2'd0 && media_id == 3'd5),
        .volume(volume), .fade_gain(fade_gain),
        .out_valid(gained_valid), .out_ready(gained_ready),
        .pcm_left_out(gained_left), .pcm_right_out(gained_right)
    );

    m06_pcm_contract_adapter u_m06_pcm_contract (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .source_valid(gained_valid), .source_ready(gained_ready),
        .source_left(gained_left), .source_right(gained_right),
        .pcm_valid(sample_valid), .pcm_ready(sample_ready),
        .pcm_left(sample_left), .pcm_right(sample_right),
        .contract_error(pcm_contract_error)
    );

    wire audio_valid = sample_valid && sample_ready;
    wire signed [15:0] pcm_probe;

    // DDC/EDID is not needed for fixed 640x480 output; keep the connector idle.
    assign ddc_scl = 1'b1;
    assign ddc_sda = 1'bz;
    assign clock_symbol = 10'b1111100000;
    assign pcm_tap_valid = audio_valid;
    assign pcm_tap_left = pcm_probe;
    assign pcm_probe = sample_left;

    hdmi_audio_symbol_core #(
        .ACR_INTERVAL_CYCLES(25000)
    ) u_symbol_core (
        .pixel_clk(pixel_clk), .rst_n(pixel_rst_n),
        .video_hsync(video_hsync_q), .video_vsync(video_vsync_q),
        .video_de(video_de_q), .video_x(video_x_q), .video_rgb(video_rgb_q),
        .video_line_active(video_line_active_q),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_left(hdmi_sample_left), .sample_right(hdmi_sample_right),
        .channel0_symbol(channel0_symbol),
        .channel1_symbol(channel1_symbol),
        .channel2_symbol(channel2_symbol),
        .sequence_error(sequence_error)
    );

endmodule


// Small same-clock elastic FIFO. DEPTH is 2**ADDR_WIDTH and is intentionally
// much larger than the few samples of worst-case HDMI packet-scheduling delay.
module pcm_elastic_fifo #(
    parameter integer ADDR_WIDTH = 5
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               clear,
    input  wire               in_valid,
    output wire               in_ready,
    input  wire signed [15:0] in_left,
    input  wire signed [15:0] in_right,
    output wire               out_valid,
    input  wire               out_ready,
    output wire signed [15:0] out_left,
    output wire signed [15:0] out_right
);
    localparam integer DEPTH = 1 << ADDR_WIDTH;

    reg [31:0] sample_mem [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] write_ptr;
    reg [ADDR_WIDTH-1:0] read_ptr;
    reg [ADDR_WIDTH:0] sample_count;

    wire push = in_valid && in_ready;
    wire pop = out_valid && out_ready;

    assign in_ready = !clear && sample_count < DEPTH;
    assign out_valid = !clear && sample_count != 0;
    assign {out_right, out_left} = sample_mem[read_ptr];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_ptr <= 0;
            read_ptr <= 0;
            sample_count <= 0;
        end else if (clear) begin
            write_ptr <= 0;
            read_ptr <= 0;
            sample_count <= 0;
        end else begin
            if (push) begin
                sample_mem[write_ptr] <= {in_right, in_left};
                write_ptr <= write_ptr + 1'b1;
            end
            if (pop)
                read_ptr <= read_ptr + 1'b1;

            case ({push, pop})
                2'b10: sample_count <= sample_count + 1'b1;
                2'b01: sample_count <= sample_count - 1'b1;
                default: sample_count <= sample_count;
            endcase
        end
    end
endmodule

// For 640x480, negative HSYNC starts at active x=656, line length=800.
module hdmi_video_position (
    input wire clk,
    input wire rst_n,
    input wire hsync,
    input wire de,
    output wire [9:0] x
);
    reg hs_q, de_q;
    reg [9:0] x_count;
    assign x = (de && !de_q) ? 10'd0 :
               (hs_q && !hsync) ? 10'd656 : x_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs_q <= 1'b0;
            de_q <= 1'b0;
            x_count <= 10'd0;
        end else begin
            hs_q <= hsync;
            de_q <= de;
            x_count <= x == 10'd799 ? 10'd0 : x + 1'b1;
        end
    end
endmodule
