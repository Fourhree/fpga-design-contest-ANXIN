`timescale 1ns/1ps

// Valid/ready source arbiter. A source is held once selected until its
// current sample is accepted, so a stalled consumer cannot see a mid-sample
// source change. Source 1 is reserved for a future WAV reader.
module pcm_source_mux (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    source_select,
    input  wire                    tone_valid,
    output wire                    tone_ready,
    input  wire signed [15:0]      tone_left,
    input  wire signed [15:0]      tone_right,
    input  wire                    wav_valid,
    output wire                    wav_ready,
    input  wire signed [15:0]      wav_left,
    input  wire signed [15:0]      wav_right,
    output wire                    pcm_valid,
    input  wire                    pcm_ready,
    output wire signed [15:0]      pcm_left,
    output wire signed [15:0]      pcm_right,
    output reg                     source_error
);
    reg       locked;
    reg       locked_source;
    wire      selected_source = locked ? locked_source :
                                (source_select && wav_valid) ? 1'b1 :
                                tone_valid ? 1'b0 : 1'b1;
    wire      selected_valid = (selected_source == 1'b0) ? tone_valid : wav_valid;
    wire      transfer = pcm_valid && pcm_ready;

    assign pcm_valid = selected_valid;
    assign pcm_left = (selected_source == 1'b0) ? tone_left : wav_left;
    assign pcm_right = (selected_source == 1'b0) ? tone_right : wav_right;
    assign tone_ready = pcm_ready && pcm_valid && (selected_source == 1'b0);
    assign wav_ready = pcm_ready && pcm_valid && (selected_source == 1'b1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            locked <= 1'b0;
            locked_source <= 1'b0;
            source_error <= 1'b0;
        end else if (locked) begin
            if (transfer || !selected_valid)
                locked <= 1'b0;
        end else if (tone_valid || wav_valid) begin
            if (!pcm_ready) begin
                locked <= 1'b1;
                locked_source <= selected_source;
            end
        end
    end
endmodule
