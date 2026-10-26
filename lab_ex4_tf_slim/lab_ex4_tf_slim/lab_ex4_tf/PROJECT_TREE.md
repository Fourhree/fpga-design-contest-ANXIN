# 最小工程文件树

以下仅保留 **TD 6.2 打开工程并重新综合、布局布线所需的文件**。清单依据
`src/td_project/lab_ex5_i2s_v1.0.al` 中当前未标记为 `AutoExcluded` 的输入整理；
IP 同时保留配置文件（`.ipc`）及启用的 Verilog 生成文件（`.v`）。

```text
lab_ex4_tf/
└── src/
    ├── media_frame_loader.v
    ├── media_frame_reader.v
    ├── media_player_control.v
    ├── td_project/
    │   └── lab_ex5_i2s_v1.0.al
    └── user_source/
        ├── constraints_source/
        │   ├── pin.adc
        │   └── timing.sdc
        └── hdl_source/
            ├── audio_source_mux.v
            ├── brightness_contrast_adjust.v
            ├── dynamic_text_overlay.v
            ├── hdmi_audio_acr_packetizer.v
            ├── hdmi_audio_infoframe_packetizer.v
            ├── hdmi_audio_packet_scheduler.v
            ├── hdmi_audio_sample_packetizer.v
            ├── hdmi_audio_symbol_core.v
            ├── hdmi_avi_infoframe_packetizer.v
            ├── hdmi_bch8.v
            ├── hdmi_data_island_mapper.v
            ├── hdmi_data_island_scheduler.v
            ├── hdmi_phy_warpper.v
            ├── hdmi_terc4_encoder.v
            ├── hdmi_tmds_channel_encoder.v
            ├── lane_lvds_10_1.v
            ├── m06_pcm_contract_adapter.v
            ├── media_hdmi_audio_bridge.v
            ├── osd_overlay_24.v
            ├── param_config_service.v
            ├── param_menu_controller.v
            ├── pcm_gain_scale.v
            ├── pcm_media_tone.v
            ├── promax_audio_waveform.v
            ├── reset_sync.v
            ├── status_osd_overlay.v
            ├── sync_2ff.v
            ├── thumbnail_layout.v
            ├── timestamp_osd.v
            ├── top_tf_hdmi_audio.v
            ├── video_fade_transition.v
            ├── wav_stream_player.v
            ├── include/
            │   ├── sdr_as_ram.enc.v
            │   ├── sdr_init_ref.enc.v
            │   └── sdr_wrrd.enc.v
            ├── IP/
            │   ├── afifo_16_32_256.ipc
            │   ├── afifo_16_32_256.v
            │   ├── afifo_32_16_256.ipc
            │   ├── afifo_32_16_256.v
            │   ├── sys_pll.ipc
            │   ├── sys_pll.v
            │   ├── video_pll.ipc
            │   └── video_pll.v
            └── SD/
                ├── bmp_fat_reader.v
                ├── bmp_stream_stretch.v
                ├── color_bar.v
                ├── fat32_file_streamer.v
                ├── fat32_volume_scanner.v
                ├── fifo_prefetch_2.v
                ├── media_pixel_cdc.v
                ├── sd_card_bmp.v
                ├── sd_card_cmd.v
                ├── sd_card_sec_read_write.v
                ├── sd_card_top.v
                ├── sd_sector_adapter.v
                ├── sdram.v
                ├── sdram_refresh_scheduler.v
                ├── seg_decoder.v
                ├── seg_scan.v
                └── spi_master.v
```

## 必要入口

- 工程文件：`src/td_project/lab_ex5_i2s_v1.0.al`
- 顶层模块：`src/user_source/hdl_source/top_tf_hdmi_audio.v`
- 引脚约束：`src/user_source/constraints_source/pin.adc`
- 时序约束：`src/user_source/constraints_source/timing.sdc`

## 未列入的内容

以下内容不是重新构建工程的必需输入，因此不出现在上面的最小文件树中：

- `src/td_project/lab_ex5_i2s_v1.0_Runs/`、`log/`：可重新生成的构建产物和日志。
- `tests/`：验证工程所需，但不是生成正式 bitstream 的必要输入。
- `doc/`、根目录说明文档和 TF 卡媒体：使用资料或运行素材，不参与 FPGA 构建。
- `.recent_user_depot.ini`、`.cwc`、备份文件：本机状态或调试文件。
- `.vhd`、仿真模型、旧 IP、重复 RTL：当前工程未启用。
- `.al` 中标记为 `AutoExcluded` 的 20 个条目：当前不会进入综合。

> 说明：此处的“必需”专指 **从源文件重新生成 bitstream**。如果只需要直接烧录，
> 还需单独保留已生成的 `.bit` 文件；如果需要回归验证，则应保留 `tests/`。
