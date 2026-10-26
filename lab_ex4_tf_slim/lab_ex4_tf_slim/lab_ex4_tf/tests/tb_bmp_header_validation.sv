`timescale 1ns/1ps

// Feed complete header sectors through the reader's normal byte interface.
// Check acceptance in both catalog scanning and direct picture loading.
module tb_bmp_header_validation;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg scan_start = 0, load_start = 0, load_abort = 0;
    reg [7:0] data = 0;
    reg data_valid = 0, sector_end = 0;
    wire ready, scan_done, scan_found_valid, write_req, sector_req;
    wire [2:0] scan_found_total;
    wire [2:0] bmp_error;
    wire load_error;
    reg [31:0] dib = 40, offset = 54, length = 921654;
    reg [15:0] plane_count = 1;
    reg test_pass = 0;
    integer checks = 0;

    bmp_read dut (
        .clk(clk), .rst(rst), .ready(ready),
        .scan_start(scan_start), .scan_start_sector(32'd0),
        .scan_max_sector(32'd0), .scan_target_count(3'd1),
        .scan_done(scan_done), .scan_found_valid(scan_found_valid),
        .scan_found_sector(), .scan_found_total(scan_found_total),
        .load_start(load_start), .load_abort(load_abort), .load_sector(32'd0),
        .bmp_error(bmp_error), .load_error(load_error),
        .sd_init_done(1'b1), .state_code(),
        .bmp_width(16'd640), .bmp_height(16'd480),
        .write_req(write_req), .write_req_ack(1'b0),
        .sd_sec_read(sector_req), .sd_sec_read_addr(),
        .sd_sec_read_data(data), .sd_sec_read_data_valid(data_valid),
        .sd_sec_read_end(sector_end), .sd_sec_read_error(1'b0),
        .bmp_data_wr_en(), .bmp_data()
    );

    function [7:0] header_byte(input integer index);
        case (index)
            0: header_byte = "B";
            1: header_byte = "M";
            2, 3, 4, 5: header_byte = length >> ((index - 2) * 8);
            10, 11, 12, 13: header_byte = offset >> ((index - 10) * 8);
            14, 15, 16, 17: header_byte = dib >> ((index - 14) * 8);
            18: header_byte = 8'h80;
            19: header_byte = 8'h02;
            22: header_byte = 8'he0;
            23: header_byte = 8'h01;
            26, 27: header_byte = plane_count >> ((index - 26) * 8);
            28: header_byte = 24;
            default: header_byte = 0;
        endcase
    endfunction

    task check_header(input bit scanning, input bit expected);
        integer index;
        begin
            if (!ready) $fatal(1, "reader not idle before header");
            @(negedge clk);
            scan_start = scanning;
            load_start = !scanning;
            @(negedge clk);
            scan_start = 0;
            load_start = 0;
            wait (sector_req);
            @(negedge clk);
            for (index = 0; index < 512; index = index + 1) begin
                data = header_byte(index);
                data_valid = 1;
                @(negedge clk);
            end
            data_valid = 0;
            sector_end = 1;
            @(negedge clk);
            sector_end = 0;
            if (scanning) begin
                if (!scan_done || !ready || scan_found_valid !== expected ||
                    scan_found_total !== (expected ? 3'd1 : 3'd0))
                    $fatal(1, "scan acceptance mismatch: check %0d", checks);
            end else begin
                if (write_req !== expected || ready !== !expected)
                    $fatal(1, "load acceptance mismatch: check %0d", checks);
                if (load_error !== !expected || bmp_error !== (expected ? 3'd0 : 3'd1))
                    $fatal(1, "header error reporting mismatch: check %0d", checks);
                // Stop before the memory handshake/pixel stream.
                load_abort = 1;
                @(negedge clk);
                load_abort = 0;
            end
            checks = checks + 1;
        end
    endtask

    task check_both(input bit expected);
        begin
            check_header(1, expected);
            check_header(0, expected);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 0;
        if (dut.TIMEOUT_CYCLES != 64'd50000000)
            $fatal(1, "default 500 ms timeout calculation overflowed");
        if (dut.dib_size !== 0 || dut.planes !== 0)
            $fatal(1, "new header fields were not reset");
        check_both(1);                    // Exact minimum valid file size.
        dib = 39; check_both(0); dib = 40;
        plane_count = 0; check_both(0);
        plane_count = 16'h0101; check_both(0); plane_count = 1;
        offset = 53; check_both(0);
        offset = length; check_both(0);
        offset = length + 1; check_both(0); offset = 54;
        length = 921653; check_both(0); length = 921654;
        // Extended header and multi-byte offset/length exercise byte order.
        dib = 256; offset = 310; length = 921910; check_both(1);
        $display("PASS: strict BMP header validation, scan/load and boundaries (%0d checks)", checks);
        test_pass = 1;
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "header test watchdog");
    end
endmodule
