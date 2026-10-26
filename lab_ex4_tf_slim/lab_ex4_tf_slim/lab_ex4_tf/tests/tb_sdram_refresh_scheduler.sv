`timescale 1ns/1ps

module tb_sdram_refresh_scheduler;
    localparam integer INTERVAL = 8;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg init_done = 1'b0;
    reg refresh_active = 1'b0;
    reg request_allowed = 1'b0;
    wire refresh_pending;
    wire refresh_request;
    integer wait_cycles = 0;
    reg test_pass = 1'b0;

    always #5 clk = ~clk;

    sdram_refresh_scheduler #(
        .REFRESH_INTERVAL_CYCLES(INTERVAL)
    ) dut (
        .clk(clk),
        .rst(rst),
        .init_done(init_done),
        .refresh_active(refresh_active),
        .request_allowed(request_allowed),
        .refresh_pending(refresh_pending),
        .refresh_request(refresh_request)
    );

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);
        if (refresh_request !== 1'b0)
            $fatal(1, "Refresh requested before SDRAM initialization");

        init_done = 1'b1;
        repeat (INTERVAL - 1) @(negedge clk);
        if (refresh_request !== 1'b0)
            $fatal(1, "Refresh request asserted too early");
        @(negedge clk);
        if (refresh_pending !== 1'b1 || refresh_request !== 1'b0)
            $fatal(1, "Refresh deadline did not create a blocked pending request");

        repeat (5) begin
            @(negedge clk);
            if (refresh_pending !== 1'b1 || refresh_request !== 1'b0)
                $fatal(1, "Pending refresh was lost while an application burst was active");
        end

        request_allowed = 1'b1;
        @(negedge clk);
        if (refresh_request !== 1'b1)
            $fatal(1, "Refresh request was not issued when the controller became idle");
        request_allowed = 1'b0;
        @(negedge clk);
        if (refresh_request !== 1'b1)
            $fatal(1, "Refresh request was not held until acknowledgement");
        refresh_active = 1'b1;
        @(negedge clk);
        if (refresh_pending !== 1'b0 || refresh_request !== 1'b0)
            $fatal(1, "Refresh request did not clear after acknowledgement");
        refresh_active = 1'b0;
        request_allowed = 1'b1;

        wait_cycles = 0;
        while ((refresh_pending !== 1'b1) && (wait_cycles < INTERVAL)) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (refresh_pending !== 1'b1)
            $fatal(1, "Periodic refresh request did not recur");

        test_pass = 1'b1;
        $display("PASS: periodic SDRAM refresh request is held until acknowledgement");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "Refresh scheduler timeout");
    end
endmodule
