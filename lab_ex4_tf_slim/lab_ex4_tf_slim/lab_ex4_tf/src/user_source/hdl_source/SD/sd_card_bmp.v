// SD/FAT catalog and BMP source only. Frame storage and display selection
// belong to media_frame_loader and media_player_control.
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter [31:0] SCAN_START_SECTOR = 0,
    parameter [31:0] SCAN_MAX_SECTOR = 131071,
    parameter [2:0] SCAN_TARGET_COUNT = 6,
    parameter integer LONG_PRESS_MS = 1000,
    parameter integer LOAD_TIMEOUT_MS = 5000
)(
    input clk, rst, Sdr_init_done, key_next, key_auto, key_mode,
    input [2:0] audio_file_index,
    input [15:0] bmp_width, bmp_height,
    output key_next_press,
    output reg key_auto_press, key_prev_press,
    output reg key_mode_press,
    output reg [3:0] state_code,
    output reg loader_load_start,
    output reg [2:0] loader_image_index,
    output [15:0] loader_image_width, loader_image_height,
    output loader_image_bottom_up,
    output loader_pixel_valid,
    output [23:0] loader_pixel_rgb,
    output loader_frame_commit,
    output reg [7:0] loader_decode_error,
    input loader_load_done,
    input [7:0] loader_memory_error,
    // Audio takes the existing sector port only after all BMP loads finish.
    output audio_storage_ready,
    output reg wav_file_valid,
    output reg [31:0] wav_first_cluster, wav_file_size, wav_start_lba, wav_total_sectors,
    output [7:0] fs_sectors_per_cluster,
    output [31:0] fs_fat_start_lba, fs_data_start_lba, fs_max_cluster,
    input audio_sector_req,
    input [31:0] audio_sector_lba,
    output audio_sector_busy, audio_sector_valid, audio_sector_done,
    output [7:0] audio_sector_byte, audio_sector_error,
    output [8:0] audio_sector_byte_index,
    output SD_nCS, SD_DCLK, SD_MOSI,
    input SD_MISO
);
localparam [31:0] LOAD_TIMEOUT_CYCLES = (CLK_FREQ_HZ / 1000) * LOAD_TIMEOUT_MS;
localparam [31:0] SD_RESET_CYCLES = (CLK_FREQ_HZ < 1000) ? 1 : CLK_FREQ_HZ / 1000;
localparam [31:0] SD_RECOVER_CYCLES = (CLK_FREQ_HZ / 1000) * 5000;
localparam INIT=4'd0, SCAN=4'd1, SELECT=4'd2, START=4'd3,
           DECODE=4'd4, WAIT_LOADER=4'd5, NEXT=4'd6, DONE=4'd7,
           RECOVER=4'd8;
