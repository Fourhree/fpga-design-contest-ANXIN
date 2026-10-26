`timescale 1ns/1ps
module tb_frame_writer;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst = 1, request = 0, produce = 0;
    wire ack, finish, clear, write_en;
    wire [20:0] address;
    integer fifo_count = 0, supplied = 0, consumed = 0, cycles = 0;
    integer stream_limit = 307200;
    integer expected_address;
    reg [1:0] buffer_index = 0;
    reg test_pass = 0;
    frame_fifo_write dut (
        .rst(rst), .mem_clk(clk), .Sdr_init_done(1'b1),
        .Sdr_init_ref_vld(1'b0), .Sdr_busy(1'b0), .App_rd_busy(1'b0),
        .O_wr_busy(), .App_wr_en(write_en), .App_wr_addr(address),
        .write_req(request), .write_req_ack(ack), .write_finish(finish),
        .write_addr_0(21'd0), .write_addr_1(21'd307200),
        .write_addr_2(21'd0), .write_addr_3(21'd0),
        .write_addr_index(buffer_index), .write_len(21'd307200),
        .fifo_aclr(clear), .rdusedw(fifo_count[9:0])
    );
    always @(posedge clk) begin
        cycles = cycles + 1;
        if (rst || clear) begin
            fifo_count = 0;
            supplied = 0;
            consumed = 0;
        end else begin
            if (write_en) begin
                if (fifo_count == 0) $fatal(1, "frame writer FIFO underflow");
                expected_address = buffer_index * 307200 +
                                   (479 - consumed / 640) * 640 + consumed % 640;
                if (address !== expected_address[20:0])
                    $fatal(1, "vertical flip address mismatch at pixel %0d: %0d != %0d", consumed, address, expected_address);
                fifo_count = fifo_count - 1;
                consumed = consumed + 1;
            end
            if (produce && supplied < stream_limit && cycles % 4 == 0) begin
                fifo_count = fifo_count + 1;
                supplied = supplied + 1;
            end
            if (fifo_count > 512) $fatal(1, "frame writer FIFO overflow");
        end
    end
    task start_frame;
        begin
            @(negedge clk);
            produce = 0;
            request = 1;
            wait (ack);
            @(negedge clk);
            request = 0;
            wait (!ack);
            @(negedge clk);
            produce = 1;
        end
    endtask
    initial begin
        repeat (5) @(negedge clk);
        rst = 0;
        start_frame;
        wait (finish);
        if (consumed != 307200) $fatal(1, "frame finished with wrong pixel count");
        repeat (10) @(negedge clk);
        stream_limit = 4000;
        start_frame;
        wait (supplied == 4000);
        repeat (200) @(negedge clk);
        // Recover a truncated old frame through the normal write-request ACK.
        stream_limit = 307200;
        buffer_index = 1;
        start_frame;
        wait (finish);
        if (consumed != 307200) $fatal(1, "restarted frame did not complete");
        $display("PASS: 640x480 frame writes, every flip address, FIFO bounds and truncated-frame restart");
        test_pass = 1;
        $finish;
    end
    initial begin
        #30000000;
        $fatal(1, "frame writer watchdog");
    end
endmodule
