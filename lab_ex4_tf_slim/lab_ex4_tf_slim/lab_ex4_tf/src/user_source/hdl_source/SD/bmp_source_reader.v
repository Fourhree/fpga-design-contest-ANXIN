// Select FAT32 files when a valid volume is present. Old raw-sector cards
// retain the original scanner/loader and its pause-after-discovery behavior.
module bmp_source_reader #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer PAUSE_ON_FOUND = 1
)(
    input clk, rst, catalog_rst,
    output ready,
    input scan_start, scan_resume,
    output scan_paused,
    input [31:0] scan_start_sector, scan_max_sector,
    input [2:0] scan_target_count,
    output scan_done, scan_found_valid,
    output [31:0] scan_found_cluster, scan_found_size,
    output [2:0] scan_found_total,
    input load_start, load_abort,
    input [31:0] load_cluster, load_file_size,
    output [2:0] bmp_error,
    output load_error,
    input sd_init_done,
    output [3:0] state_code,
    input [15:0] bmp_width, bmp_height,
    output write_req,
    input write_req_ack,
    output sd_sec_read,
    output [31:0] sd_sec_read_addr,
    input [7:0] sd_sec_read_data,
    input sd_sec_read_data_valid, sd_sec_read_end, sd_sec_read_error,
    output bmp_data_wr_en,
    output [23:0] bmp_data
);
localparam IDLE=3'd0, PROBE=3'd1, EMIT=3'd2, RAW_START=3'd3;
reg [2:0] state;
// Volume geometry survives the player's local SD recovery reset, like its
// image catalog; transaction engines still reset immediately on rst.
reg fat_mode;
reg [7:0] spc_saved;
reg [31:0] fat_saved, data_saved, max_saved;
wire [7:0] spc;
wire [31:0] fat_lba, data_lba, max_cluster;
wire scanner_done;
wire [7:0] scan_error;
wire [5:0] resource_valid;
wire [31:0] c0,c1,c2,c3,c4,c5,s0,s1,s2,s3,s4,s5;
reg [2:0] emit_idx, emit_count;
reg fat_found, fat_done;
reg [31:0] found_cluster, found_size;
reg scan_io_error;
wire scan_req, stream_req;
wire [31:0] scan_lba, stream_lba;
wire sector_busy, sector_valid, sector_done;
wire [7:0] sector_byte, sector_error;
wire [8:0] sector_byte_index;
wire fat_sd_read;
wire [31:0] fat_sd_addr;
wire raw_ready, raw_done, raw_found, raw_paused;
wire [31:0] raw_sector, raw_size;
wire [2:0] raw_total, raw_error;
wire raw_load_error, raw_write_req, raw_pixel_en, raw_sd_read;
wire [23:0] raw_pixel;
wire [31:0] raw_sd_addr;
wire [3:0] raw_state;
wire fat_ready, fat_load_error, fat_write_req, fat_pixel_en;
wire [2:0] fat_error;
wire [23:0] fat_pixel;
wire raw_active = !fat_mode && state != PROBE && state != EMIT;
wire scanner_active = state == PROBE;

assign ready = state == IDLE && (fat_mode ? fat_ready : raw_ready);
assign scan_paused = raw_active && raw_paused;
assign scan_done = fat_done || (raw_active && raw_done);
assign scan_found_valid = fat_found || (raw_active && raw_found);
assign scan_found_cluster = fat_mode ? found_cluster : raw_sector;
assign scan_found_size = fat_mode ? found_size : raw_size;
assign scan_found_total = fat_mode ? emit_count : raw_total;
assign bmp_error = scan_io_error ? 3'd2 : (fat_mode ? fat_error : raw_error);
assign load_error = scan_io_error || (fat_mode ? fat_load_error : (raw_active && raw_load_error));
assign write_req = fat_mode ? fat_write_req : raw_write_req;
assign bmp_data_wr_en = fat_mode ? fat_pixel_en : raw_pixel_en;
assign bmp_data = fat_mode ? fat_pixel : raw_pixel;
assign state_code = state == PROBE || state == EMIT ? 4'd2 :
                    (fat_mode ? (fat_ready ? 4'd1 : 4'd4) : raw_state);
assign sd_sec_read = scanner_active || fat_mode ? fat_sd_read : raw_sd_read;
assign sd_sec_read_addr = scanner_active || fat_mode ? fat_sd_addr : raw_sd_addr;

