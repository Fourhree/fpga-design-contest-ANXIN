`timescale 1ns/1ps

// KEY4 parameter control. Logical SW1/SW2 modes select contrast (00), volume
// (01), or brightness (11). A short press increments the selected value on
// release; a one-second hold decrements once, without another event on release.
// The board switches are active low, so physical SW1=1/SW2=0 selects volume.
module param_menu_controller #(
    parameter integer CLKS_PER_MS = 50000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer LONG_HOLD_MS = 1000,
    parameter integer PARAM_STEP = 16,
    // Board switches connect to ground in the ON (logical 1) position.
    parameter integer SW_ACTIVE_LOW = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        key4_n,
    input  wire        sw1,
    input  wire        sw2,
    input  wire        service_ready,
    input  wire        input_inhibit,
    // Legacy inputs/outputs are retained for source compatibility.
    input  wire [7:0]  live_volume,
    input  wire [31:0] live_period_ms,
    output reg         cfg_update_valid,
    output reg  [31:0] cfg_period_ms,
    output reg  [7:0]  cfg_volume,
    output reg  [7:0]  cfg_brightness,
    output reg  [7:0]  cfg_contrast,
    output reg         menu_event,
    output reg  [1:0]  menu_kind,
    output reg  [3:0]  menu_level
);
    localparam integer DEBOUNCE_CYCLES = DEBOUNCE_MS * CLKS_PER_MS;
    localparam integer LONG_HOLD_CYCLES = LONG_HOLD_MS * CLKS_PER_MS;

    (* async_reg = "true" *) reg key_sync_ff1, key_sync_ff2;
    (* async_reg = "true" *) reg [1:0] sw_sync_ff1, sw_sync_ff2;
    reg [1:0] switch_mode;
    reg [1:0] switch_candidate;
    reg [1:0] press_mode;
    reg [31:0] switch_debounce_count;
    reg key_raw_q;
    reg key_stable_q;
    reg [31:0] debounce_count;
    reg [31:0] hold_count;
    reg press_active;
    reg long_press;
    reg [7:0] next_value;

    wire selected_brightness = press_mode == 2'b11;
    wire selected_contrast = press_mode == 2'b00;
    wire selected_volume = press_mode == 2'b01;
    wire key_pressed = !key_stable_q;
    wire [1:0] logical_switches = SW_ACTIVE_LOW ? ~{sw1, sw2} : {sw1, sw2};
    wire increment_event = press_active && !key_pressed && !long_press;
    wire decrement_ready = selected_volume ||
                           ((selected_brightness || selected_contrast) && service_ready);
    wire decrement_event = press_active && key_pressed && !long_press &&
                           hold_count >= LONG_HOLD_CYCLES - 1 && decrement_ready;

    function [7:0] increment_value;
        input [7:0] value;
        begin
            if (value >= 8'd255 - PARAM_STEP)
                increment_value = 8'd255;
            else
                increment_value = value + PARAM_STEP;
        end
    endfunction

    function [7:0] decrement_value;
        input [7:0] value;
        begin
            // Keep the saturated endpoint on the same 16-step grid when
            // moving down: 255 -> 240 -> 224 ... -> 0.
            if (value == 8'd255)
                decrement_value = 8'd240;
            else if (value <= PARAM_STEP)
                decrement_value = 8'd0;
            else
                decrement_value = value - PARAM_STEP;
        end
    endfunction

    function [7:0] increment_volume;
        input [7:0] value;
        begin
            case (value)
                8'd0:   increment_volume = 8'd64;
                8'd64:  increment_volume = 8'd128;
                8'd128: increment_volume = 8'd192;
                8'd192: increment_volume = 8'd255;
                default: increment_volume = 8'd0;
            endcase
        end
    endfunction

    function [7:0] decrement_volume;
        input [7:0] value;
        begin
            case (value)
                8'd0:   decrement_volume = 8'd255;
                8'd64:  decrement_volume = 8'd0;
                8'd128: decrement_volume = 8'd64;
                8'd192: decrement_volume = 8'd128;
                default: decrement_volume = 8'd192;
            endcase
        end
    endfunction

    function [3:0] volume_level;
        input [7:0] value;
        begin
            case (value)
                8'd0:   volume_level = 4'd0;
                8'd64:  volume_level = 4'd1;
                8'd128: volume_level = 4'd2;
                8'd192: volume_level = 4'd3;
                default: volume_level = 4'd4;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_sync_ff1 <= 1'b1;
            key_sync_ff2 <= 1'b1;
            sw_sync_ff1 <= 2'b10;
            sw_sync_ff2 <= 2'b10;
            switch_mode <= 2'b10;
            switch_candidate <= 2'b10;
            press_mode <= 2'b10;
            switch_debounce_count <= 32'd0;
            key_raw_q <= 1'b1;
            key_stable_q <= 1'b1;
            debounce_count <= 32'd0;
            hold_count <= 32'd0;
            press_active <= 1'b0;
            long_press <= 1'b0;
            cfg_update_valid <= 1'b0;
            cfg_period_ms <= 32'd5000;
            cfg_volume <= 8'd255;
            cfg_brightness <= 8'd192;
            cfg_contrast <= 8'd128;
            menu_event <= 1'b0;
            menu_kind <= 2'd0;
            menu_level <= 4'd12;
        end else begin
            cfg_update_valid <= 1'b0;
            menu_event <= 1'b0;

            key_sync_ff1 <= key4_n;
            key_sync_ff2 <= key_sync_ff1;
            sw_sync_ff1 <= logical_switches;
            sw_sync_ff2 <= sw_sync_ff1;
            if (sw_sync_ff2 != switch_candidate) begin
                switch_candidate <= sw_sync_ff2;
                switch_debounce_count <= 32'd0;
            end else if (sw_sync_ff2 != switch_mode) begin
                if (switch_debounce_count >= DEBOUNCE_CYCLES - 1) begin
                    switch_mode <= sw_sync_ff2;
                    switch_debounce_count <= 32'd0;
                end else begin
                    switch_debounce_count <= switch_debounce_count + 1'b1;
                end
            end else begin
                switch_debounce_count <= 32'd0;
            end
            if (key_sync_ff2 != key_raw_q) begin
                if (debounce_count >= DEBOUNCE_CYCLES - 1) begin
                    key_raw_q <= key_sync_ff2;
                    key_stable_q <= key_sync_ff2;
                    debounce_count <= 32'd0;
                end else begin
                    debounce_count <= debounce_count + 1'b1;
                end
            end else begin
                debounce_count <= 32'd0;
            end

            if (input_inhibit) begin
                // Cancel any partial press without turning the forced release
                // into a short-press event.
                key_raw_q <= 1'b1;
                key_stable_q <= 1'b1;
                debounce_count <= 32'd0;
                press_active <= 1'b0;
                hold_count <= 32'd0;
                long_press <= 1'b0;
            end else begin
                if (!press_active) begin
                    if (key_pressed) begin
                        press_active <= 1'b1;
                        press_mode <= switch_mode;
                        hold_count <= 32'd0;
                        long_press <= 1'b0;
                    end
                end else if (!key_pressed) begin
                    press_active <= 1'b0;
                    hold_count <= 32'd0;
                end else begin
                    if (hold_count < LONG_HOLD_CYCLES)
                        hold_count <= hold_count + 1'b1;
                    if (decrement_event)
                        long_press <= 1'b1;
                end

                if ((increment_event || decrement_event) && selected_volume) begin
                    next_value = decrement_event ? decrement_volume(cfg_volume) : increment_volume(cfg_volume);
                    cfg_volume <= next_value;
                    menu_kind <= 2'd1;
                    menu_level <= volume_level(next_value);
                    menu_event <= 1'b1;
                end else if ((increment_event || decrement_event) && service_ready &&
                             (selected_brightness || selected_contrast)) begin
                    if (selected_brightness) begin
                        next_value = decrement_event ? decrement_value(cfg_brightness) : increment_value(cfg_brightness);
                        cfg_brightness <= next_value;
                        menu_kind <= 2'd2;
                        menu_level <= next_value[7:4];
                    end else begin
                        next_value = decrement_event ? decrement_value(cfg_contrast) : increment_value(cfg_contrast);
                        cfg_contrast <= next_value;
                        menu_kind <= 2'd3;
                        menu_level <= next_value[7:4];
                    end
                    cfg_update_valid <= 1'b1;
                    menu_event <= 1'b1;
                end
            end
        end
    end
endmodule
