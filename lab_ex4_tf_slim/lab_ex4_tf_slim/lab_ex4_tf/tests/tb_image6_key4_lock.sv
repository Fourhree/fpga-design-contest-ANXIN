`timescale 1ns/1ps

module tb_image6_key4_lock;
    reg clk = 0;
    reg rst_n = 0;
    reg key4_n = 1;
    reg sw1 = 1;
    reg sw2 = 1;
    reg input_inhibit = 0;
    wire [7:0] volume;
    wire [7:0] brightness;
    wire [7:0] contrast;
    wire update_valid;
    wire menu_event;
    integer update_count = 0;
    integer menu_event_count = 0;
    reg test_pass = 0;

    always #5 clk = ~clk;

    param_menu_controller #(
        .CLKS_PER_MS(1),
        .DEBOUNCE_MS(3),
        .LONG_HOLD_MS(30)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .key4_n(key4_n),
        .sw1(sw1),
        .sw2(sw2),
        .service_ready(1'b1),
        .input_inhibit(input_inhibit),
        .live_volume(8'd0),
        .live_period_ms(32'd5000),
        .cfg_update_valid(update_valid),
        .cfg_period_ms(),
        .cfg_volume(volume),
        .cfg_brightness(brightness),
        .cfg_contrast(contrast),
        .menu_event(menu_event),
        .menu_kind(),
        .menu_level()
    );

    always @(posedge clk) begin
        if (update_valid)
            update_count = update_count + 1;
        if (menu_event)
            menu_event_count = menu_event_count + 1;
    end

    task tick(input integer count);
        repeat (count) @(negedge clk);
    endtask

    task short_press;
        key4_n = 0;
        tick(12);
        key4_n = 1;
        tick(12);
    endtask

    task long_press;
        key4_n = 0;
        tick(55);
        key4_n = 1;
        tick(12);
    endtask

    initial begin
        tick(4);
        rst_n = 1;
        tick(12);
        if (volume !== 8'd255 || brightness !== 8'd192 || contrast !== 8'd128)
            $fatal(1, "Unexpected parameter defaults");

        // Enter image 6 while KEY4 is already held. The forced release must
        // cancel the partial press without creating a delayed update.
        key4_n = 0;
        tick(12);
        input_inhibit = 1;
        tick(4);
        key4_n = 1;
        tick(12);
        if (update_count != 0 || menu_event_count != 0)
            $fatal(1, "Image-6 inhibit did not cancel the active KEY4 press");

        // Exercise contrast, volume, and brightness switch modes while the
        // sixth image is active. None may change a stored parameter.
        sw1 = 1; sw2 = 1; tick(12); short_press();
        sw1 = 1; sw2 = 0; tick(12); long_press();
        sw1 = 0; sw2 = 0; tick(12); short_press();
        if (volume !== 8'd255 || brightness !== 8'd192 || contrast !== 8'd128 ||
            update_count != 0 || menu_event_count != 0)
            $fatal(1, "KEY4 changed a parameter while image 6 was active");

        // Leaving image 6 restores normal KEY4 operation.
        input_inhibit = 0;
        sw1 = 1; sw2 = 1;
        tick(12);
        short_press();
        if (contrast !== 8'd144 || update_count != 1 || menu_event_count != 1)
            $fatal(1, "KEY4 did not recover after leaving image 6");

        test_pass = 1;
        $display("PASS: image-6 KEY4 lock and active-press cancellation");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Test timeout");
    end
endmodule
