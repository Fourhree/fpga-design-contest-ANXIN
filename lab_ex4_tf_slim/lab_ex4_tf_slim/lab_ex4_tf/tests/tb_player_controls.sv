`timescale 1ns/1ps

// Exercise the real player and BMP reader. Replace only the SPI card's
// sector interface and the SDRAM completion signal with deterministic models.
module tb_player_controls;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg key_next = 1;
    reg key_auto = 1;
    reg write_finish_toggle = 0;
    wire write_req, write_en, display_valid;
    wire [1:0] media_id;
    reg card_valid = 0;
    reg card_end = 0;
    reg card_error = 0;
    reg [7:0] card_data = 0;
    reg fail_load = 0;
    reg [3:0] bad_header = 0, fail_once = 0, truncated = 0;
    reg header_bad;
    integer transfer_bytes;
    integer load_attempts [0:3];
    integer prior_attempts;
    reg [1:0] saved_buffer;
    reg test_pass = 0;
    integer committed = 0;
    reg [1:0] last_id = 0;
    integer pixels = 0;
    integer finish_delay = 0;
    integer sector_byte;
    reg [31:0] card_address;

    sd_card_bmp #(
        .CLK_FREQ_HZ(1000), .SCAN_MAX_SECTOR(3),
        .LONG_PRESS_MS(1000), .AUTO_PLAY_MS(3000)
    ) dut (
        .clk(clk), .rst(rst), .Sdr_init_done(1'b1), .key_next(key_next), .key_auto(key_auto),
        .bmp_width(16'd2), .bmp_height(16'd2),
        .display_valid(display_valid), .media_id(media_id),
        .write_finish_toggle(write_finish_toggle),
        .write_req(write_req), .write_req_ack(write_req), .write_en(write_en),
        .SD_MISO(1'b1), .state_code(), .write_buf_idx(), .disp_buf_idx(),
        .write_data(), .SD_nCS(), .SD_DCLK(), .SD_MOSI()
    );

    // At the accelerated 1 kHz clock, the card model takes 512 ms/sector.
    // Hardware keeps the reader's default 500 ms timeout.
    defparam dut.bmp_read_m0.SD_READ_TIMEOUT_MS = 1000;

    function [7:0] sector_data;
        input integer offset;
        input [31:0] address;
        begin
            case (offset)
                0: sector_data = "B";
                1: sector_data = "M";
                2: sector_data = 66;
                10: sector_data = 54;
                14: sector_data = 40;
                18, 22: sector_data = 2;
                26: sector_data = 1;
                28: sector_data = header_bad ? 16 : 24;
                default: sector_data = (offset >= 54 && offset < 66) ? address + 1 : 0;
            endcase
        end
    endfunction

    initial begin
        force dut.sd_init_done = 1'b1;
        force dut.sd_sec_read_data_valid = card_valid;
        force dut.sd_sec_read_data = card_data;
        force dut.sd_sec_read_end = card_end;
        force dut.sd_sec_read_error = card_error;
        forever begin
            @(negedge clk);
            if (!rst && dut.sd_sec_read && !fail_load) begin
                card_address = dut.sd_sec_read_addr;
                header_bad = (dut.bmp_read_m0.state == 2) &&
                             (bad_header[card_address] || fail_once[card_address]);
                if (dut.bmp_read_m0.state == 2) fail_once[card_address] = 0;
                transfer_bytes = ((dut.bmp_read_m0.state == 4) && truncated[card_address]) ? 65 : 512;
                for (sector_byte = 0; sector_byte < transfer_bytes; sector_byte = sector_byte + 1) begin
                    card_data = sector_data(sector_byte, card_address);
                    card_valid = 1;
                    @(negedge clk);
                end
                card_valid = 0;
                card_end = 1;
                @(negedge clk);
                card_end = 0;
                @(negedge clk);
            end
        end
    end

    always @(posedge clk) begin
        if (dut.load_start_pulse)
            load_attempts[dut.load_idx] <= load_attempts[dut.load_idx] + 1;
        if (rst || dut.load_abort) begin
            pixels <= 0;
            finish_delay <= 0;
        end else begin
            if (write_req) pixels <= 0;
            if (write_en) begin
                pixels <= pixels + 1;
                if (pixels == 3) finish_delay <= 600;
            end
            if (finish_delay > 0) begin
                finish_delay <= finish_delay - 1;
                if (finish_delay == 1) write_finish_toggle <= ~write_finish_toggle;
            end
            if (display_valid && media_id != last_id) begin
                committed <= committed + 1;
                last_id <= media_id;
            end
        end
    end

    task cycles;
        input integer count;
        repeat (count) @(negedge clk);
    endtask

    task await_idle;
        integer count;
        begin
            count = 0;
            while ((!display_valid || dut.load_busy || !dut.bmp_ready) && count < 10000) begin
                cycles(1);
                count = count + 1;
            end
            if (count == 10000) $fatal(1, "player did not become idle");
        end
    endtask

    task short_key2;
        begin
            key_auto = 0;
            cycles(80);
            key_auto = 1;
            cycles(60);
        end
    endtask

    task next_picture;
        begin
            key_next = 0; cycles(80);
            key_next = 1; cycles(60);
        end
    endtask

    task await_failed;
        integer count;
        begin
            count = 0;
            while ((dut.load_busy || !dut.load_failed || !dut.bmp_ready) && count < 10000) begin
                cycles(1); count = count + 1;
            end
            if (count == 10000) $fatal(1, "failed picture was not released");
            if (dut.disp_buf_idx != saved_buffer) $fatal(1, "failure changed visible buffer");
        end
    endtask

    initial begin
        load_attempts[0] = 0; load_attempts[1] = 0;
        load_attempts[2] = 0; load_attempts[3] = 0;
        cycles(5);
        rst = 0;
        await_idle;
        if (dut.img_found_count != 4 || media_id != 0) $fatal(1, "initial scan/load");
        short_key2;
        if (!dut.auto_play_en) $fatal(1, "KEY2 short press did not enable slideshow");
        cycles(4800);
        await_idle;
        if (media_id != 1) $fatal(1, "slideshow did not advance");
        short_key2;
        if (dut.auto_play_en) $fatal(1, "KEY2 short press did not disable slideshow");
        key_auto = 0;
        cycles(3000);
        await_idle;
        if (media_id != 0) $fatal(1, "KEY2 long press or held-key repeat");
        key_auto = 1;
        cycles(60);
        if (dut.auto_play_en) $fatal(1, "long press release toggled slideshow");
        key_auto = 0;
        cycles(1100);
        key_auto = 1;
        cycles(60);
        await_idle;
        if (media_id != 3) $fatal(1, "previous image did not wrap");

        // A failed picture must preserve the scanned catalog and current image.
        fail_load = 1;
        key_next = 0;
        cycles(80);
        key_next = 1;
        cycles(60);
        if (!dut.load_busy) $fatal(1, "failed load was not started");
        force dut.load_timeout_cnt = 32'hffffffff;
        cycles(1);
        release dut.load_timeout_cnt;
        cycles(5);
        if (!dut.scan_done || dut.img_found_count != 4 || media_id != 3)
            $fatal(1, "load abort destroyed catalog or visible image");
        // Finish the already requested sector so the reader can drain it.
        card_end = 1;
        cycles(1);
        card_end = 0;
        fail_load = 0;
        cycles(5);
        short_key2;
        if (!dut.auto_play_en) $fatal(1, "KEY2 still blocked after timeout");
        short_key2;
        key_auto = 0;
        cycles(1100);
        key_auto = 1;
        cycles(60);
        await_idle;
        if (media_id != 2) $fatal(1, "previous image blocked after timeout");
        // A failed FIRST picture must not repeatedly swallow both keys.
        rst = 1;
        cycles(5);
        rst = 0;
        wait (dut.load_busy);
        @(negedge clk);
        // Finish supplying the header, but do not signal SDRAM completion.
        force finish_delay = 0;
        cycles(1500);
        force dut.load_timeout_cnt = 32'hffffffff;
        cycles(1);
        release dut.load_timeout_cnt;
        cycles(10);
        release finish_delay;
        if (dut.load_busy || !dut.scan_done || display_valid)
            $fatal(1, "failed first image retried forever");
        key_next = 0;
        cycles(80);
        key_next = 1;
        cycles(60);
        await_idle;
        if (media_id != 1) $fatal(1, "KEY1 could not skip failed first image");
        key_auto = 0;
        cycles(1100);
        key_auto = 1;
        cycles(60);
        await_idle;
        if (media_id != 0) $fatal(1, "KEY2 failed after first-image recovery");

        saved_buffer = dut.disp_buf_idx;
        bad_header[1] = 1;
        prior_attempts = load_attempts[1];
        next_picture; await_failed;
        if (media_id != 0 || load_attempts[1] != prior_attempts + 2 || dut.retry_count != 1)
            $fatal(1, "bad header did not retry exactly once and preserve old frame");
        cycles(20);
        if (dut.state_code != 4'he || !dut.load_error_seen)
            $fatal(1, "failed load status was not retained");
        next_picture; await_idle;
        if (media_id != 2) $fatal(1, "manual next did not skip failed picture");

        fail_once[3] = 1;
        prior_attempts = load_attempts[3];
        next_picture; await_idle;
        if (media_id != 3 || load_attempts[3] != prior_attempts + 2 || dut.retry_count != 0)
            $fatal(1, "transient header error did not recover and clear retry budget");

        truncated[0] = 1;
        saved_buffer = dut.disp_buf_idx;
        prior_attempts = load_attempts[0];
        next_picture; await_failed;
        if (media_id != 3 || dut.bmp_error != 3 || load_attempts[0] != prior_attempts + 2)
            $fatal(1, "truncated frame did not retry once and preserve display");

        // Enable auto while a previously failed picture remains undisplayed.
        bad_header = 4'b0100;
        short_key2;
        wait (media_id == 1);
        saved_buffer = dut.disp_buf_idx;
        prior_attempts = load_attempts[2];
        wait (dut.load_idx == 2 && dut.load_busy);
        wait (dut.load_idx == 3 && dut.load_busy);
        if (media_id != 1 || dut.disp_buf_idx != saved_buffer || load_attempts[2] != prior_attempts + 2)
            $fatal(1, "auto did not skip bad image after one retry and preserve frame");
        await_idle;
        if (media_id != 3 || dut.retry_count != 0) $fatal(1, "auto skip did not commit next good image");
        short_key2;

        // Both attempts time out in the reader, without waiting for the outer timer.
        fail_load = 1;
        saved_buffer = dut.disp_buf_idx;
        prior_attempts = load_attempts[0];
        next_picture;
        force dut.bmp_read_m0.sd_timeout_cnt = 1000;
        await_failed;
        release dut.bmp_read_m0.sd_timeout_cnt;
        if (media_id != 3 || dut.bmp_error != 2 || load_attempts[0] != prior_attempts + 2)
            $fatal(1, "reader timeout did not retry once and retain display");

        // A bad first header also exhausts only one retry and releases the keys.
        rst = 1; cycles(5);
        fail_load = 0; bad_header = 4'b0001; truncated = 0;
        prior_attempts = load_attempts[0];
        rst = 0;
        wait (dut.load_busy);
        saved_buffer = dut.disp_buf_idx;
        await_failed;
        if (display_valid || load_attempts[0] != prior_attempts + 2)
            $fatal(1, "bad first header retried forever or displayed incomplete buffer");
        next_picture; await_idle;
        if (media_id != 1) $fatal(1, "manual skip blocked after bad first header");

        $display("PASS: player controls, header/timeout/truncation retry, manual/auto bad-image skip and previous-frame retention");
        test_pass = 1;
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "test watchdog");
    end
endmodule
