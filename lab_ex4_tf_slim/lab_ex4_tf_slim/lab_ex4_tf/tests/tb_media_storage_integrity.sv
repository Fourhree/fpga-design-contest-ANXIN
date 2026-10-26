`timescale 1ns/1ps

module tb_media_loader_integrity;
    localparam IMAGE_WORDS = 64;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg load_start = 0;
    reg [2:0] image_index = 0;
    reg [15:0] image_width = 0, image_height = 0;
    reg image_bottom_up = 0;
    reg pixel_valid = 0;
    reg [23:0] pixel_rgb = 0;
    reg frame_commit = 0;
    wire load_busy, load_done, write_busy, app_wr_en;
    wire [5:0] image_complete;
    wire [7:0] memory_error;
    wire [20:0] app_wr_addr;
    wire [3:0] app_wr_mask;
    wire [31:0] app_wr_data;
    wire [95:0] bank_widths, bank_heights;
    wire [5:0] bank_bottom_up;

    media_frame_loader #(
        .ADDR_WIDTH(21), .IMAGE_WORDS(IMAGE_WORDS), .FIFO_DEPTH(16),
        .BURST_SIZE(8), .BURST_GAP_CYCLES(2), .DYNAMIC_GEOMETRY(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .load_start(load_start),
        .image_index(image_index), .image_width(image_width),
        .image_height(image_height), .image_bottom_up(image_bottom_up),
        .bank_widths(bank_widths), .bank_heights(bank_heights),
        .bank_bottom_up(bank_bottom_up), .pixel_valid(pixel_valid),
        .pixel_rgb(pixel_rgb), .frame_commit(frame_commit),
        .decode_error(8'd0), .load_busy(load_busy), .load_done(load_done),
        .image_complete(image_complete), .memory_error(memory_error),
        .controller_init_done(1'b1), .controller_busy(1'b0),
        .refresh_active(1'b0), .read_request_busy(1'b0),
        .write_request_busy(write_busy), .app_wr_en(app_wr_en),
        .app_wr_addr(app_wr_addr), .app_wr_mask(app_wr_mask),
        .app_wr_data(app_wr_data)
    );

    integer accepted_writes = 0;
    integer expected_bank = 0;
    integer expected_pixel = 0;
    reg check_writes = 0;
    reg saw_load_done = 0;
    always @(posedge clk) begin
        if (load_done)
            saw_load_done <= 1;
        if (app_wr_en && app_wr_mask == 4'b0000) begin
            if (check_writes) begin
                if (app_wr_addr !== expected_bank*IMAGE_WORDS + expected_pixel)
                    $fatal(1, "Bank %0d pixel %0d address %0d expected %0d",
                           expected_bank, expected_pixel, app_wr_addr,
                           expected_bank*IMAGE_WORDS + expected_pixel);
                if (app_wr_data[23:0] !== {expected_bank[7:0], expected_pixel[15:0]})
                    $fatal(1, "Bank %0d pixel %0d data %h",
                           expected_bank, expected_pixel, app_wr_data[23:0]);
                expected_pixel = expected_pixel + 1;
                accepted_writes = accepted_writes + 1;
            end
        end
    end

    task begin_load;
        input [2:0] bank;
        input [15:0] width;
        input [15:0] height;
        begin
            @(negedge clk);
            saw_load_done = 0;
            image_index = bank;
            image_width = width;
            image_height = height;
            load_start = 1;
            @(negedge clk);
            load_start = 0;
        end
    endtask

    task send_pixel;
        input [23:0] value;
        begin
            pixel_rgb = value;
            pixel_valid = 1;
            @(negedge clk);
            pixel_valid = 0;
            @(negedge clk);
        end
    endtask

    task commit_frame;
        begin
            frame_commit = 1;
            @(negedge clk);
            frame_commit = 0;
        end
    endtask

    integer bank, p;
    reg test_pass = 0;
    initial begin
        repeat (6) @(negedge clk);
        rst_n = 1;
        for (bank = 0; bank < 6; bank = bank + 1) begin
            expected_bank = bank;
            expected_pixel = 0;
            check_writes = 1;
            begin_load(bank[2:0], 16'd8, 16'd4);
            for (p = 0; p < 32; p = p + 1)
                send_pixel({bank[7:0], p[15:0]});
            commit_frame();
            wait (saw_load_done);
            #1;
            check_writes = 0;
            if (memory_error != 0 || !image_complete[bank] || expected_pixel != 32)
                $fatal(1, "Bank %0d load failed: err=%h complete=%b writes=%0d",
                       bank, memory_error, image_complete[bank], expected_pixel);
            if (bank_widths[bank*16 +: 16] != 8 ||
                bank_heights[bank*16 +: 16] != 4)
                $fatal(1, "Bank %0d geometry metadata mismatch", bank);
        end

        begin_load(3'd4, 16'd2, 16'd2);
        for (p = 0; p < 5; p = p + 1)
            send_pixel({8'd4, p[15:0]});
        wait (saw_load_done);
        #1;
        if (memory_error != 8'h43)
            $fatal(1, "Excess pixel error was %h, expected 43", memory_error);

        begin_load(3'd5, 16'd2, 16'd2);
        for (p = 0; p < 3; p = p + 1)
            send_pixel({8'd5, p[15:0]});
        commit_frame();
        wait (saw_load_done);
        #1;
        if (memory_error != 8'h45)
            $fatal(1, "Short frame error was %h, expected 45", memory_error);

        test_pass = 1;
        $display("PASS: six loader banks, %0d exact writes, excess/short rejection", accepted_writes);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "Loader integrity timeout");
    end
endmodule

module tb_media_reader_integrity;
    localparam W = 64;
    localparam H = 16;
    reg mem_clk = 0, pix_clk = 0, rst_n = 0;
    always #5 mem_clk = ~mem_clk;
    always #20 pix_clk = ~pix_clk;

    reg frame_start = 0, pixel_consume = 0;
    reg [11:0] pixel_x = 0, pixel_y = 0;
    reg [2:0] active_index = 0;
    wire request_valid;
    wire [11:0] request_x, request_y;
    wire app_rd_en;
    wire [20:0] app_rd_addr;
    reg sdram_rd_valid = 0;
    reg [31:0] sdram_rd_data = 0;
    wire [23:0] pixel_rgb;
    wire pixel_valid, underflow, reader_busy;
    wire [7:0] reader_error;

    media_frame_reader #(
        .ADDR_WIDTH(21), .IMAGE_WORDS(307200),
        .DISPLAY_WIDTH(W), .DISPLAY_HEIGHT(H),
        .BURST_SIZE(128), .BURST_GAP_CYCLES(12)
    ) dut (
        .mem_clk(mem_clk), .mem_rst_n(rst_n),
        .controller_init_done(1'b1), .controller_busy(1'b0),
        .refresh_active(1'b0), .write_request_busy(1'b0),
        .read_request_busy(), .app_rd_en(app_rd_en),
        .app_rd_addr(app_rd_addr), .sdram_rd_valid(sdram_rd_valid),
        .sdram_rd_data(sdram_rd_data), .pix_clk(pix_clk),
        .pix_rst_n(rst_n), .frame_start(frame_start),
        .active_index(active_index), .pixel_consume(pixel_consume),
        .pixel_x(pixel_x), .pixel_y(pixel_y),
        .request_valid(request_valid), .request_x(request_x),
        .request_y(request_y), .coordinate_valid(request_valid),
        .source_index(active_index), .source_x({4'd0, request_x}),
        .source_y({4'd0, request_y}), .source_stride(16'd640),
        .focus_border(1'b0), .pixel_rgb(pixel_rgb),
        .pixel_valid(pixel_valid), .underflow(underflow),
        .reader_busy(reader_busy), .frame_read_done(),
        .reader_index(), .reader_error(reader_error)
    );

    reg [20:0] return_fifo [0:8191];
    integer return_wr = 0, return_rd = 0, return_count = 0;
    integer reads_issued = 0, reads_returned = 0;
    reg [15:0] lfsr = 16'h1ace;
    wire make_return = return_count != 0 && lfsr[2:0] != 3'b000;
    always @(posedge mem_clk) begin
        lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
        sdram_rd_valid <= make_return;
        if (make_return) begin
            sdram_rd_data <= {11'd0, return_fifo[return_rd]};
            return_rd <= (return_rd + 1) & 8191;
            reads_returned <= reads_returned + 1;
        end
        if (app_rd_en) begin
            return_fifo[return_wr] <= app_rd_addr;
            return_wr <= (return_wr + 1) & 8191;
            reads_issued <= reads_issued + 1;
        end
        case ({app_rd_en, make_return})
            2'b10: return_count <= return_count + 1;
            2'b01: return_count <= return_count - 1;
            default: ;
        endcase
        if (return_count > 8000)
            $fatal(1, "SDRAM response model overflow");
    end

    function [23:0] expected_rgb;
        input integer bank;
        input integer x;
        input integer y;
        begin
            expected_rgb = bank*307200 + y*640 + x;
        end
    endfunction

    task display_bank;
        input integer bank;
        integer x, y;
        begin
            active_index = bank[2:0];
            @(negedge pix_clk);
            frame_start = 1;
            @(negedge pix_clk);
            frame_start = 0;
            repeat (W + 500) @(negedge pix_clk);
            for (y = 0; y < H; y = y + 1) begin
                for (x = 0; x < W; x = x + 1) begin
                    pixel_x = x;
                    pixel_y = y;
                    pixel_consume = 1;
                    @(posedge pix_clk);
                    #1;
                    if (!pixel_valid || pixel_rgb !== expected_rgb(bank, x, y))
                        $fatal(1, "Bank %0d pixel (%0d,%0d): rgb=%h expected=%h valid=%b",
                               bank, x, y, pixel_rgb, expected_rgb(bank, x, y), pixel_valid);
                    @(negedge pix_clk);
                end
                pixel_consume = 0;
                repeat (180) @(negedge pix_clk);
            end
            wait (!reader_busy && return_count == 0);
        end
    endtask

    integer bank;
    reg test_pass = 0;
    initial begin
        repeat (10) @(negedge pix_clk);
        rst_n = 1;
        for (bank = 0; bank < 6; bank = bank + 1)
            display_bank(bank);
        if (underflow || reader_error != 0)
            $fatal(1, "Reader status underflow=%b error=%h", underflow, reader_error);
        if (reads_issued != reads_returned || reads_issued < 20000)
            $fatal(1, "Read accounting mismatch issued=%0d returned=%0d",
                   reads_issued, reads_returned);
        test_pass = 1;
        $display("PASS: six reader banks, %0d gapped returns, repeated metadata wrap", reads_returned);
        $finish;
    end

    initial begin
        #50000000;
        $fatal(1, "Reader integrity timeout");
    end
endmodule
