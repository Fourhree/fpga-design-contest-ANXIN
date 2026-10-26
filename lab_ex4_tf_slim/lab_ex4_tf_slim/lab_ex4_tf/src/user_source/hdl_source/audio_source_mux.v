`timescale 1ns/1ps

// R3'-A3: audio source selector. Both sources share the same sample_valid /
// sample_ready / sample_left / sample_right interface; the mux is purely
// combinational on the valid/data paths. The tone source is also consumed as
// a 48 kHz cadence while silence is selected, keeping HDMI audio continuous.
// WAV loss/recovery uses a short ramp so switching cannot create a full-scale
// discontinuity (an audible click).
module audio_source_mux (
    input  wire               clk,
    input  wire               rst_n,

    // source A: WAV stream
    input  wire               wav_valid,
    output wire               wav_ready,
    input  wire signed [15:0] wav_left,
    input  wire signed [15:0] wav_right,
    input  wire               wav_active,     // stream playing (level)

    // source B: arpeggio synth (existing pcm_media_tone)
    input  wire               arp_valid,
    output wire               arp_ready,
    input  wire signed [15:0] arp_left,
    input  wire signed [15:0] arp_right,

    // 0: WAV only; 1: test tone; 2/3: silence.
    input  wire [1:0]         source_mode,

    // output to m06_pcm_contract_adapter
    output wire               out_valid,
    input  wire               out_ready,
    output wire signed [15:0] out_left,
    output wire signed [15:0] out_right
);
    localparam [5:0] RAMP_MAX = 6'd32;

    reg [5:0] wav_ramp;
    reg signed [15:0] last_wav_left;
    reg signed [15:0] last_wav_right;
    reg wav_path_active;

    wire wav_requested = source_mode == 2'd0 && wav_active;
    wire wav_selected = wav_path_active;
    wire use_tone = source_mode == 2'd1;
    // Keep a paced PCM stream alive while WAV changes files or refills its
    // FIFO.  Dropping valid here makes the HDMI sink lose audio lock, which
    // can swallow the first samples after an automatic image-group switch.
    // The tone source supplies the common 48 kHz cadence in silence modes.
    wire output_fire = out_valid && out_ready;

    // Eight gain steps spread over 32 samples (about 0.67 ms at 48 kHz).
    // Shift/add scaling avoids adding multipliers to the already dense design.
    function signed [15:0] ramp_sample;
        input signed [15:0] sample;
        input [5:0] ramp;
        reg signed [16:0] half;
        reg signed [16:0] quarter;
        reg signed [16:0] eighth;
        begin
            half = sample >>> 1;
            quarter = sample >>> 2;
            eighth = sample >>> 3;
            case (ramp[5:2])
                4'd0: ramp_sample = 16'sd0;
                4'd1: ramp_sample = eighth[15:0];
                4'd2: ramp_sample = quarter[15:0];
                4'd3: ramp_sample = (quarter + eighth);
                4'd4: ramp_sample = half[15:0];
                4'd5: ramp_sample = (half + eighth);
                4'd6: ramp_sample = (half + quarter);
                4'd7: ramp_sample = (half + quarter + eighth);
                default: ramp_sample = sample;
            endcase
        end
    endfunction

    assign out_valid = wav_selected ? wav_valid : arp_valid;
    assign out_left  = (wav_selected && wav_valid) ? ramp_sample(wav_left, wav_ramp) :
                       use_tone ? arp_left : ramp_sample(last_wav_left, wav_ramp);
    assign out_right = (wav_selected && wav_valid) ? ramp_sample(wav_right, wav_ramp) :
                       use_tone ? arp_right : ramp_sample(last_wav_right, wav_ramp);

    assign wav_ready = wav_selected ? out_ready : 1'b0;
    // Drain the unused cadence FIFO during WAV playback. Otherwise it fills
    // immediately, asserts overflow and can emit stale tone samples later.
    assign arp_ready = (use_tone || !wav_selected || !wav_valid) ? out_ready : 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Start at unity gain so the first spoken sample is not hidden
            // by a power-on fade. Only a real source interruption fades out.
            wav_ramp <= RAMP_MAX;
            last_wav_left <= 16'sd0;
            last_wav_right <= 16'sd0;
            wav_path_active <= 1'b0;
        end else begin
            // Switch only between accepted samples. The WAV elastic FIFO
            // holds its first sample until this path is ready, so no content
            // is consumed while a stalled HDMI packet is being completed.
            if (!out_valid || out_ready)
                wav_path_active <= wav_requested;

            if (output_fire) begin
                if (wav_selected && wav_valid) begin
                    last_wav_left <= wav_left;
                    last_wav_right <= wav_right;
                    if (wav_ramp < RAMP_MAX)
                        wav_ramp <= wav_ramp + 1'b1;
                end else if (!use_tone && !wav_requested && wav_ramp != 0) begin
                    wav_ramp <= wav_ramp - 1'b1;
                end
            end
        end
    end
endmodule
