`timescale 1ns/1ps

module tb_bmp_read_errors;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, scan_start = 0, load_start = 0, abort_load = 0;
    reg data_valid = 0, sector_end = 0, sector_error = 0, write_ack = 0;
    reg [7:0] data = 0;
    reg [31:0] length = 66, offset = 54;
    reg [15:0] width = 2, height = 2, bits = 24;
    reg signature = 1;
    wire ready, scan_done, request, write_req, pixel_wr, load_error;
    wire [2:0] bmp_error;
    wire [31:0] address;
    reg test_pass = 0;
    integer output_pixels = 0;
    integer sectors;

    // 500 ms is 1000 cycles here; a complete sector takes 512 cycles.
    bmp_read #(.CLK_FREQ_HZ(2000)) dut (
        .clk(clk), .rst(rst), .ready(ready),
        .scan_start(scan_start), .scan_start_sector(32'd0),
        .scan_max_sector(32'd8), .scan_target_count(3'd4),
        .scan_done(scan_done), .scan_found_valid(), .scan_found_sector(), .scan_found_total(),
        .load_start(load_start), .load_abort(abort_load), .load_sector(32'd0),
        .bmp_error(bmp_error), .load_error(load_error), .sd_init_done(1'b1), .state_code(),
        .bmp_width(width), .bmp_height(height), .write_req(write_req), .write_req_ack(write_ack),
        .sd_sec_read(request), .sd_sec_read_addr(address), .sd_sec_read_data(data),
        .sd_sec_read_data_valid(data_valid), .sd_sec_read_end(sector_end),
        .sd_sec_read_error(sector_error), .bmp_data_wr_en(pixel_wr), .bmp_data()
    );

    always @(posedge clk)
        if (rst) output_pixels <= 0;
        else if (pixel_wr) output_pixels <= output_pixels + 1;

    function [7:0] header_byte(input integer index);
        case (index)
            0: header_byte = signature ? "B" : 0;
            1: header_byte = signature ? "M" : 0;
            2,3,4,5: header_byte = length >> ((index-2)*8);
            10,11,12,13: header_byte = offset >> ((index-10)*8);
            14: header_byte = 40;
            18,19: header_byte = width >> ((index-18)*8);
            22,23: header_byte = height >> ((index-22)*8);
            26: header_byte = 1;
            28,29: header_byte = bits >> ((index-28)*8);
            default: header_byte = 0;
        endcase
    endfunction

    task reset_reader;
        begin
            rst = 1;
            repeat (3) @(negedge clk);
            rst = 0;
            @(negedge clk);
        end
    endtask

    task start_read(input bit scanning);
        begin
            if (!ready) $fatal(1, "not idle before request");
            scan_start = scanning; load_start = !scanning;
            @(negedge clk);
            scan_start = 0; load_start = 0;
            wait (request);
            @(negedge clk);
        end
    endtask

    task send_sector(input integer bytes, input bit header);
        integer index;
        begin
            for (index = 0; index < bytes; index = index + 1) begin
                data = header ? header_byte(index) : 8'h55;
                data_valid = 1;
                @(negedge clk);
            end
            data_valid = 0; sector_end = 1;
            @(negedge clk);
            sector_end = 0;
        end
    endtask

    task begin_pixels;
        begin
            start_read(0);
            send_sector(512, 1);
            if (!write_req || load_error) $fatal(1, "valid header rejected");
            write_ack = 1;
            @(negedge clk);
            write_ack = 0;
            wait (request);
            @(negedge clk);
        end
    endtask

    task check_error(input [2:0] code);
        begin
            if (!ready || !load_error || bmp_error != code || request)
                $fatal(1, "expected error %0d, got %0d", code, bmp_error);
            @(negedge clk);
            if (load_error || bmp_error != code) $fatal(1, "error must be a pulse with retained code");
        end
    endtask

    task await_timeout;
        integer count;
        begin
            count = 0;
            while (!load_error && count < 1100) begin
                @(negedge clk); count = count + 1;
            end
            if (count == 1100) $fatal(1, "timeout did not fire");
            check_error(2);
        end
    endtask

    initial begin
        reset_reader;
        bits = 16; length = 1536;
        start_read(1); send_sector(512, 1);
        if (address != 3 || scan_done || load_error) $fatal(1, "bad BM file did not skip 3 sectors");
        wait (request); @(negedge clk);
        signature = 0; send_sector(512, 1);
        if (address != 4) $fatal(1, "non-BM sector must skip only one");
        wait (request); @(negedge clk);
        signature = 1; length = 0; send_sector(512, 1);
        if (address != 5) $fatal(1, "zero length must still make scan progress");
        wait (request); @(negedge clk);
        length = 32'hffffffff; send_sector(512, 1);
        if (!scan_done || !ready || dut.file_sector_count != 32'd8388608)
            $fatal(1, "large bad file overflowed sector count or scan bounds");

        reset_reader; bits = 24; length = 66;
        start_read(1); await_timeout;
        if (!scan_done) $fatal(1, "scan timeout did not release upper layer");
        reset_reader; start_read(0); await_timeout;
        reset_reader; begin_pixels; await_timeout;
        reset_reader; begin_pixels; sector_error = 1;
        send_sector(0, 0); sector_error = 0; check_error(2);
        reset_reader; begin_pixels; send_sector(65, 0); check_error(3);
        if (dut.pixel_count != 3) $fatal(1, "truncated stream pixel count");

        // Put the last pixel on the final byte of a sector to catch NBA off-by-one.
        reset_reader; length = 512; offset = 500;
        begin_pixels; send_sector(512, 0);
        if (!ready || load_error || bmp_error != 0 || output_pixels != 4)
            $fatal(1, "last-byte pixel incorrectly rejected");

        // Real frame: total duration exceeds one deadline, each sector does not.
        reset_reader; width = 640; height = 480; offset = 54; length = 921654;
        begin_pixels;
        for (sectors = 0; sectors < 1801; sectors = sectors + 1) begin
            send_sector(512, 0);
            if (load_error) $fatal(1, "valid full frame error at sector %0d", sectors);
            if (sectors < 1800) begin wait (request); @(negedge clk); end
        end
        if (!ready || bmp_error != 0 || output_pixels != 307200 || dut.pixel_count != 307200)
            $fatal(1, "640x480 completeness check failed");
        $display("PASS: BM fast skip, scan bounds, scan/header/data timeouts, truncation, last-byte pixel and 307200-pixel frame");
        test_pass = 1;
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "BMP error test watchdog");
    end
endmodule