reg [3:0] load_state;
reg scan_start_pulse, load_start_pulse, load_abort;
reg scan_kicked, scan_done, sd_recovering;
reg [31:0] sd_reset_count, sd_recover_count, load_timeout_cnt;
reg [2:0] load_idx;
reg [1:0] retry_count;
reg recover_retry;
reg [5:0] attempted;
reg [31:0] load_cluster, load_file_size;
wire sd_local_reset = rst || (sd_reset_count != 0);
wire sd_sec_read, sd_sec_read_data_valid, sd_sec_read_end, sd_sec_read_error;
wire [31:0] sd_sec_read_addr;
wire [7:0] sd_sec_read_data;
wire sd_init_done, bmp_ready, load_error, scan_done_i, scanner_scan_ok;
wire [2:0] bmp_error;
wire bmp_data_wr_en;
wire [23:0] bmp_data;
wire key_auto_stable;
wire key_auto_down;
wire key_mode_stable;
wire key_mode_down;
reg key_auto_was_down, long_press_marked;
reg key_mode_was_down;
reg [31:0] long_press_count;
localparam [31:0] LONG_PRESS_CYCLES = (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS;
wire reader_write_req;
reg reader_write_ack;
reg loader_opened, decode_failed;
wire key_next_down;
wire [7:0] scanner_spc;
wire [31:0] scanner_fat_start, scanner_data_start, scanner_max_cluster;
wire [7:0] scanner_fs_error;
wire scanner_wav_valid, scanner_wav1_valid, scanner_wav2_valid, scanner_wav3_valid;
wire [31:0] scanner_wav_cluster, scanner_wav_size;
wire [31:0] scanner_wav1_cluster, scanner_wav1_size;
wire [31:0] scanner_wav2_cluster, scanner_wav2_size;
wire [31:0] scanner_wav3_cluster, scanner_wav3_size;
reg selected_wav_valid_q;
reg [31:0] selected_wav_cluster_q, selected_wav_size_q;
assign audio_storage_ready = load_state == DONE && !sd_local_reset &&
                             !sd_recovering && sd_init_done;
assign fs_sectors_per_cluster = scanner_spc;
assign fs_fat_start_lba = scanner_fat_start;
assign fs_data_start_lba = scanner_data_start;
assign fs_max_cluster = scanner_max_cluster;

// Pipeline the WAV-group selection before it reaches the stream player.
// This breaks the long group-index -> cluster multiply -> player-state path.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        selected_wav_valid_q   <= 1'b0;
        selected_wav_cluster_q <= 32'd0;
        selected_wav_size_q    <= 32'd0;
        wav_file_valid         <= 1'b0;
        wav_first_cluster      <= 32'd0;
        wav_file_size          <= 32'd0;
        wav_start_lba          <= 32'd0;
        wav_total_sectors      <= 32'd0;
    end else begin
        case (audio_file_index)
            3'd6: begin
                selected_wav_valid_q   <= scanner_wav1_valid;
                selected_wav_cluster_q <= scanner_wav1_cluster;
                selected_wav_size_q    <= scanner_wav1_size;
            end
            3'd1: begin
                selected_wav_valid_q   <= scanner_wav2_valid;
                selected_wav_cluster_q <= scanner_wav2_cluster;
                selected_wav_size_q    <= scanner_wav2_size;
            end
            3'd2: begin
                selected_wav_valid_q   <= scanner_wav2_valid;
                selected_wav_cluster_q <= scanner_wav2_cluster;
                selected_wav_size_q    <= scanner_wav2_size;
            end
            3'd3: begin
                selected_wav_valid_q   <= scanner_wav3_valid;
                selected_wav_cluster_q <= scanner_wav3_cluster;
                selected_wav_size_q    <= scanner_wav3_size;
            end
            3'd4: begin
                selected_wav_valid_q   <= scanner_wav3_valid;
                selected_wav_cluster_q <= scanner_wav3_cluster;
                selected_wav_size_q    <= scanner_wav3_size;
            end
            3'd5: begin
                selected_wav_valid_q   <= scanner_wav_valid;
                selected_wav_cluster_q <= scanner_wav_cluster;
                selected_wav_size_q    <= scanner_wav_size;
            end
            default: begin
                selected_wav_valid_q   <= 1'b0;
                selected_wav_cluster_q <= 32'd0;
                selected_wav_size_q    <= 32'd0;
            end
        endcase

        wav_file_valid    <= scan_done && selected_wav_valid_q &&
                             (scanner_fs_error == 0 || scanner_fs_error == 8'h22);
        wav_first_cluster <= selected_wav_cluster_q;
        wav_file_size     <= selected_wav_size_q;
        wav_start_lba     <= scanner_data_start +
                             (selected_wav_cluster_q - 32'd2) * scanner_spc;
        wav_total_sectors <= (selected_wav_size_q >> 9) +
                             (|selected_wav_size_q[8:0]);
    end
end
wire [5:0] scan_resource_valid;
wire [31:0] img_cluster0, img_cluster1, img_cluster2, img_cluster3,
            img_cluster4, img_cluster5;
wire [31:0] img_size0, img_size1, img_size2, img_size3,
            img_size4, img_size5;
wire [5:0] target_mask = SCAN_TARGET_COUNT >= 6 ? 6'b111111 :
                         SCAN_TARGET_COUNT == 5 ? 6'b011111 :
                         SCAN_TARGET_COUNT == 4 ? 6'b001111 :
                         SCAN_TARGET_COUNT == 3 ? 6'b000111 :
                         SCAN_TARGET_COUNT == 2 ? 6'b000011 : 6'b000001;
wire [5:0] remaining = scan_resource_valid & target_mask & ~attempted;
wire [2:0] selected_idx = remaining[0] ? 3'd0 : remaining[1] ? 3'd1 :
                          remaining[2] ? 3'd2 : remaining[3] ? 3'd3 :
                          remaining[4] ? 3'd4 : 3'd5;
assign loader_pixel_valid = bmp_data_wr_en && !sd_local_reset && !load_abort;
assign loader_pixel_rgb = bmp_data;
key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    // Fast press qualification, with a longer release filter preventing
    // contact bounce from generating a second navigation event.
    .DEBOUNCE_MS (2),
    .RELEASE_DEBOUNCE_MS (20)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_down),
    .button_stable_out()
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (10)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_down),
    //修改9.28
    .button_stable_out(key_auto_stable)
    //修改完成
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (10)
) u_key_mode (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_mode),
    .press_pulse(key_mode_down),
    .button_stable_out(key_mode_stable)
);

