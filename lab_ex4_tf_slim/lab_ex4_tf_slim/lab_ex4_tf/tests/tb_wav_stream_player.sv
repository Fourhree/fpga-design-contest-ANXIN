`timescale 1ns/1ps

module tb_wav_stream_player;
    reg wr_clk = 0, rd_clk = 0, wr_rst_n = 0, rd_rst_n = 0;
    always #5 wr_clk = ~wr_clk;
    always #20 rd_clk = ~rd_clk;
    reg play_enable = 0, sample_tick = 0;
    wire sd_req, sd_busy, sd_valid, sd_done;
    wire [31:0] sd_lba;
    wire [7:0] sd_byte, sd_error;
    wire [8:0] sd_byte_index;
    wire signed [15:0] sample_left, sample_right;
    wire sample_valid, stream_active, stream_end, buffer_low;
    wire [31:0] sample_counter;
    wire [7:0] format_error;
    reg busy = 0, valid = 0, done = 0;
    reg [7:0] byte_value = 0;
    reg [8:0] byte_index = 0;
    integer i, sample_seen = 0;
    reg test_pass = 0;
    assign sd_busy = busy;
    assign sd_valid = valid;
    assign sd_done = done;
    assign sd_byte = byte_value;
    assign sd_byte_index = byte_index;
    assign sd_error = 0;

    function [7:0] wav_byte;
        input integer offset;
        begin
            case (offset)
                0: wav_byte="R"; 1: wav_byte="I"; 2,3: wav_byte="F";
                4: wav_byte=8'd44;
                8: wav_byte="W"; 9: wav_byte="A"; 10: wav_byte="V"; 11: wav_byte="E";
                12: wav_byte="f"; 13: wav_byte="m"; 14: wav_byte="t"; 15: wav_byte=" ";
                16: wav_byte=16; 20: wav_byte=1; 22: wav_byte=2;
                24: wav_byte=8'h80; 25: wav_byte=8'hbb;
                29: wav_byte=8'hee; 30: wav_byte=2; 32: wav_byte=4; 34: wav_byte=16;
                36: wav_byte="d"; 37: wav_byte="a"; 38: wav_byte="t"; 39: wav_byte="a";
                40: wav_byte=8;
                44: wav_byte=8'h34; 45: wav_byte=8'h12;
                46: wav_byte=8'hcc; 47: wav_byte=8'hed;
                48: wav_byte=8'hfe; 49: wav_byte=8'hff;
                50: wav_byte=8'h02; 51: wav_byte=8'h00;
                default: wav_byte = 0;
            endcase
        end
    endfunction

    wav_stream_player #(
        .ADDR_WIDTH(9),
        .STARTUP_PREFILL_WORDS(2),
        .STARTUP_PREROLL_SAMPLES(2)
    ) dut (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n), .play_enable(play_enable),
        .start_lba(32'd20), .total_sectors(32'd1),
        .first_cluster(32'd2), .file_size(32'd52), .sectors_per_cluster(8'd1),
        .fat_start_lba(32'd10), .data_start_lba(32'd20), .max_cluster(32'd100),
        .sd_req(sd_req), .sd_lba(sd_lba), .sd_busy(sd_busy), .sd_valid(sd_valid),
        .sd_byte(sd_byte), .sd_byte_index(sd_byte_index), .sd_done(sd_done),
        .sd_error(sd_error), .rd_clk(rd_clk), .rd_rst_n(rd_rst_n),
        .sample_tick(sample_tick), .sample_out(sample_left), .sample_right(sample_right),
        .sample_valid(sample_valid), .sample_ready(1'b1),
        .sample_counter(sample_counter), .stream_active(stream_active),
        .stream_end(stream_end), .buffer_low(buffer_low), .format_error(format_error)
    );

    initial forever begin
        @(posedge wr_clk);
        if (sd_req && !busy) begin
            busy = 1;
            for (i=0; i<512; i=i+1) begin
                @(negedge wr_clk);
                byte_index = i;
                if (sd_lba == 20)
                    byte_value = wav_byte(i);
                else if (sd_lba == 10 && i == 8)
                    byte_value = 8'hf8;
                else if (sd_lba == 10 && (i == 9 || i == 10 || i == 11))
                    byte_value = 8'hff;
                else
                    byte_value = 0;
                valid = 1;
                @(negedge wr_clk); valid = 0;
            end
            @(negedge wr_clk); done = 1;
            @(negedge wr_clk); done = 0; busy = 0;
        end
    end

    always @(posedge rd_clk) begin
        if (sample_valid) begin
            if (sample_seen < 2 && (sample_left !== 16'sd0 || sample_right !== 16'sd0))
                $fatal(1, "startup preroll was not silent");
            if (sample_seen == 2 && (sample_left !== 16'sh1234 || sample_right !== -16'sh1234))
                $fatal(1, "first stereo sample mismatch: %h %h", sample_left, sample_right);
            if (sample_seen == 3 && (sample_left !== -16'sd2 || sample_right !== 16'sd2))
                $fatal(1, "second stereo sample mismatch: %h %h", sample_left, sample_right);
            sample_seen = sample_seen + 1;
        end
    end

    task tick;
        begin
            @(negedge rd_clk); sample_tick = 1;
            @(negedge rd_clk); sample_tick = 0;
            @(negedge rd_clk);
        end
    endtask

    initial begin
        repeat (4) @(negedge wr_clk);
        wr_rst_n = 1; rd_rst_n = 1; play_enable = 1;
        wait (dut.fifo_wrusedw == 2);
        repeat (5) @(negedge rd_clk);
        tick; tick; tick; tick;
        wait (sample_seen == 4);
        repeat (8) @(negedge rd_clk);
        if (format_error != 0 || sample_counter != 2 ||
            !dut.startup_preroll_complete)
            $fatal(1, "WAV status mismatch: error=%h count=%0d", format_error, sample_counter);
        play_enable = 0;
        repeat (4) @(negedge rd_clk);
        if (!dut.startup_preroll_complete)
            $fatal(1, "one-time startup guard was incorrectly re-armed");
        $display("PASS: WAV parsed and emitted two stereo PCM samples");
        test_pass = 1;
        $finish;
    end
endmodule
