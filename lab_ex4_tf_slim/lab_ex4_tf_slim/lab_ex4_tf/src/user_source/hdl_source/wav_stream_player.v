`timescale 1ns/1ps

// FAT32 WAV -> stereo PCM FIFO. start_lba/total_sectors describe the FILE
// extent, including its header; cluster traversal handles fragmented files.
// Accept PCM format 1, 48 kHz, 16 bits, mono or stereo. Unknown RIFF chunks
// (and their odd-byte padding) are skipped. Data is bounded by the data chunk.
module wav_stream_player #(
    parameter integer ADDR_WIDTH = 10,
    parameter integer SAMPLES_PER_SECTOR = 256,
    parameter integer LOOP_ENABLE = 0,
    parameter integer STARTUP_PREFILL_WORDS = 256,
    parameter integer STARTUP_PREROLL_SAMPLES = 4800
) (
    input wire wr_clk, wr_rst_n, play_enable,
    input wire [31:0] start_lba, total_sectors,
    input wire [31:0] first_cluster, file_size,
    input wire [7:0] sectors_per_cluster,
    input wire [31:0] fat_start_lba, data_start_lba, max_cluster,
    output wire sd_req,
    output wire [31:0] sd_lba,
    input wire sd_busy, sd_valid,
    input wire [7:0] sd_byte,
    input wire [8:0] sd_byte_index,
    input wire sd_done,
    input wire [7:0] sd_error,
    input wire rd_clk, rd_rst_n, sample_tick,
    output reg signed [15:0] sample_out,
    output reg signed [15:0] sample_right,
    output reg sample_valid,
    input wire sample_ready,
    output reg [31:0] sample_counter,
    output wire stream_active, stream_end, buffer_low,
    output reg [7:0] format_error
);
    localparam RIFF=0, CHUNK=1, FMT=2, SKIP=3, DATA=4, FINISHED=5;
    reg [2:0] parser;
    reg [4:0] pos;
    reg [31:0] chunk_id, chunk_size, remaining;
    reg pad_byte, fmt_ok, started, ended;
    reg [15:0] fmt_code, channels, block_align, bits;
    reg [31:0] sample_rate;
    reg [7:0] pcm0, pcm1, pcm2;
    reg [1:0] pcm_pos;
    wire file_valid, file_done;
    wire [7:0] file_byte, fs_error;
    wire [31:0] file_offset;
    wire [31:0] completed_size = {file_byte, chunk_size[23:0]};
    reg play_r1, play_r2, ended_r1, ended_r2;
    reg playback_started;
    reg startup_preroll_complete;
    reg [31:0] startup_preroll_count;
    reg fifo_we, fifo_re;
    reg [31:0] fifo_write_data;
    wire [31:0] fifo_read_data;
    wire fifo_valid, fifo_full, fifo_empty, fifo_afull, fifo_aempty;
    wire [8:0] fifo_wrusedw, fifo_rdusedw;
    wfifo_32_32_512 u_pcm_fifo (
        .rst(!wr_rst_n || !rd_rst_n || !play_enable),
        .clkw(wr_clk), .clkr(rd_clk), .we(fifo_we), .di(fifo_write_data),
        .re(fifo_re), .dout(fifo_read_data), .valid(fifo_valid),
        .full_flag(fifo_full), .empty_flag(fifo_empty),
        .afull(fifo_afull), .aempty(fifo_aempty),
        .wrusedw(fifo_wrusedw), .rdusedw(fifo_rdusedw)
    );
    // Reserve a whole sector before starting it: sector bytes cannot stall.
    wire allow_sector = !ended && fifo_wrusedw <= 9'd255;
    fat32_file_streamer #(.MAX_VISITED_CLUSTERS(1048576)) u_file (
        .clk(wr_clk), .rst_n(wr_rst_n && play_enable),
        .file_start(play_enable && !started && start_lba != 0 && total_sectors != 0),
        .data_enable(allow_sector), .file_ready(1'b1),
        .first_cluster(first_cluster), .file_size(file_size),
        .sectors_per_cluster(sectors_per_cluster), .fat_start_lba(fat_start_lba),
        .data_start_lba(data_start_lba), .max_cluster(max_cluster),
        .file_busy(), .file_done(file_done), .file_valid(file_valid),
        .file_byte(file_byte), .file_byte_offset(file_offset), .file_sector_done(),
        .fs_error(fs_error), .sector_req(sd_req), .sector_lba(sd_lba),
        .sector_busy(sd_busy), .sector_valid(sd_valid), .sector_byte(sd_byte),
        .sector_byte_index(sd_byte_index), .sector_done(sd_done), .sector_error(sd_error)
    );
    task bad_format;
        begin format_error <= 8'h30; ended <= 1; parser <= FINISHED; end
    endtask
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            parser <= RIFF; pos <= 0; chunk_id <= 0; chunk_size <= 0;
            remaining <= 0; pad_byte <= 0; fmt_ok <= 0;
            started <= 0; ended <= 0; format_error <= 0;
            fmt_code <= 0; channels <= 0; block_align <= 0; bits <= 0;
            sample_rate <= 0; pcm_pos <= 0; pcm0 <= 0; pcm1 <= 0; pcm2 <= 0;
            fifo_we <= 0; fifo_write_data <= 0;
        end else begin
            fifo_we <= 0;
            if (!play_enable) begin
                started <= 0; ended <= 0;
                parser <= RIFF; pos <= 0; fmt_ok <= 0; format_error <= 0;
                pcm_pos <= 0; chunk_id <= 0; chunk_size <= 0;
            end else begin
                started <= 1;
                if (file_valid && !ended) begin
                    case (parser)
                        RIFF: begin
                            pos <= pos + 1'b1;
                            case (pos)
                                0: if (file_byte != "R") bad_format;
                                1: if (file_byte != "I") bad_format;
                                2,3: if (file_byte != "F") bad_format;
                                8: if (file_byte != "W") bad_format;
                                9: if (file_byte != "A") bad_format;
                                10: if (file_byte != "V") bad_format;
                                11: if (file_byte != "E") bad_format;
                                    else begin parser <= CHUNK; pos <= 0; end
                                default: begin end
                            endcase
                        end
                        CHUNK: begin
                            pos <= pos + 1'b1;
                            case (pos)
                                0: chunk_id[7:0] <= file_byte;
                                1: chunk_id[15:8] <= file_byte;
                                2: chunk_id[23:16] <= file_byte;
                                3: chunk_id[31:24] <= file_byte;
                                4: chunk_size[7:0] <= file_byte;
                                5: chunk_size[15:8] <= file_byte;
                                6: chunk_size[23:16] <= file_byte;
                                7: begin
                                    chunk_size[31:24] <= file_byte;
                                    remaining <= completed_size;
                                    pad_byte <= completed_size[0]; pos <= 0;
                                    if (completed_size > file_size - file_offset - 1)
                                        bad_format;
                                    else if (chunk_id == 32'h20746d66) begin // fmt
                                        if (completed_size < 16) bad_format;
                                        else parser <= FMT;
                                    end else if (chunk_id == 32'h61746164) begin // data
                                        if (!fmt_ok || completed_size == 0 ||
                                            completed_size[0] || (channels == 2 && completed_size[1]))
                                            bad_format;
                                        else begin parser <= DATA; pcm_pos <= 0; end
                                    end else if (completed_size == 0) parser <= CHUNK;
                                    else parser <= SKIP;
                                end
                                default: begin end
                            endcase
                        end
                        FMT, SKIP: begin
                            if (parser == FMT) begin
                                if (pos < 16) pos <= pos + 1'b1;
                                case (pos)
                                    0: fmt_code[7:0] <= file_byte;
                                    1: fmt_code[15:8] <= file_byte;
                                    2: channels[7:0] <= file_byte;
                                    3: channels[15:8] <= file_byte;
                                    4: sample_rate[7:0] <= file_byte;
                                    5: sample_rate[15:8] <= file_byte;
                                    6: sample_rate[23:16] <= file_byte;
                                    7: sample_rate[31:24] <= file_byte;
                                    12: block_align[7:0] <= file_byte;
                                    13: block_align[15:8] <= file_byte;
                                    14: bits[7:0] <= file_byte;
                                    15: begin
                                        bits[15:8] <= file_byte;
                                        fmt_ok <= fmt_code == 1 && (channels == 1 || channels == 2) &&
                                                  sample_rate == 48000 && {file_byte,bits[7:0]} == 16 &&
                                                  block_align == (channels == 1 ? 2 : 4);
                                    end
                                    default: begin end
                                endcase
                            end
                            if (remaining > 1) remaining <= remaining - 1'b1;
                            else if (remaining == 1 && pad_byte) begin
                                remaining <= 0; parser <= SKIP;
                            end else begin parser <= CHUNK; pos <= 0; end
                        end
                        DATA: begin
                            remaining <= remaining - 1'b1;
                            pcm_pos <= pcm_pos + 1'b1;
                            case (pcm_pos)
                                0: pcm0 <= file_byte;
                                1: begin
                                    pcm1 <= file_byte;
                                    if (channels == 1) begin
                                        fifo_write_data <= {file_byte,pcm0,file_byte,pcm0};
                                        fifo_we <= 1;
                                        pcm_pos <= 0;
                                    end
                                end
                                2: pcm2 <= file_byte;
                                3: begin
                                    fifo_write_data <= {file_byte,pcm2,pcm1,pcm0};
                                    fifo_we <= 1;
                                end
                            endcase
                            if (remaining == 1) begin parser <= FINISHED; ended <= 1; end
                        end
                        default: begin end
                    endcase
                end
                if (file_done) begin
                    if (LOOP_ENABLE && ended && format_error == 0 && fs_error == 0) begin
                        // Re-arm the parser and file streamer while queued PCM
                        // still drains, keeping the loop boundary continuous.
                        started <= 0;
                        ended <= 0;
                        parser <= RIFF;
                        pos <= 0;
                        chunk_id <= 0;
                        chunk_size <= 0;
                        remaining <= 0;
                        pad_byte <= 0;
                        fmt_ok <= 0;
                        fmt_code <= 0;
                        channels <= 0;
                        block_align <= 0;
                        bits <= 0;
                        sample_rate <= 0;
                        pcm_pos <= 0;
                    end else if (fs_error != 0) begin
                        ended <= 1;
                        format_error <= fs_error;
                    end else if (!ended) begin
                        ended <= 1;
                        format_error <= 8'h31;
                    end
                end
                if (sd_done && sd_error != 0) begin
                    ended <= 1; format_error <= sd_error;
                end
            end
        end
    end
    assign stream_end = play_r2 && ended_r2 && fifo_empty;
    // Do not expose the stream until a useful amount of PCM is queued.  This
    // removes the initial empty-FIFO interval and gives the SD reader enough
    // margin to avoid an audible start-up discontinuity.
    assign stream_active = play_r2 && playback_started && !stream_end;
    assign buffer_low = fifo_rdusedw < 9'd128;
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            play_r1 <= 0; play_r2 <= 0; ended_r1 <= 0; ended_r2 <= 0;
            playback_started <= 0;
            startup_preroll_complete <= 0;
            startup_preroll_count <= 0;
            sample_valid <= 0; sample_out <= 0; sample_right <= 0; sample_counter <= 0;
            fifo_re <= 0;
        end else begin
            play_r1 <= play_enable; play_r2 <= play_r1;
            ended_r1 <= ended; ended_r2 <= ended_r1;
            fifo_re <= 0;
            if (sample_valid && sample_ready) sample_valid <= 0;
            if (!play_r2) begin
                playback_started <= 0;
                startup_preroll_count <= 0;
                sample_counter <= 0; sample_valid <= 0;
            end else if (!playback_started) begin
                sample_valid <= 0;
                startup_preroll_count <= 0;
                if (fifo_rdusedw >= STARTUP_PREFILL_WORDS)
                    playback_started <= 1;
            end else if (sample_tick && (!sample_valid || sample_ready)) begin
                sample_valid <= 1;
                if (!startup_preroll_complete &&
                    startup_preroll_count < STARTUP_PREROLL_SAMPLES) begin
                    // Send valid silence once after power-up so the HDMI sink
                    // locks before speech. The PCM FIFO is not read, so sample
                    // zero remains the first real sample delivered afterward.
                    sample_out <= 0;
                    sample_right <= 0;
                    startup_preroll_count <= startup_preroll_count + 1'b1;
                    if (startup_preroll_count + 1'b1 >= STARTUP_PREROLL_SAMPLES)
                        startup_preroll_complete <= 1'b1;
                end else if (!startup_preroll_complete) begin
                    startup_preroll_complete <= 1'b1;
                end else if (fifo_valid) begin
                    {sample_right,sample_out} <= fifo_read_data;
                    fifo_re <= 1;
                    sample_counter <= sample_counter + 1'b1;
                end else begin sample_out <= 0; sample_right <= 0; end
            end
        end
    end
endmodule
