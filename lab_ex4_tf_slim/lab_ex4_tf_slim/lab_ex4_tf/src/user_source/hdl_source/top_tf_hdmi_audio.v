
module top(
    input                       clk,
    input                       rst_n,
    input                       key1, // Next image
    input                       key2, // Short: autoplay; long: previous image
    input                       key3, // Display mode
    input                       key4, // Brightness/contrast/volume selected by SW1/SW2
    input                       sw1,
    input                       sw2,
    input                       sw3,  // KEY1: 0 selects image 6, 1 cycles images 1..5

	output [5:0]                seg_sel,
	output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;
parameter BUF2_ADDR     = FRAME_PIXELS * 2;
parameter BUF3_ADDR     = FRAME_PIXELS * 3;
parameter BUF4_ADDR     = FRAME_PIXELS * 4;
parameter BUF5_ADDR     = FRAME_PIXELS * 5;
parameter [1:0] AUDIO_SOURCE_MODE = 2'd0; // 0=image 1 tone/images 2..6 WAV, 1=tone, 2=silence

wire sd_card_clk, sys_pll_clk0, ext_mem_clk, ext_mem_clk_sft, video_clk, hdmi_5x_clk;
wire Sdr_init_done, Sdr_init_ref_vld, Sdr_busy;
wire App_rd_en, Sdr_rd_en, App_wr_en;
wire [ADDR_BITS-1:0] App_rd_addr, App_wr_addr;
wire [31:0] Sdr_rd_dout, App_wr_din;
wire [3:0] App_wr_dm;
wire hs, vs, de, line_active;
wire [23:0] vout_data_raw, text_rgb_out, vout_data;
wire [23:0] startup_gated_video;
reg display_valid;
wire [3:0] state_code;
wire [6:0] seg_data_0;
wire [2:0] media_id_sd;
reg [2:0] media_id_pix1, media_id_pix2;
wire [9:0] video_x;
wire [9:0] reader_video_x;
reg [1:0] display_mode_sd, mode_pix1, mode_pix2, display_mode;
reg [2:0] frame_focus;
reg [5:0] frame_complete;
reg [95:0] widths_pix1,widths_pix2,heights_pix1,heights_pix2;
reg [95:0] frame_widths,frame_heights;
reg [5:0] flips_pix1,flips_pix2,frame_flips;
reg frame_capture;
wire [11:0] raw_x,raw_y,request_x,request_y;
wire request_valid;
wire [15:0] current_width=frame_widths[frame_focus*16 +: 16];
wire [15:0] current_height=frame_heights[frame_focus*16 +: 16];
wire        layout_de;
wire [2:0]  layout_source_index;
wire [15:0] layout_source_x, layout_source_y;
wire        layout_focus_border;
wire [2:0] mapped_index;
wire [15:0] mapped_x,mapped_y,mapped_stride;
wire [15:0] mapped_source_y;
wire mapped_de;
wire reader_underflow;
wire [7:0] reader_memory_error;
reg [7:0] reader_error_pix1,reader_error_pix2,source_error_hold;
wire [9:0] tmds_ch0_data, tmds_ch1_data, tmds_ch2_data, tmds_clk_data;
(* keep = "true" *) wire audio_probe_valid;
(* keep = "true" *) wire signed [15:0] audio_probe_left;
wire source_load_start, source_pixel_valid, source_frame_commit;
wire [2:0] source_image_index;
wire [23:0] source_pixel_rgb;
wire [7:0] source_decode_error;
wire [15:0] source_image_width,source_image_height,loader_image_width,loader_image_height;
wire source_image_bottom_up,loader_image_bottom_up;
wire [95:0] bank_widths,bank_heights;
wire [5:0] bank_bottom_up;
wire loader_load_start, loader_pixel_valid, loader_frame_commit;
wire [2:0] loader_image_index;
wire [23:0] loader_pixel_rgb;
wire [7:0] loader_decode_error;
wire loader_load_busy, loader_load_done;
wire [5:0] loader_image_complete;
wire [7:0] loader_memory_error;
wire write_request_busy, read_request_busy;
wire [2:0] reader_active_index;
wire reader_frame_start, reader_pixel_consume;
wire [23:0] reader_pixel_rgb;
wire reader_pixel_valid;
wire ctrl_index_commit;
wire ctrl_auto_enabled;
wire [2:0] ctrl_pending_index;
wire [7:0] ctrl_control_error;
reg done_toggle_mem;
reg [2:0] done_sync_sd;
reg [7:0] memory_error_sd1, memory_error_sd2;
reg [5:0] complete_sd1, complete_sd2, complete_pix1, complete_pix2;
wire raw_hs, raw_vs, raw_de, raw_line_active;
reg raw_vs_q;
reg hs_q, vs_q, de_q, line_q;
wire [23:0] rgb_q;
reg [2:0] active_index_sd1, active_index_sd2;
// 统一复位：TF 图像链路 + HDMI 链路
wire sys_pll_lock;
wire video_pll_lock;
wire sdcard_rst_n;
wire mem_rst_n;
wire video_rst_n;
wire audio_rst_n;
wire Sdr_init_done_sd;
// 当前音频处理链与像素时钟同域；保留独立复位同步信号供音频模块使用。
wire audio_mclk = video_clk;
wire ext_rst_n = rst_n & sys_pll_lock & video_pll_lock;
// The TF/FAT/BMP path has substantially more combinational work than the
// SDRAM interface. Run it from the board's clean 50 MHz clock so decoded RGB
// cannot be corrupted by the former 100 MHz setup-time violations. The PLL
// C0 output remains connected because it is also the PLL feedback clock.
assign sd_card_clk = clk;

wire key_next_press;
wire key_auto_press;
wire key_prev_press;
wire key_mode_press;
wire audio_storage_ready, wav_file_valid;
wire [31:0] wav_first_cluster, wav_file_size, wav_start_lba, wav_total_sectors;
wire [7:0] fs_sectors_per_cluster;
wire [31:0] fs_fat_start_lba, fs_data_start_lba, fs_max_cluster;
wire wav_sd_req, wav_sd_busy, wav_sd_valid, wav_sd_done;
wire [31:0] wav_sd_lba;
wire [7:0] wav_sd_byte, wav_sd_error;
wire [8:0] wav_sd_byte_index;
wire wav_pcm_valid, wav_pcm_ready, wav_stream_active, wav_stream_end, wav_buffer_low;
wire signed [15:0] wav_pcm_left, wav_pcm_right;
reg startup_av_ready;
wire pcm_tap_valid;
wire signed [15:0] pcm_tap_left;
wire waveform_active;
// Keep the audio waveform visible in its original on-screen position.
// The PCM tap and waveform renderer share video_clk, so no CDC is required.
wire waveform_enable = (AUDIO_SOURCE_MODE == 2'd0) ||
                       (AUDIO_SOURCE_MODE == 2'd1);
wire [31:0] wav_sample_counter;
wire [7:0] wav_format_error;
reg [24:0] wav_rate_accumulator;
wire wav_sample_tick = wav_rate_accumulator >= 25_000_000 - 48_000;
// Derive and register the group in the pixel domain before crossing clocks.
// A 2->3 or 4->5 image switch therefore leaves this bus completely static,
// rather than exposing a transient multi-bit image index to the WAV reset.
wire [2:0] wav_audio_group_pix_next =
    (reader_active_index == 3'd0) ? 3'd6 :
    (reader_active_index == 3'd1 || reader_active_index == 3'd2) ? 3'd1 :
    (reader_active_index == 3'd3 || reader_active_index == 3'd4) ? 3'd3 :
    (reader_active_index == 3'd5) ? 3'd5 : 3'd0;
reg [2:0] wav_audio_group_pix;
(* async_reg = "true" *) reg [2:0] wav_group_sync1, wav_group_sync2;
reg [2:0] wav_audio_group_q1, wav_audio_group_q2;
wire [2:0] wav_audio_group_sd = wav_group_sync2;
wire wav_image_selected = wav_audio_group_sd != 3'd0;
wire wav_audio_group_stable = (wav_audio_group_q1 == wav_audio_group_sd) &&
                              (wav_audio_group_q2 == wav_audio_group_sd);
wire wav_group_image_ready =
    wav_audio_group_sd == 3'd6 ? complete_sd2[0] :
    wav_audio_group_sd == 3'd1 ? (complete_sd2[1] || complete_sd2[2]) :
    wav_audio_group_sd == 3'd3 ? (complete_sd2[3] || complete_sd2[4]) :
    wav_audio_group_sd == 3'd5 ? complete_sd2[5] : 1'b0;
// Hold play low only when changing audio groups while the two-stage file
// parameter pipeline catches up. A change within a group never stops WAV.
wire wav_play_enable = audio_storage_ready && wav_file_valid &&
                       wav_image_selected && wav_audio_group_stable &&
                       wav_group_image_ready;
// In normal mode every image uses its assigned WAV file.
wire [1:0] selected_audio_source_mode =
    AUDIO_SOURCE_MODE == 2'd0 ? 2'd0 : AUDIO_SOURCE_MODE;
// Tap accepted PCM after source selection.
// sample_valid alone can stay high under backpressure and is not a sample pulse.
assign pcm_tap_valid = audio_probe_valid;
assign pcm_tap_left = audio_probe_left;
//---- 转场控制器（第9课新增）----
wire        fade_next_event;   // 转场模块输出的切换请求
wire        fade_busy;
wire [7:0]  fade_alpha;
wire        fade_active;
wire        wipe_active;
wire [4:0]  wipe_ramp;
wire [2:0]  transition_kind;
(* async_reg = "true" *) reg sw3_sync1, sw3_sync2;
reg [1:0] key1_next_mode_latched;
reg key_lock_sd;
wire [1:0] key1_next_mode = fade_busy ? key1_next_mode_latched :
                            (sw3_sync2 ? 2'd1 : 2'd2);
// The image-6 navigation lock is independent from display mode (KEY3).
// KEY4 is inhibited separately whenever image 6 is the active picture.
wire key1_enabled = key_lock_sd ? 1'b1 : key1;
wire key2_enabled = key_lock_sd ? 1'b1 : key2;
wire key3_enabled = key3;
wire image6_active_sd = active_index_sd2 == 3'd5;

// Capture the switch mode with the accepted key press. The destination then
// remains stable throughout the fade-out interval.
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n) begin
        sw3_sync1 <= 1'b1;
        sw3_sync2 <= 1'b1;
        key1_next_mode_latched <= 2'd1;
        key_lock_sd <= 1'b0;
    end else begin
        sw3_sync1 <= sw3;
        sw3_sync2 <= sw3_sync1;
        if (key_next_press && !fade_busy)
            key1_next_mode_latched <= sw3_sync2 ? 2'd1 : 2'd2;
        if (sw3_sync2)
            key_lock_sd <= 1'b0;
        else if (active_index_sd2 == 3'd5)
            key_lock_sd <= 1'b1;
    end
end



// OSD状态叠加：接入实际视频信号，SD域状态先同步到像素域。
wire [23:0] osd_rgb_out;
wire        osd_de_out;
wire        osd_active;
reg         osd_auto_pix1, osd_auto_pix2;
reg [7:0]   osd_error_pix1, osd_error_pix2;
wire [7:0]  osd_error_sd = source_error_hold != 0 ? source_error_hold :
                           memory_error_sd2 != 0 ? memory_error_sd2 : ctrl_control_error;
wire [7:0] cfg_volume_sd, cfg_brightness_sd, cfg_contrast_sd;
wire [7:0] brightness_frame, contrast_frame;
wire cfg_update_valid_sd;
wire cfg_service_ready;
(* async_reg = "true" *) reg [7:0] volume_pix1, volume_pix2;

// active_index changes only at a video frame boundary. Applying the image-6
// override in this domain keeps all three parameters coherent for the whole
// frame and avoids mid-frame brightness/contrast artifacts.
wire image6_active_pix = reader_active_index == 3'd5;
wire [7:0] active_volume_pix = image6_active_pix ? 8'd255 : volume_pix2;
wire [7:0] active_brightness_pix = image6_active_pix ? 8'd192 : brightness_frame;
wire [7:0] active_contrast_pix = image6_active_pix ? 8'd128 : contrast_frame;

// Mode is held in SD domain, synchronized, then committed only in blanking.
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n) begin display_mode_sd<=2'd1; source_error_hold<=0; end
    else begin
        // KEY3 is a two-way toggle: thumbnail <-> fitted fullscreen.
        // Keeping fullscreen as a single user-visible state avoids stepping
        // through the native-size renderer before returning to thumbnails.
        if (key_mode_press)
            display_mode_sd <= (display_mode_sd == 2'd0) ? 2'd1 : 2'd0;
        if (source_load_start) source_error_hold<=0;
        if (source_decode_error!=0) source_error_hold<=source_decode_error;
    end
end
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        mode_pix1<=2'd1; mode_pix2<=2'd1; display_mode<=2'd1;
        frame_focus<=0; frame_complete<=0; frame_capture<=0;
        widths_pix1<=0; widths_pix2<=0; heights_pix1<=0; heights_pix2<=0;
        frame_widths<=0; frame_heights<=0;
        flips_pix1<=0; flips_pix2<=0; frame_flips<=0;
    end else begin
        mode_pix1<=display_mode_sd; mode_pix2<=mode_pix1;
        widths_pix1<=bank_widths; widths_pix2<=widths_pix1;
        heights_pix1<=bank_heights; heights_pix2<=heights_pix1;
        flips_pix1<=bank_bottom_up; flips_pix2<=flips_pix1;
        frame_capture<=reader_frame_start;
        if (frame_capture) begin
            display_mode<=mode_pix2; frame_focus<=reader_active_index;
            frame_complete<=complete_pix2;
            frame_widths<=widths_pix2; frame_heights<=heights_pix2;
            frame_flips<=flips_pix2;
        end
    end
end

param_config_service u_param_config_service (
    .ctrl_clk(sd_card_clk), .ctrl_rst_n(sdcard_rst_n),
    .update_valid(cfg_update_valid_sd),
    .brightness_in(cfg_brightness_sd), .contrast_in(cfg_contrast_sd),
    .ready(cfg_service_ready),
    .pix_clk(video_clk), .pix_rst_n(video_rst_n),
    .frame_start(reader_frame_start),
    .brightness_frame(brightness_frame), .contrast_frame(contrast_frame)
);

always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        volume_pix1 <= 8'd255;
        volume_pix2 <= 8'd255;
        wav_audio_group_pix <= 3'd0;
    end else begin
        volume_pix1 <= cfg_volume_sd;
        volume_pix2 <= volume_pix1;
        wav_audio_group_pix <= wav_audio_group_pix_next;
    end
end



always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        osd_auto_pix1 <= 1'b0;
        osd_auto_pix2 <= 1'b0;
        osd_error_pix1 <= 8'd0;
        osd_error_pix2 <= 8'd0;
        reader_error_pix1<=0; reader_error_pix2<=0;
    end else begin
        osd_auto_pix1 <= ctrl_auto_enabled;
        osd_auto_pix2 <= osd_auto_pix1;
        osd_error_pix1 <= osd_error_sd;
        osd_error_pix2 <= osd_error_pix1;
        reader_error_pix1<=reader_memory_error; reader_error_pix2<=reader_error_pix1;
    end
end

always @(posedge video_clk or negedge audio_rst_n) begin
    if (!audio_rst_n)
        wav_rate_accumulator <= 0;
    else if (wav_sample_tick)
        wav_rate_accumulator <= wav_rate_accumulator - (25_000_000 - 48_000);
    else
        wav_rate_accumulator <= wav_rate_accumulator + 48_000;
end

// Keep the initial HDMI picture and WAV path closed until AUDIO1 has been
// prefetched.  Committing at a frame boundary prevents a partial first frame;
// the latch stays set, so later image/group switching is unchanged.
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        startup_av_ready <= 1'b0;
    else if (reader_frame_start && wav_stream_active)
        startup_av_ready <= 1'b1;
end

video_fade_transition #(
    .FADE_FRAMES(16)    // 16帧完成淡入淡出（约0.27秒@60fps）
) u_fade_transition (
    // 控制域（50MHz）
    .ctrl_clk       (sd_card_clk),
    .ctrl_rst_n     (sdcard_rst_n),
    .next_event_in  (key_next_press),   // 按键"下一张"
    .next_event_out (fade_next_event),  // → media_player_control
    .fade_busy      (fade_busy),
    // 像素域（25MHz）
    .pix_clk        (video_clk),
    .pix_rst_n      (video_rst_n),
    .player_active  (display_valid),
    .frame_start    (reader_frame_start),
    .index_commit   (ctrl_index_commit), // 来自控制层
    .active_index   (reader_active_index),
    .alpha_out      (fade_alpha),
    .fade_active    (fade_active),
    .wipe_active    (wipe_active),
    .ramp_out       (wipe_ramp),
    .transition_kind(transition_kind)
);

osd_overlay_24 #(
    .OSD_X(544),  // 88-pixel Chinese status, 8 pixels from the right edge
    .OSD_Y(8)     // OSD左上角Y=8
) u_osd_overlay (
    .clk          (video_clk),        // 像素时钟25MHz
    .rst_n        (video_rst_n),      // 像素域复位
    .vsync        (vs),               // 场同步
    .de           (de),               // 数据使能
    .rgb_in       (vout_data_raw),     // 原始24位RGB
    .pixel_x      (video_x),          // X坐标（来自视频时序）
    .active_index (reader_active_index), // Current image index 0..5
    .auto_enabled (osd_auto_pix2),     // 自动轮播使能
    .error_code   (reader_underflow ? 8'h63 : reader_error_pix2!=0 ? reader_error_pix2 : osd_error_pix2),
    .brightness   (active_brightness_pix),
    .contrast     (active_contrast_pix),
    .volume       (active_volume_pix),
    .param_valid  (1'b1),
    .rgb_out      (osd_rgb_out),      // 叠加OSD后的RGB
    .de_out       (osd_de_out),
    .osd_active   (osd_active)
);

// OSD是组合逻辑，RGB与原有DE/同步信号保持对齐。


// 每个时钟域一个复位同步器
reset_sync u_sdcard_reset (
    .clk        (sd_card_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (sdcard_rst_n)
);

reset_sync u_mem_reset (
    .clk        (ext_mem_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (mem_rst_n)
);

reset_sync u_video_reset (
    .clk        (video_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (video_rst_n)
);

reset_sync u_audio_reset (
    .clk        (audio_mclk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (audio_rst_n)
);
//=== 修改结束 ===

//=== 选做：Sdr_init_done从ext_mem_clk域同步到sd_card_clk域 ===
sync_2ff u_sdram_init_sync (
    .clk        (sd_card_clk),
    .rst_n      (sdcard_rst_n),
    .async_in   (Sdr_init_done),
    .sync_out   (Sdr_init_done_sd)
);
//=== 选做结束 ===

//=== 修改：sys_pll的reset从1'b0改成~rst_n，确认locked输出 ===
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sys_pll_clk0),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (~rst_n),        // 修改：原来接1'b0
    .extlock    (sys_pll_lock)   // 新增：如果IP没有locked输出端口，需要在IP配置里打开
);

//=== 修改：video_pll的reset从1'b0改成~rst_n，确认locked输出 ===
video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (~rst_n),         // 修改：原来接1'b0
    .extlock    (video_pll_lock)  // 新增：如果IP没有locked输出端口，需要在IP配置里打开
);


// Return a reliable completion event; error is held until the next load.
always @(posedge ext_mem_clk or negedge mem_rst_n) begin
    if (!mem_rst_n) done_toggle_mem <= 0;
    else if (loader_load_done) done_toggle_mem <= ~done_toggle_mem;
end
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n) begin
        done_sync_sd <= 0; memory_error_sd1 <= 0; memory_error_sd2 <= 0;
        complete_sd1 <= 0; complete_sd2 <= 0;
        active_index_sd1 <= 0; active_index_sd2 <= 0;
        wav_group_sync1 <= 0;
        wav_group_sync2 <= 0;
        wav_audio_group_q1 <= 0;
        wav_audio_group_q2 <= 0;
    end else begin
        done_sync_sd <= {done_sync_sd[1:0],done_toggle_mem};
        memory_error_sd1 <= loader_memory_error; memory_error_sd2 <= memory_error_sd1;
        complete_sd1 <= loader_image_complete; complete_sd2 <= complete_sd1;
        active_index_sd1 <= reader_active_index; active_index_sd2 <= active_index_sd1;
        wav_group_sync1 <= wav_audio_group_pix;
        wav_group_sync2 <= wav_group_sync1;
        wav_audio_group_q1 <= wav_audio_group_sd;
        wav_audio_group_q2 <= wav_audio_group_q1;
    end
end
assign media_id_sd = active_index_sd2;
sd_card_bmp #(.CLK_FREQ_HZ(50_000_000), .SCAN_TARGET_COUNT(3'd6)) sd_card_bmp_m0 (
    .clk(sd_card_clk), .rst(~sdcard_rst_n), .Sdr_init_done(Sdr_init_done_sd),
    .key_next(key1_enabled), .key_auto(key2_enabled), .key_mode(key3_enabled),
    .audio_file_index(wav_audio_group_sd),
    .key_next_press(key_next_press), .key_auto_press(key_auto_press), .key_prev_press(key_prev_press),
    .key_mode_press(key_mode_press),
    .state_code(state_code), .bmp_width(16'd0), .bmp_height(16'd0),
    .loader_load_start(source_load_start), .loader_image_index(source_image_index),
    .loader_image_width(source_image_width), .loader_image_height(source_image_height),
    .loader_image_bottom_up(source_image_bottom_up),
    .loader_pixel_valid(source_pixel_valid), .loader_pixel_rgb(source_pixel_rgb),
    .loader_frame_commit(source_frame_commit), .loader_decode_error(source_decode_error),
    .loader_load_done(done_sync_sd[2] ^ done_sync_sd[1]),
    .loader_memory_error(memory_error_sd2),
    .audio_storage_ready(audio_storage_ready),
    .wav_file_valid(wav_file_valid),
    .wav_first_cluster(wav_first_cluster), .wav_file_size(wav_file_size),
    .wav_start_lba(wav_start_lba), .wav_total_sectors(wav_total_sectors),
    .fs_sectors_per_cluster(fs_sectors_per_cluster),
    .fs_fat_start_lba(fs_fat_start_lba), .fs_data_start_lba(fs_data_start_lba),
    .fs_max_cluster(fs_max_cluster),
    .audio_sector_req(wav_sd_req), .audio_sector_lba(wav_sd_lba),
    .audio_sector_busy(wav_sd_busy), .audio_sector_valid(wav_sd_valid),
    .audio_sector_byte(wav_sd_byte), .audio_sector_byte_index(wav_sd_byte_index),
    .audio_sector_done(wav_sd_done), .audio_sector_error(wav_sd_error),
    .SD_nCS(sd_ncs), .SD_DCLK(sd_dclk), .SD_MOSI(sd_mosi), .SD_MISO(sd_miso)
);

wav_stream_player #(
    .LOOP_ENABLE(1),
    // One-time 650 ms lead-in. The HDMI bridge turns digital zero into an
    // inaudible 1-LSB keepalive so slow sinks unmute before speech starts.
    // The WAV FIFO is not consumed during this interval.
    .STARTUP_PREROLL_SAMPLES(31200)
) u_wav_player (
    .wr_clk(sd_card_clk), .wr_rst_n(sdcard_rst_n), .play_enable(wav_play_enable),
    .start_lba(wav_start_lba), .total_sectors(wav_total_sectors),
    .first_cluster(wav_first_cluster), .file_size(wav_file_size),
    .sectors_per_cluster(fs_sectors_per_cluster), .fat_start_lba(fs_fat_start_lba),
    .data_start_lba(fs_data_start_lba), .max_cluster(fs_max_cluster),
    .sd_req(wav_sd_req), .sd_lba(wav_sd_lba), .sd_busy(wav_sd_busy),
    .sd_valid(wav_sd_valid), .sd_byte(wav_sd_byte), .sd_byte_index(wav_sd_byte_index),
    .sd_done(wav_sd_done), .sd_error(wav_sd_error),
    .rd_clk(video_clk), .rd_rst_n(audio_rst_n), .sample_tick(wav_sample_tick),
    .sample_out(wav_pcm_left), .sample_right(wav_pcm_right),
    .sample_valid(wav_pcm_valid), .sample_ready(wav_pcm_ready),
    .sample_counter(wav_sample_counter), .stream_active(wav_stream_active),
    .stream_end(wav_stream_end), .buffer_low(wav_buffer_low),
    .format_error(wav_format_error)
);
media_pixel_cdc u_pixel_cdc (
    .sd_clk(sd_card_clk), .sd_rst_n(sdcard_rst_n),
    .mem_clk(ext_mem_clk), .mem_rst_n(mem_rst_n),
    .source_start(source_load_start), .source_index(source_image_index),
    .source_width(source_image_width), .source_height(source_image_height),
    .source_bottom_up(source_image_bottom_up),
    .source_pixel_valid(source_pixel_valid), .source_pixel_rgb(source_pixel_rgb),
    .source_commit(source_frame_commit), .source_error(source_decode_error),
    .load_start(loader_load_start), .image_index(loader_image_index),
    .image_width(loader_image_width), .image_height(loader_image_height),
    .image_bottom_up(loader_image_bottom_up),
    .pixel_valid(loader_pixel_valid), .pixel_rgb(loader_pixel_rgb),
    .frame_commit(loader_frame_commit), .decode_error(loader_decode_error)
);
media_frame_loader #(
    .ADDR_WIDTH(21), .IMAGE_WORDS(307200), .FIFO_DEPTH(512), .BURST_SIZE(128),
    .STALL_TIMEOUT(65535), .DYNAMIC_GEOMETRY(1)
) u_loader (
    .clk(ext_mem_clk), .rst_n(mem_rst_n),
    .load_start(loader_load_start), .image_index(loader_image_index),
    .image_width(loader_image_width), .image_height(loader_image_height),
    .image_bottom_up(loader_image_bottom_up), .bank_widths(bank_widths), .bank_heights(bank_heights),
    .bank_bottom_up(bank_bottom_up),
    .pixel_valid(loader_pixel_valid), .pixel_rgb(loader_pixel_rgb),
    .frame_commit(loader_frame_commit), .decode_error(loader_decode_error),
    .load_busy(loader_load_busy), .load_done(loader_load_done),
    .image_complete(loader_image_complete), .memory_error(loader_memory_error),
    .controller_init_done(Sdr_init_done), .controller_busy(Sdr_busy),
    .refresh_active(Sdr_init_ref_vld), .read_request_busy(read_request_busy),
    .write_request_busy(write_request_busy),
    .app_wr_en(App_wr_en), .app_wr_addr(App_wr_addr),
    .app_wr_mask(App_wr_dm), .app_wr_data(App_wr_din)
);
media_frame_reader #(
    .ADDR_WIDTH(21), .IMAGE_WORDS(307200), .FIFO_DEPTH(512), .FIFO_MARGIN(8),
    .BURST_SIZE(128), .BURST_GAP_CYCLES(12), .MAX_INFLIGHT_BURSTS(2)
) u_reader (
    .mem_clk(ext_mem_clk), .mem_rst_n(mem_rst_n),
    .controller_init_done(Sdr_init_done), .controller_busy(Sdr_busy),
    .refresh_active(Sdr_init_ref_vld), .write_request_busy(write_request_busy),
    .read_request_busy(read_request_busy),
    .app_rd_en(App_rd_en), .app_rd_addr(App_rd_addr),
    .sdram_rd_valid(Sdr_rd_en), .sdram_rd_data(Sdr_rd_dout),
    .pix_clk(video_clk), .pix_rst_n(video_rst_n),
    .frame_start(reader_frame_start), .active_index(reader_active_index),
    .pixel_x(raw_x), .pixel_y(raw_y),
    .request_valid(request_valid), .request_x(request_x), .request_y(request_y),
    .coordinate_valid(mapped_de), .source_index(mapped_index),
    .source_x(mapped_x),
    .source_y(mapped_source_y),
    .source_stride(mapped_stride),
    .focus_border(display_mode==0 && layout_focus_border),
    .pixel_consume(reader_pixel_consume), .pixel_rgb(reader_pixel_rgb),
    .pixel_valid(reader_pixel_valid), .underflow(reader_underflow),
    .reader_busy(), .frame_read_done(), .reader_index(), .reader_error(reader_memory_error)
);
media_player_control #(
    .DEFAULT_PERIOD_CYCLES(32'd200000000),
    .MIN_PERIOD_CYCLES(32'd25000000),
    .MAX_PERIOD_CYCLES(32'd1500000000)
) u_control (
    .sys_clk(sd_card_clk), .sys_rst_n(sdcard_rst_n),
    .next_event(fade_next_event), .manual_next_mode(key1_next_mode),
    .navigation_lock(key_lock_sd),
    .auto_normal_only(sw3_sync2),
    .prev_event(key_prev_press), .toggle_auto_event(key_auto_press),
    .period_cfg_valid(1'b0), .period_cfg_cycles(32'd0),
    .auto_cfg_valid(1'b0), .auto_cfg_enabled(1'b0),
    .image_complete(complete_sd2), .auto_enabled(ctrl_auto_enabled),
    .active_period_cycles(), .pending_index(ctrl_pending_index),
    .control_error(ctrl_control_error), .request_busy(),
    .pix_clk(video_clk), .pix_rst_n(video_rst_n),
    .frame_start(reader_frame_start), .active_index(reader_active_index),
    .index_commit(ctrl_index_commit)
);

param_menu_controller #(
    .CLKS_PER_MS(50000),
    .DEBOUNCE_MS(20),
    .LONG_HOLD_MS(1000)
) u_param_menu_controller (
    .clk              (sd_card_clk),
    .rst_n            (sdcard_rst_n),
    .key4_n           (key4),
    .sw1              (sw1),
    .sw2              (sw2),
    .service_ready    (cfg_service_ready),
    .input_inhibit    (image6_active_sd),
    .live_volume      (8'd255),
    .live_period_ms   (32'd5000),
    .cfg_update_valid (cfg_update_valid_sd),
    .cfg_period_ms    (),
    .cfg_volume       (cfg_volume_sd),
    .cfg_brightness   (cfg_brightness_sd),
    .cfg_contrast     (cfg_contrast_sd),
    .menu_event       (),
    .menu_kind        (),
    .menu_level       ()
);
// Reuse the established 640x480 timing, including line_active for HDMI audio.
// DE remains the fixed active rectangle; FIFO underflow produces black RGB.
color_bar u_timing (
    .clk(video_clk), .rst(~video_rst_n),
    .hs(raw_hs), .vs(raw_vs), .de(raw_de), .line_active(raw_line_active),
    .pixel_x(raw_x), .pixel_y(raw_y),
    .rgb_r(), .rgb_g(), .rgb_b()
);

thumbnail_layout #(.NORMALIZED_MEDIA(1)) u_thumbnail_layout (
    .in_de(request_valid), .pixel_x(request_x), .pixel_y(request_y),
    .focus_index(frame_focus), .image_complete(frame_complete),
    // Full-screen 640x480 uses the direct mapping below.  Keeping this block
    // thumbnail-only removes the generic scaler from the live full-screen
    // SDRAM address path.
    .fullscreen(1'b0), .fullscreen_fit(1'b0),
    .current_width(current_width), .current_height(current_height),
    .image_width0(frame_widths[15:0]), .image_height0(frame_heights[15:0]),
    .image_width1(frame_widths[31:16]), .image_height1(frame_heights[31:16]),
    .image_width2(frame_widths[47:32]), .image_height2(frame_heights[47:32]),
    .image_width3(frame_widths[63:48]), .image_height3(frame_heights[63:48]),
    .image_width4(frame_widths[79:64]), .image_height4(frame_heights[79:64]),
    .image_width5(frame_widths[95:80]), .image_height5(frame_heights[95:80]),
    .thumb_de(layout_de), .source_index(layout_source_index),
    .source_x(layout_source_x), .source_y(layout_source_y), .focus_border(layout_focus_border)
);
// Every TF-card image in this project is normalized to 640x480.  Full-screen
// display therefore uses direct coordinates, avoiding the long scaler path
// that could occasionally form a wrong SDRAM address after the FPGA warmed.
assign mapped_index = display_mode!=0 ? frame_focus : layout_source_index;
assign mapped_x = display_mode!=0 ? {4'd0,request_x} : layout_source_x;
assign mapped_y = display_mode!=0 ? {4'd0,request_y} : layout_source_y;
assign mapped_stride = display_mode!=0 ? 16'd640 :
                       frame_widths[mapped_index*16 +: 16];
assign mapped_source_y = frame_flips[mapped_index] ?
    (display_mode!=0 || frame_heights[mapped_index*16 +: 16] == 16'd480 ?
     16'd479 - mapped_y :
     frame_heights[mapped_index*16 +: 16] - 16'd1 - mapped_y) : mapped_y;
assign mapped_de = display_mode!=0 ? request_valid && frame_complete[frame_focus] &&
    request_x<current_width && request_y<current_height : layout_de;

wire [15:0] fade_r = reader_pixel_rgb[23:16] * fade_alpha;
wire [15:0] fade_g = reader_pixel_rgb[15:8]  * fade_alpha;
wire [15:0] fade_b = reader_pixel_rgb[7:0]   * fade_alpha;

wire [23:0] faded_pixel = fade_alpha == 8'd255 ?
      reader_pixel_rgb : {fade_r[15:8], fade_g[15:8], fade_b[15:8]};

assign reader_frame_start = raw_vs_q && !raw_vs;
assign reader_pixel_consume = raw_de;
assign rgb_q = reader_pixel_valid ? (display_mode==0 ? reader_pixel_rgb : faded_pixel) : 24'd0;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        raw_vs_q <= 1; hs_q <= 1; vs_q <= 1; de_q <= 0; line_q <= 0;
        complete_pix1 <= 0; complete_pix2 <= 0; display_valid <= 0;
        media_id_pix1 <= 0; media_id_pix2 <= 0;
    end else begin
        raw_vs_q <= raw_vs;
        complete_pix1 <= loader_image_complete; complete_pix2 <= complete_pix1;
        if (frame_capture) display_valid <= complete_pix2[reader_active_index];
        hs_q <= raw_hs; vs_q <= raw_vs; de_q <= raw_de; line_q <= raw_line_active;
        media_id_pix1 <= reader_active_index; media_id_pix2 <= media_id_pix1;
    end
end
wire [9:0] wipe_boundary = wipe_ramp * 10'd40;
wire show_new = reader_video_x < wipe_boundary;

wire [23:0] transition_rgb = wipe_active && display_mode!=0 ?
      (show_new ? rgb_q : 24'd0) : rgb_q;
wire [23:0] adjusted_rgb;
wire adjusted_de;

brightness_contrast_adjust u_brightness_contrast_adjust (
    .clk       (video_clk),
    .rst_n     (video_rst_n),
    .rgb_in    (transition_rgb),
    .in_de     (de_q),
    .in_hsync  (hs_q),
    .in_vsync  (vs_q),
    .in_line_active(line_q),
    .in_pixel_x(reader_video_x),
    .brightness(active_brightness_pix),
    .contrast  (active_contrast_pix),
    .rgb_out   (adjusted_rgb),
    .out_de    (adjusted_de),
    .out_hsync (hs),
    .out_vsync (vs),
    .out_line_active(line_active),
    .out_pixel_x(video_x)
);

assign vout_data_raw = adjusted_rgb;
assign de = adjusted_de;

dynamic_text_overlay u_dynamic_text (
    .clk(video_clk), .rst_n(video_rst_n), .vsync(vs), .de(de),
    .pixel_x(video_x), .rgb_in(osd_rgb_out),
    .active_index(reader_active_index), .auto_enabled(osd_auto_pix2),
    .rgb_out(text_rgb_out)
);

promax_audio_waveform u_audio_waveform (
    .clk             (video_clk),
    .rst_n           (video_rst_n),
    .vsync           (vs),
    .de              (de),
    .rgb_in          (text_rgb_out),
    .pixel_x         (video_x),
    .enable          (waveform_enable),
    .pcm_tap_valid   (pcm_tap_valid),
    .pcm_tap_left    (pcm_tap_left),
    .rgb_out         (vout_data),
    .waveform_active (waveform_active)
);
assign startup_gated_video = startup_av_ready ? vout_data : 24'd0;
seg_decoder seg_decoder_m0 (
    .bin_data({1'b0,media_id_sd}+4'd1), .seg_data(seg_data_0)
);
seg_scan seg_scan_m0 (
    .clk(clk), .rst_n(rst_n), .seg_sel(seg_sel), .seg_data(seg_data),
    .seg_data_0(8'hff), .seg_data_1(8'hff), .seg_data_2(8'hff),
    .seg_data_3(8'hff), .seg_data_4(8'hff),
    .seg_data_5(complete_sd2[media_id_sd] ? {1'b1,seg_data_0} : 8'hff)
);
hdmi_video_position u_video_position (
    .clk(video_clk), .rst_n(video_rst_n), .hsync(hs_q), .de(de_q), .x(reader_video_x)
);
sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (~mem_rst_n),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

media_hdmi_audio_bridge u_audio_bridge (
    .pixel_clk          (video_clk),
    .pixel_rst_n        (video_rst_n),
    .video_hsync        (hs),
    .video_vsync        (vs),
    .video_de           (de),
    .video_line_active  (line_active),
    .video_x            (video_x),
    .video_rgb          (startup_gated_video),
    .media_id           (media_id_pix2),
    .volume             (active_volume_pix),
    // Keep audio level independent of the visual transition alpha.
    .fade_gain          (8'd255),
    .audio_source_mode  (selected_audio_source_mode),
    .wav_active         (wav_stream_active && startup_av_ready),
    .wav_valid          (wav_pcm_valid),
    .wav_ready          (wav_pcm_ready),
    .wav_left           (wav_pcm_left),
    .wav_right          (wav_pcm_right),
    .clock_symbol       (tmds_clk_data),
    .ddc_scl            (HDMI_DDC_SCL),
    .ddc_sda            (HDMI_DDC_SDA),
    .channel0_symbol    (tmds_ch0_data),
    .channel1_symbol    (tmds_ch1_data),
    .channel2_symbol    (tmds_ch2_data),
    .sequence_error     (),
    .tone_overflow      (),
    .pcm_contract_error (),
    .blip_active        (),
    .pcm_tap_valid      (audio_probe_valid),
    .pcm_tap_left       (audio_probe_left)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (~video_rst_n),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
