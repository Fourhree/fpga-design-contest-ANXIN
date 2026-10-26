`timescale 1ns/1ps
// Exercise the real SD-source key filters and frame-boundary image controller.
// CLK_FREQ_HZ=1000 gives one simulated clock per millisecond of key timing.
module tb_thumbnail_controls;
    reg clk=0, pix_clk=0, rst=1;
    always #5 clk=~clk;
    always #7 pix_clk=~pix_clk;
    reg key1=1, key2=1, key3=1;
    wire next_event,prev_event,auto_event,mode_event;
    reg test_pass=0;
    sd_card_bmp #(.CLK_FREQ_HZ(1000)) source (
        .clk(clk),.rst(rst),.Sdr_init_done(1'b0),
        .key_next(key1),.key_auto(key2),.key_mode(key3),.bmp_width(16'd0),.bmp_height(16'd0),
        .audio_file_index(3'd0),
        .key_next_press(next_event),.key_prev_press(prev_event),
        .key_auto_press(auto_event),.key_mode_press(mode_event),
        .loader_load_done(1'b0),.loader_memory_error(8'd0),
        .audio_sector_req(1'b0),.audio_sector_lba(32'd0),.SD_MISO(1'b1),
        .state_code(),.loader_load_start(),.loader_image_index(),
        .loader_image_width(),.loader_image_height(),.loader_image_bottom_up(),
        .loader_pixel_valid(),.loader_pixel_rgb(),.loader_frame_commit(),.loader_decode_error(),
        .audio_storage_ready(),.wav_file_valid(),.wav_first_cluster(),.wav_file_size(),
        .wav_start_lba(),.wav_total_sectors(),.fs_sectors_per_cluster(),
        .fs_fat_start_lba(),.fs_data_start_lba(),.fs_max_cluster(),
        .audio_sector_busy(),.audio_sector_valid(),.audio_sector_done(),
        .audio_sector_byte(),.audio_sector_error(),.audio_sector_byte_index(),
        .SD_nCS(),.SD_DCLK(),.SD_MOSI());
    reg frame_start=0;
    integer frame_cycle=0;
    always @(negedge pix_clk) begin
        if(rst) begin frame_start=0; frame_cycle=0; end
        else begin
            frame_start=(frame_cycle==0);
            frame_cycle=(frame_cycle+1)%40;
        end
    end
    wire [2:0] active_index;
    wire auto_enabled,index_commit;
    media_player_control #(.DEFAULT_PERIOD_CYCLES(100000)) player (
        .sys_clk(clk),.sys_rst_n(!rst),.next_event(next_event),
        .manual_next_mode(2'd0),
        .navigation_lock(1'b0),
        .auto_normal_only(1'b0),
        .prev_event(prev_event),.toggle_auto_event(auto_event),
        .period_cfg_valid(1'b0),.period_cfg_cycles(32'd0),
        .auto_cfg_valid(1'b0),.auto_cfg_enabled(1'b0),.image_complete(6'b111111),
        .auto_enabled(auto_enabled),.active_period_cycles(),.pending_index(),
        .control_error(),.request_busy(),.pix_clk(pix_clk),.pix_rst_n(!rst),
        .frame_start(frame_start),.active_index(active_index),.index_commit(index_commit));
    integer next_count=0,prev_count=0,auto_count=0,mode_count=0;
    always @(posedge clk) if(!rst) begin
        if(next_event) next_count=next_count+1;
        if(prev_event) prev_count=prev_count+1;
        if(auto_event) auto_count=auto_count+1;
        if(mode_event) mode_count=mode_count+1;
    end
    reg [2:0] last_index=0;
    always @(posedge pix_clk) begin
        #1;
        if(!rst && active_index!=last_index && (!frame_start || !index_commit))
            $fatal(1,"selected image changed outside a frame boundary");
        last_index=active_index;
    end
    task cycles(input integer n);
        repeat(n) @(negedge clk);
    endtask
    task short_key2;
        begin key2=0; cycles(80); key2=1; cycles(100); end
    endtask
    task short_key3;
        begin
            key3=0; cycles(80); key3=1; cycles(100);
        end
    endtask
    initial begin
        cycles(5); rst=0; cycles(150);
        key2=0; cycles(4); key2=1; cycles(40);
        key1=0; cycles(1); key1=1; cycles(40);
        if(next_count || prev_count || auto_count || mode_count)
            $fatal(1,"short contact bounce generated an event");
        key1=0; cycles(100); key1=1; cycles(100);
        if(next_count!=1 || active_index!=1)
            $fatal(1,"KEY1 must navigate once despite a held press");
        short_key2(); short_key2(); short_key2();
        if(auto_count!=3 || !auto_enabled || mode_count || prev_count || active_index!=1)
            $fatal(1,"three short KEY2 releases must only toggle autoplay");
        key2=0; cycles(2200);
        if(prev_count!=1 || active_index!=0)
            $fatal(1,"long KEY2 must select the previous image exactly once");
        key2=1; cycles(100);
        if(auto_count!=3) $fatal(1,"long-press release also toggled autoplay");
        short_key3();
        if(mode_count!=1 || auto_count!=3 || !auto_enabled || next_count!=1 || prev_count!=1)
            $fatal(1,"KEY3 leaked a navigation or autoplay event");
        short_key3();
        if(mode_count!=2 || auto_count!=3 || !auto_enabled || next_count!=1 || prev_count!=1)
            $fatal(1,"second KEY3 press failed to cycle display mode cleanly");
        // KEY2 no longer modifies KEY1: both retain their independent actions.
        key2=0; cycles(40); key1=0; cycles(30); key1=1; cycles(40);
        key2=1; cycles(100);
        if(mode_count!=2 || auto_count!=4 || next_count!=2 || prev_count!=1)
            $fatal(1,"Removed KEY2+KEY1 chord still affects key actions");
        test_pass=1;
        $display("PASS: short KEY2 autoplay, KEY3 mode, long KEY2 previous, independent KEY1, frame commit");
        $finish;
    end
    initial begin #200000; $fatal(1,"controls test timeout"); end
endmodule