// KEY1 advances independently. KEY2 short release toggles autoplay and a
// one-second hold selects the previous image. KEY3 short release cycles mode.
assign key_next_press = key_next_down;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        key_auto_was_down <= 0; long_press_marked <= 0; long_press_count <= 0;
        key_mode_was_down <= 0;
        key_auto_press <= 0; key_prev_press <= 0; key_mode_press<=0;
    end else begin
        key_auto_press <= 0; key_prev_press <= 0; key_mode_press<=0;
        key_auto_was_down <= !key_auto_stable;
        key_mode_was_down <= !key_mode_stable;
        if (!key_auto_stable) begin
            if (!long_press_marked) begin
                if (long_press_count >= LONG_PRESS_CYCLES-1) begin
                    long_press_marked <= 1; key_prev_press <= 1;
                end else long_press_count <= long_press_count + 1'b1;
            end
        end else begin
            if (key_auto_was_down && !long_press_marked) key_auto_press <= 1;
            long_press_count <= 0; long_press_marked <= 0;
        end
        if (key_mode_was_down && key_mode_stable) key_mode_press <= 1;
    end
end

function [31:0] cluster_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: cluster_lut = img_cluster0;
            3'd1: cluster_lut = img_cluster1;
            3'd2: cluster_lut = img_cluster2;
            3'd3: cluster_lut = img_cluster3;
            3'd4: cluster_lut = img_cluster4;
            default: cluster_lut = img_cluster5;
        endcase
    end
endfunction

function [31:0] size_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: size_lut = img_size0;
            3'd1: size_lut = img_size1;
            3'd2: size_lut = img_size2;
            3'd3: size_lut = img_size3;
            3'd4: size_lut = img_size4;
            default: size_lut = img_size5;
        endcase
    end
endfunction


