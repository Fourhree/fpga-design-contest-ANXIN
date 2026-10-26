`timescale 1ns/1ps

// Real player, card controller and SPI pins. Card loses its initialization
// when removed; reads are accepted again only after CMD0/ACMD41/CMD16.
module tb_tf_reinsert;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, key_next = 1, finish_toggle = 0;
    reg present = 1, card_ready = 0, miso = 1;
    wire cs, sclk, mosi, display_valid, write_req, write_en;
    wire [1:0] media_id, disp_buf;
    reg test_pass = 0;
    integer bit_index = 0, byte_index = 0, command = 0, reply_index = 0;
    integer init_commands = 0, pixels = 0, finish_delay = 0;
    reg [31:0] sector_address = 0;
    reg [7:0] receive_byte = 0, reply_byte = 8'hff;
    reg [1:0] saved_buf;

    sd_card_bmp #(.CLK_FREQ_HZ(100000), .SCAN_MAX_SECTOR(3)) dut (
        .clk(clk), .rst(rst), .Sdr_init_done(1'b1), .key_next(key_next), .key_auto(1'b1),
        .bmp_width(16'd2), .bmp_height(16'd2),
        .display_valid(display_valid), .media_id(media_id), .state_code(),
        .write_finish_toggle(finish_toggle), .write_buf_idx(), .disp_buf_idx(disp_buf),
        .write_req(write_req), .write_req_ack(write_req), .write_en(write_en), .write_data(),
        .SD_nCS(cs), .SD_DCLK(sclk), .SD_MOSI(mosi), .SD_MISO(miso)
    );
    defparam dut.sd_card_top_m0.SPI_LOW_SPEED_DIV = 0;

    function [7:0] picture_byte(input integer offset);
        case (offset)
            0: picture_byte = "B";
            1: picture_byte = "M";
            2: picture_byte = 66;
            10: picture_byte = 54;
            14: picture_byte = 40;
            18,22: picture_byte = 2;
            26: picture_byte = 1;
            28: picture_byte = 24;
            default: picture_byte = (offset >= 54 && offset < 66) ? sector_address + 1 : 0;
        endcase
    endfunction

    always @(posedge cs or negedge present) begin
        bit_index = 0; byte_index = 0; reply_index = 0;
        reply_byte = 8'hff; miso = 1;
        if (!present) card_ready = 0;
    end
    always @(negedge sclk)
        if (!cs) miso = present ? reply_byte[7-bit_index] : 1'b1;

    always @(posedge sclk) begin
        if (!cs && present) begin
            receive_byte = {receive_byte[6:0], mosi};
            if (bit_index == 7) begin
                bit_index = 0;
                // Wait for a command start after power is restored mid-CS.
                if (byte_index != 0 || receive_byte[7:6] == 2'b01) begin
                    if (byte_index == 0) begin
                        command = receive_byte & 8'h3f;
                        sector_address = 0;
                    end else if (byte_index <= 4)
                        sector_address = {sector_address[23:0], receive_byte};
                    byte_index = byte_index + 1;
                    if (byte_index == 6) begin
                        case (command)
                            0: begin reply_byte = 1; card_ready = 0; init_commands = init_commands + 1; end
                            8,55: reply_byte = 1;
                            16: begin reply_byte = 0; card_ready = 1; end
                            17: reply_byte = card_ready ? 0 : 1;
                            default: reply_byte = 0;
                        endcase
                        reply_index = 0;
                    end else if (byte_index > 6) begin
                        reply_index = reply_index + 1;
                        if (command == 8 && reply_index <= 4)
                            reply_byte = reply_index == 4 ? 8'haa : 0;
                        else if (command == 17 && card_ready) begin
                            if (reply_index == 1) reply_byte = 8'hfe;
                            else if (reply_index >= 2 && reply_index < 514)
                                reply_byte = picture_byte(reply_index - 2);
                            else reply_byte = 8'hff;
                        end else reply_byte = 8'hff;
                    end
                end
            end else bit_index = bit_index + 1;
        end
    end

    always @(posedge clk) begin
        if (rst || dut.sd_local_reset || write_req) begin
            pixels <= 0; finish_delay <= 0;
        end else begin
            if (write_en) begin
                pixels <= pixels + 1;
                if (pixels == 3) finish_delay <= 100;
            end
            if (finish_delay > 0) begin
                finish_delay <= finish_delay - 1;
                if (finish_delay == 1) finish_toggle <= ~finish_toggle;
            end
        end
    end

    task next_key;
        begin
            key_next = 0;
            repeat (5100) @(negedge clk);
            key_next = 1;
            repeat (5100) @(negedge clk);
        end
    endtask

    task await_picture(input [1:0] expected);
        integer count;
        begin
            count = 0;
            while ((!display_valid || media_id != expected || dut.load_busy) && count < 4000000) begin
                @(negedge clk); count = count + 1;
            end
            if (count == 4000000) $fatal(1, "picture %0d did not recover", expected);
        end
    endtask

    initial begin
        repeat (5) @(negedge clk); rst = 0;
        await_picture(0);
        saved_buf = disp_buf;
        next_key;
        // Remove after the header, before the next CMD17/pixel transfer.
        wait (dut.bmp_read_m0.state == 4);
        @(negedge clk); present = 0;
        wait (dut.sd_recovering);
        if (dut.last_bmp_error != 2) $fatal(1, "removal did not report timeout");
        repeat (200) @(negedge clk);
        if (!display_valid || media_id != 0 || disp_buf != saved_buf || dut.img_found_count != 4 || !dut.scan_done)
            $fatal(1, "local reinit destroyed catalog/frame");
        present = 1;
        await_picture(1);
        if (init_commands < 2) $fatal(1, "card was not initialized again");

        // Stay absent longer than the bounded init wait, then press KEY1.
        saved_buf = disp_buf;
        present = 0;
        next_key;
        wait (dut.sd_recovering);
        wait (!dut.sd_recovering);
        if (dut.load_busy || !display_valid || media_id != 1 || disp_buf != saved_buf)
            $fatal(1, "absent card kept busy or cleared frame");
        next_key;
        if (!dut.next_req_pending) $fatal(1, "key during reinit was not remembered");
        present = 1;
        await_picture(3);
        if (init_commands < 3) $fatal(1, "late insertion did not reinitialize");
        next_key; await_picture(0);
        $display("PASS: real SPI card power loss, reinit/retry, bounded missing-card wait, queued KEY1 and preserved picture/catalog");
        test_pass = 1;
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1, "TF reinsertion test watchdog");
    end
endmodule