always @(posedge clk or posedge catalog_rst) begin
    if (catalog_rst) begin
        fat_mode <= 0;
        spc_saved <= 0; fat_saved <= 0; data_saved <= 0; max_saved <= 0;
    end else if (scanner_active && scanner_done) begin
        fat_mode <= scan_error == 0 || scan_error == 8'h22;
        spc_saved <= spc;
        fat_saved <= fat_lba; data_saved <= data_lba; max_saved <= max_cluster;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= IDLE;
        emit_idx <= 0; emit_count <= 0;
        fat_found <= 0; fat_done <= 0; scan_io_error <= 0;
        found_cluster <= 0; found_size <= 0;
    end else begin
        fat_found <= 0;
        fat_done <= 0;
        scan_io_error <= 0;
        case (state)
            IDLE: if (scan_start && sd_init_done) begin
                state <= PROBE;
                emit_idx <= 0; emit_count <= 0;
            end
            PROBE: if (scanner_done) begin
                if (scan_error == 0 || scan_error == 8'h22)
                    state <= EMIT;
                else if (scan_error == 8'h10) begin
                    scan_io_error <= 1;
                    fat_done <= 1;
                    state <= IDLE;
                end else
                    state <= RAW_START;
            end
            EMIT: begin
                if (emit_idx >= 6 || emit_count >= scan_target_count) begin
                    fat_done <= 1;
                    state <= IDLE;
                end else begin
                    emit_idx <= emit_idx + 1'b1;
                    if (resource_valid[emit_idx]) begin
                        fat_found <= 1;
                        emit_count <= emit_count + 1'b1;
                        case (emit_idx)
                            0: begin found_cluster <= c0; found_size <= s0; end
                            1: begin found_cluster <= c1; found_size <= s1; end
                            2: begin found_cluster <= c2; found_size <= s2; end
                            3: begin found_cluster <= c3; found_size <= s3; end
                            4: begin found_cluster <= c4; found_size <= s4; end
                            default: begin found_cluster <= c5; found_size <= s5; end
                        endcase
                    end
                end
            end
            RAW_START: state <= IDLE;
            default: state <= IDLE;
        endcase
    end
end

fat32_volume_scanner scanner (
    .clk(clk), .rst_n(~rst), .scan_start(scan_start && state == IDLE && sd_init_done),
    .scan_busy(), .scan_done(scanner_done), .fs_error(scan_error), .partition_lba(),
    .sectors_per_cluster(spc), .fat_start_lba(fat_lba), .data_start_lba(data_lba),
    .max_cluster(max_cluster), .resource_valid(resource_valid),
    .resource0_cluster(c0), .resource1_cluster(c1), .resource2_cluster(c2), .resource3_cluster(c3),
    .resource4_cluster(c4), .resource5_cluster(c5),
    .resource0_size(s0), .resource1_size(s1), .resource2_size(s2), .resource3_size(s3),
    .resource4_size(s4), .resource5_size(s5),
    .wav1_valid(), .wav1_cluster(), .wav1_size(),
    .wav_valid(), .wav_cluster(), .wav_size(),
    .wav2_valid(), .wav2_cluster(), .wav2_size(),
    .wav3_valid(), .wav3_cluster(), .wav3_size(),
    .sector_req(scan_req), .sector_lba(scan_lba), .sector_busy(sector_busy),
    .sector_valid(sector_valid && scanner_active), .sector_byte(sector_byte),
    .sector_byte_index(sector_byte_index), .sector_done(sector_done && scanner_active),
    .sector_error(sector_error)
);

bmp_fat_reader #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) fat_reader (
    .clk(clk), .rst(rst), .load_start(load_start && fat_mode && state == IDLE),
    .load_abort(load_abort), .load_cluster(load_cluster), .load_file_size(load_file_size),
    .sectors_per_cluster(spc_saved), .fat_start_lba(fat_saved),
    .data_start_lba(data_saved), .max_cluster(max_saved),
    .bmp_width(bmp_width), .bmp_height(bmp_height), .ready(fat_ready),
    .bmp_error(fat_error), .load_error(fat_load_error), .write_req(fat_write_req),
    .write_req_ack(write_req_ack), .bmp_data_wr_en(fat_pixel_en), .bmp_data(fat_pixel),
    .sector_req(stream_req), .sector_lba(stream_lba), .sector_busy(sector_busy),
    .sector_valid(sector_valid && !scanner_active), .sector_byte(sector_byte),
    .sector_byte_index(sector_byte_index), .sector_done(sector_done && !scanner_active),
    .sector_error(sector_error)
);

sd_sector_adapter #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) adapter (
    .clk(clk), .rst_n(~rst), .sector_req(scanner_active ? scan_req : (fat_mode && stream_req)),
    .sector_lba(scanner_active ? scan_lba : stream_lba), .sector_busy(sector_busy),
    .sector_valid(sector_valid), .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
    .sector_done(sector_done), .sector_error(sector_error), .sd_sec_read(fat_sd_read),
    .sd_sec_read_addr(fat_sd_addr), .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_data(sd_sec_read_data), .sd_sec_read_end(sd_sec_read_end),
    .sd_sec_read_error(sd_sec_read_error)
);

bmp_read #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .PAUSE_ON_FOUND(PAUSE_ON_FOUND)) raw_reader (
    .clk(clk), .rst(rst), .ready(raw_ready), .scan_start(state == RAW_START),
    .scan_resume(scan_resume && raw_active), .scan_paused(raw_paused),
    .scan_start_sector(scan_start_sector), .scan_max_sector(scan_max_sector),
    .scan_target_count(scan_target_count), .scan_done(raw_done),
    .scan_found_valid(raw_found), .scan_found_sector(raw_sector), .scan_found_size(raw_size),
    .scan_found_total(raw_total), .load_start(load_start && raw_active && state == IDLE),
    .load_abort(load_abort), .load_sector(load_cluster),
    .bmp_error(raw_error), .load_error(raw_load_error), .sd_init_done(sd_init_done),
    .state_code(raw_state), .bmp_width(bmp_width), .bmp_height(bmp_height),
    .write_req(raw_write_req), .write_req_ack(write_req_ack),
    .sd_sec_read(raw_sd_read), .sd_sec_read_addr(raw_sd_addr),
    .sd_sec_read_data(sd_sec_read_data), .sd_sec_read_data_valid(sd_sec_read_data_valid && raw_active),
    .sd_sec_read_end(sd_sec_read_end && raw_active), .sd_sec_read_error(sd_sec_read_error),
    .bmp_data_wr_en(raw_pixel_en), .bmp_data(raw_pixel)
);
endmodule