always @(posedge clk or posedge rst) begin
    if (rst) begin
        load_state <= INIT; state_code <= 0;
        scan_start_pulse <= 0; load_start_pulse <= 0; load_abort <= 0;
        scan_kicked <= 0; scan_done <= 0; sd_recovering <= 0;
        sd_reset_count <= 0; sd_recover_count <= 0; load_timeout_cnt <= 0;
        load_idx <= 0; retry_count <= 0; attempted <= 0;
        recover_retry <= 0;
        load_cluster <= 0; load_file_size <= 0;
        loader_load_start <= 0; loader_image_index <= 0; loader_decode_error <= 0;
        reader_write_ack <= 0;
        loader_opened<=0; decode_failed<=0;
    end else begin
        scan_start_pulse <= 0; load_start_pulse <= 0; load_abort <= 0;
        loader_load_start <= 0; loader_decode_error <= 0;
        // The legacy parser's start handshake now stays entirely in the SD
        // domain; the loader is opened by the ordered START FIFO marker.
        reader_write_ack <= reader_write_req;
        if (load_state==DECODE && reader_write_req && !reader_write_ack) begin
            loader_load_start<=1; loader_opened<=1;
        end
        if (sd_reset_count != 0) sd_reset_count <= sd_reset_count - 1'b1;
        case (load_state)
            INIT: if (sd_init_done && Sdr_init_done && bmp_ready) begin
                scan_start_pulse <= 1; scan_kicked <= 1;
                load_state <= SCAN; state_code <= 2;
            end
            SCAN: if (scan_done_i) begin
                scan_done <= 1;
                if (scanner_scan_ok) load_state <= SELECT;
                else begin load_state <= DONE; state_code <= 8; end
            end
            SELECT: if (remaining != 0) begin
                load_idx <= selected_idx; loader_image_index <= selected_idx;
                load_cluster <= cluster_lut(selected_idx);
                load_file_size <= size_lut(selected_idx);
                attempted[selected_idx] <= 1;
                retry_count <= 0;
                load_state <= START;
            end else begin load_state <= DONE; state_code <= 1; end
            START: if (sd_init_done && Sdr_init_done && bmp_ready) begin
                loader_opened<=0; decode_failed<=0;
                load_start_pulse <= 1;
                load_timeout_cnt <= 0;
                load_state <= DECODE; state_code <= 4;
            end
            DECODE: begin
                load_timeout_cnt <= load_timeout_cnt + 1'b1;
                if (loader_load_done) begin
                    // An early FIFO/memory failure must abort the source too.
                    load_abort <= 1;
                    load_state <= NEXT;
                end else if (load_error || load_timeout_cnt >= LOAD_TIMEOUT_CYCLES) begin
                    loader_decode_error <= load_error ?
                                           (bmp_error != 0 ? {5'd0,bmp_error} : 8'h83) : 8'h80;
                    load_abort <= 1;
                    decode_failed<=1;
                    load_state <= loader_opened ? WAIT_LOADER : NEXT; state_code <= 8;
                    if (bmp_error == 2 || load_timeout_cnt >= LOAD_TIMEOUT_CYCLES) begin
                        sd_reset_count <= SD_RESET_CYCLES;
                        sd_recover_count <= 0; sd_recovering <= 1;
                    end
                end else if (loader_frame_commit) begin
                    load_state <= WAIT_LOADER;
                end
            end
            WAIT_LOADER: if (loader_load_done) load_state <= NEXT;
            NEXT: begin
                if ((decode_failed || (loader_opened && loader_memory_error != 0)) && retry_count < 2) begin
                    retry_count <= retry_count + 1'b1;
                    recover_retry <= 1;
                    load_state <= sd_recovering ? RECOVER : START;
                end else begin
                    recover_retry <= 0;
                    load_state <= sd_recovering ? RECOVER : SELECT;
                end
            end
            RECOVER: begin
                sd_recover_count <= sd_recover_count + 1'b1;
                if (sd_reset_count == 0 && sd_init_done) begin
                    sd_recovering <= 0;
                    load_state <= recover_retry ? START : SELECT;
                end else if (sd_recover_count >= SD_RECOVER_CYCLES) begin
                    sd_recovering <= 0; load_state <= DONE; state_code <= 8;
                end
            end
            DONE: ;
            default: load_state <= INIT;
        endcase
    end
end

// ---------- 扇区读仲裁：两个FAT32模块都要读SD卡，分时复用 ----------
// 扫描阶段用扫描器，加载阶段用流读器（扫描和加载不会同时进行）
reg         use_streamer;          // 0=用扫描器, 1=用流读器
reg         scan_success;          // 扫描成功标志（至少找到1个文件）
// A partial catalog (ERR_RESOURCE_MISSING) is usable; an SD I/O failure is
// not a successful scan even if an earlier directory entry was captured.
assign scanner_scan_ok = (scan_resource_valid != 6'd0) &&
                       ((scanner_fs_error == 8'h00) || (scanner_fs_error == 8'h22));
wire [2:0] resource_count = {2'd0, scan_resource_valid[0]} +
                             {2'd0, scan_resource_valid[1]} +
                             {2'd0, scan_resource_valid[2]} +
                             {2'd0, scan_resource_valid[3]} +
                             {2'd0, scan_resource_valid[4]} +
                             {2'd0, scan_resource_valid[5]};
wire reader_ready, reader_load_error;
wire [2:0] reader_bmp_error;
assign bmp_ready = reader_ready;
assign load_error = reader_load_error;
assign bmp_error = reader_bmp_error;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        use_streamer <= 1'b0;
        scan_success <= 1'b0;
    end else if (scan_start_pulse) begin
        use_streamer <= 1'b0;
        scan_success <= 1'b0;
    end else if (scan_done_i) begin
        scan_success <= scanner_scan_ok;
        use_streamer <= scanner_scan_ok;
    end
end

// 扫描器的扇区读接口（接到仲裁器）
wire        scanner_sector_req;
wire [31:0] scanner_sector_lba;
wire        scanner_sector_busy;
wire        scanner_sector_valid;
wire [7:0]  scanner_sector_byte;
wire [8:0]  scanner_sector_byte_index;
wire        scanner_sector_done;
wire [7:0]  scanner_sector_error;

// 流读器的扇区读接口（接到仲裁器）
wire        streamer_sector_req;
wire [31:0] streamer_sector_lba;
wire        streamer_sector_busy;
wire        streamer_sector_valid;
wire [7:0]  streamer_sector_byte;
wire [8:0]  streamer_sector_byte_index;
wire        streamer_sector_done;
wire [7:0]  streamer_sector_error;

// 仲裁器输出（接到sd_sector_adapter）
reg         arb_sector_req;
reg [31:0]  arb_sector_lba;
wire        arb_sector_busy;
wire        arb_sector_valid;
wire [7:0]  arb_sector_byte;
wire [8:0]  arb_sector_byte_index;
wire        arb_sector_done;
wire [7:0]  arb_sector_error;

// 仲裁逻辑：use_streamer=0时透传扫描器，=1时透传流读器
always @(*) begin
    if (load_state == DONE) begin
        arb_sector_req = audio_sector_req && wav_file_valid && !sd_recovering;
        arb_sector_lba = audio_sector_lba;
    end else if (use_streamer) begin
        arb_sector_req   = streamer_sector_req && scan_success;
        arb_sector_lba   = streamer_sector_lba;
        // 流读器接收仲裁返回
        // （扫描器的返回信号设为无效）
    end else begin
        arb_sector_req   = scanner_sector_req;
        arb_sector_lba   = scanner_sector_lba;
        // 扫描器接收仲裁返回
        // （流读器的返回信号设为无效）
    end
end

// The unselected engine must not consume sector bytes/completion or issue
// a request while the selected engine owns the SD interface.
assign scanner_sector_busy       = load_state == DONE || use_streamer || arb_sector_busy;
assign scanner_sector_valid      = load_state != DONE && !use_streamer && arb_sector_valid;
assign scanner_sector_byte       = arb_sector_byte;
assign scanner_sector_byte_index = arb_sector_byte_index;
assign scanner_sector_done       = load_state != DONE && !use_streamer && arb_sector_done;
assign scanner_sector_error      = !use_streamer ? arb_sector_error : 8'd0;
assign streamer_sector_busy       = load_state == DONE || !use_streamer || !scan_success || arb_sector_busy;
assign streamer_sector_valid      = load_state != DONE && use_streamer && scan_success && arb_sector_valid;
assign streamer_sector_byte       = arb_sector_byte;
assign streamer_sector_byte_index = arb_sector_byte_index;
assign streamer_sector_done       = load_state != DONE && use_streamer && scan_success && arb_sector_done;
assign streamer_sector_error      = use_streamer && scan_success ? arb_sector_error : 8'd0;
assign audio_sector_busy = load_state != DONE || !wav_file_valid || sd_local_reset ||
                           sd_recovering || !sd_init_done || arb_sector_busy;
assign audio_sector_valid = load_state == DONE && arb_sector_valid;
assign audio_sector_done = load_state == DONE && arb_sector_done;
assign audio_sector_byte = arb_sector_byte;
assign audio_sector_byte_index = arb_sector_byte_index;
assign audio_sector_error = load_state == DONE ? arb_sector_error : 8'd0;

// ---------- 卷扫描器 ----------
fat32_volume_scanner u_scanner (
    .clk                 (clk),
    .rst_n               (~rst),            // 官方是高有效复位，新模块是低有效
    .scan_start          (scan_start_pulse),
    .scan_busy           (),
    .scan_done           (scan_done_i),
    .fs_error            (scanner_fs_error),
    .partition_lba       (),
    .sectors_per_cluster (scanner_spc),
    .fat_start_lba       (scanner_fat_start),
    .data_start_lba      (scanner_data_start),
    .max_cluster         (scanner_max_cluster),
    .resource_valid      (scan_resource_valid),
    .resource0_cluster   (img_cluster0),
    .resource1_cluster   (img_cluster1),
    .resource2_cluster   (img_cluster2),
    .resource3_cluster   (img_cluster3),
    .resource4_cluster   (img_cluster4),
    .resource5_cluster   (img_cluster5),
    .resource0_size      (img_size0),
    .resource1_size      (img_size1),
    .resource2_size      (img_size2),
    .resource3_size      (img_size3),
    .resource4_size      (img_size4),
    .resource5_size      (img_size5),
    .wav1_valid          (scanner_wav1_valid),
    .wav1_cluster        (scanner_wav1_cluster),
    .wav1_size           (scanner_wav1_size),
    .wav_valid           (scanner_wav_valid),
    .wav_cluster         (scanner_wav_cluster),
    .wav_size            (scanner_wav_size),
    .wav2_valid          (scanner_wav2_valid),
    .wav2_cluster        (scanner_wav2_cluster),
    .wav2_size           (scanner_wav2_size),
    .wav3_valid          (scanner_wav3_valid),
    .wav3_cluster        (scanner_wav3_cluster),
    .wav3_size           (scanner_wav3_size),
    .sector_req          (scanner_sector_req),
    .sector_lba          (scanner_sector_lba),
    .sector_busy         (scanner_sector_busy),
    .sector_valid        (scanner_sector_valid),
    .sector_byte         (scanner_sector_byte),
    .sector_byte_index   (scanner_sector_byte_index),
    .sector_done         (scanner_sector_done),
    .sector_error        (scanner_sector_error)
);

// ---------- 文件流读取器 ----------
// Contains the FAT file streamer and the existing validated BMP decoder.
bmp_fat_reader #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .STRETCH_TO_DISPLAY(1)) u_streamer (
    .clk                 (clk),
    .rst                 (sd_local_reset),
    .load_start          (load_start_pulse && scan_success && use_streamer),
    .load_abort          (load_abort),
    .load_cluster        (load_cluster),
    .load_file_size      (load_file_size),
    .sectors_per_cluster (scanner_spc),
    .fat_start_lba       (scanner_fat_start),
    .data_start_lba      (scanner_data_start),
    .max_cluster         (scanner_max_cluster),
    .bmp_width           (bmp_width),
    .bmp_height          (bmp_height),
    .decoded_width       (loader_image_width),
    .decoded_height      (loader_image_height),
    .decoded_bottom_up   (loader_image_bottom_up),
    .ready               (reader_ready),
    .bmp_error           (reader_bmp_error),
    .load_error          (reader_load_error),
    .write_req           (reader_write_req),
    .write_req_ack       (reader_write_ack),
    .bmp_data_wr_en      (bmp_data_wr_en),
    .bmp_data            (bmp_data),
    .frame_commit        (loader_frame_commit),
    .sector_req          (streamer_sector_req),
    .sector_lba          (streamer_sector_lba),
    .sector_busy         (streamer_sector_busy),
    .sector_valid        (streamer_sector_valid),
    .sector_byte         (streamer_sector_byte),
    .sector_byte_index   (streamer_sector_byte_index),
    .sector_done         (streamer_sector_done),
    .sector_error        (streamer_sector_error)
);

// ---------- SD卡接口适配层（对接官方sd_card_top）----------
sd_sector_adapter #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_adapter (
    .clk                    (clk),
    .rst_n                  (~sd_local_reset),
    // 新模块侧（接仲裁器输出）
    .sector_req             (arb_sector_req),
    .sector_lba             (arb_sector_lba),
    .sector_busy            (arb_sector_busy),
    .sector_valid           (arb_sector_valid),
    .sector_byte            (arb_sector_byte),
    .sector_byte_index      (arb_sector_byte_index),
    .sector_done            (arb_sector_done),
    .sector_error           (arb_sector_error),
    // 官方sd_card_top侧
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_read_error      (sd_sec_read_error)
);
//=== 修改结束 ===

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (sd_local_reset),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read && !sd_recovering),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_read_error      (sd_sec_read_error),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (8'd0),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer RELEASE_DEBOUNCE_MS = DEBOUNCE_MS
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse,
    //修改9.28
    output reg  button_stable_out
    //修改完成
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
localparam integer RELEASE_DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * RELEASE_DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        //修改9.28
        button_stable_out <= 1'b1;
        //修改完成
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= (button_sync1 ? RELEASE_DEBOUNCE_CYCLES : DEBOUNCE_CYCLES) - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                //修改9.28
                button_stable_out <= button_sync1;
                //修改完成
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
