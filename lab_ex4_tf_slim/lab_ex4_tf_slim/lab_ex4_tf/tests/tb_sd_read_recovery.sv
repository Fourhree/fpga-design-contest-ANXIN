`timescale 1ns/1ps

// Exercise initialization, CMD17 and missing-token recovery through the
// real SPI pins. No forced internal state or fabricated sector-end pulse.
module tb_sd_read_recovery;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg read_req = 0;
    reg [31:0] address = 0;
    reg miso = 1;
    wire cs, sclk, mosi, initialized, valid, ended, failed;
    wire [7:0] data;
    reg test_pass = 0;
    integer mode = 0; // 0: no token, 1: valid sector, 2: CMD17 error
    integer bit_index = 0, byte_index = 0, command = 0;
    integer reply_index = 0, payload_count = 0;
    reg [7:0] receive_byte = 0, reply_byte = 8'hff;

    sd_card_top #(.SPI_LOW_SPEED_DIV(0)) dut (
        .clk(clk), .rst(rst), .SD_nCS(cs), .SD_DCLK(sclk),
        .SD_MOSI(mosi), .SD_MISO(miso), .sd_init_done(initialized),
        .sd_sec_read(read_req), .sd_sec_read_addr(address),
        .sd_sec_read_data(data), .sd_sec_read_data_valid(valid),
        .sd_sec_read_end(ended), .sd_sec_read_error(failed),
        .sd_sec_write(1'b0), .sd_sec_write_addr(32'd0),
        .sd_sec_write_data(8'd0), .sd_sec_write_data_req(), .sd_sec_write_end()
    );
    defparam dut.sd_card_cmd_m0.READ_TOKEN_TIMEOUT_BYTES = 16;

    always @(posedge cs) begin
        bit_index = 0;
        byte_index = 0;
        reply_index = 0;
        reply_byte = 8'hff;
        miso = 1;
    end
    // SPI mode 3: change MISO on falling edges, sample MOSI on rising.
    always @(negedge sclk)
        if (!cs) miso = reply_byte[7-bit_index];

    always @(posedge sclk) begin
        if (!cs) begin
            receive_byte = {receive_byte[6:0], mosi};
            if (bit_index == 7) begin
                bit_index = 0;
                if (byte_index == 0) command = receive_byte & 8'h3f;
                byte_index = byte_index + 1;
                if (byte_index == 6) begin
                    case (command)
                        0, 8, 55: reply_byte = 8'h01;
                        17: reply_byte = mode == 2 ? 8'h04 : 8'h00;
                        default: reply_byte = 8'h00;
                    endcase
                    reply_index = 0;
                end else if (byte_index > 6) begin
                    reply_index = reply_index + 1;
                    if (command == 8 && reply_index <= 4)
                        reply_byte = reply_index == 4 ? 8'haa : 8'h00;
                    else if (command == 17 && mode == 1) begin
                        if (reply_index == 1) reply_byte = 8'hfe;
                        else if (reply_index >= 2 && reply_index < 514)
                            reply_byte = (reply_index - 2) & 8'hff;
                        else reply_byte = 8'hff;
                    end else reply_byte = 8'hff;
                end
            end else bit_index = bit_index + 1;
        end
    end

    always @(posedge clk) begin
        if (valid) begin
            if (mode != 1 || data !== (payload_count & 8'hff))
                $fatal(1, "unexpected SD payload byte %0d: %h", payload_count, data);
            payload_count = payload_count + 1;
        end
    end

    task read_sector;
        input integer card_mode;
        integer count;
        begin
            mode = card_mode;
            payload_count = 0;
            address = address + 1;
            read_req = 1;
            count = 0;
            while (!ended && count < 30000) begin
                @(negedge clk);
                count = count + 1;
            end
            if (!ended) $fatal(1, "SD transaction remained stuck, mode %0d", mode);
            if (mode == 1) begin
                if (failed || payload_count != 512)
                    $fatal(1, "valid sector failed: error=%b bytes=%0d", failed, payload_count);
            end else if (!failed || payload_count != 0)
                $fatal(1, "failed read was not reported");
            read_req = 0;
            repeat (10) @(negedge clk);
        end
    endtask

    initial begin
        repeat (5) @(negedge clk);
        rst = 0;
        wait (initialized);
        repeat (100) @(negedge clk);
        read_sector(0);
        read_sector(1);
        read_sector(2);
        read_sector(1);
        $display("PASS: real SPI initialization, missing-token timeout, CMD17 error and subsequent sector recovery");
        test_pass = 1;
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "SD test watchdog");
    end
endmodule
