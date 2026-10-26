`timescale 1ns/1ps

module media_player_control #(
    parameter [31:0] DEFAULT_PERIOD_CYCLES = 32'd250000000,
    parameter [31:0] MIN_PERIOD_CYCLES = 32'd50000000,
    parameter [31:0] MAX_PERIOD_CYCLES = 32'd3000000000
) (
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    input  wire        next_event,
    // 0: all available; 1: cycle images 1..5; 2: select image 6.
    input  wire [1:0]  manual_next_mode,
    input  wire        navigation_lock,
    input  wire        auto_normal_only,
    input  wire        prev_event,
    input  wire        toggle_auto_event,
    input  wire        period_cfg_valid,
    input  wire [31:0] period_cfg_cycles,
    input  wire        auto_cfg_valid,
    input  wire        auto_cfg_enabled,
    input  wire [5:0]  image_complete,
    output reg         auto_enabled,
    output reg  [31:0] active_period_cycles,
    output reg  [2:0]  pending_index,
    output reg  [7:0]  control_error,
    output wire        request_busy,
    input  wire        pix_clk,
    input  wire        pix_rst_n,
    input  wire        frame_start,
    output reg  [2:0]  active_index,
    output reg         index_commit
);
    localparam ERR_NONE = 8'h00;
    localparam ERR_PERIOD_RANGE = 8'h51;
    localparam ERR_REQUEST_BUSY = 8'h52;
    localparam ERR_NO_RESOURCE = 8'h53;

    reg [31:0] auto_counter;
    reg [2:0] sys_current_index;
    reg request_toggle;
    reg ack_toggle_pix;
    reg ack_sync1, ack_sync2;
    reg [2:0] index_sync1, index_sync2;
    reg req_sync1, req_sync2;
    reg req_seen_pix;
    reg [2:0] requested_index_pix;
    reg commit_pending_pix;
    reg first_request_sent;
    // Images 2/3 and 4/5 form two groups. Each member uses half of the
    // configured slideshow period while image 1 keeps the full period.
    wire grouped_auto_image = sys_current_index >= 3'd1 &&
                              sys_current_index <= 3'd4;
    wire [31:0] current_auto_period = grouped_auto_image ?
                                      (active_period_cycles >> 1) :
                                      active_period_cycles;
    wire [2:0] first_available = image_complete[0] ? 3'd0 :
                                 image_complete[1] ? 3'd1 :
                                 image_complete[2] ? 3'd2 :
                                 image_complete[3] ? 3'd3 :
                                 image_complete[4] ? 3'd4 : 3'd5;

    assign request_busy = request_toggle != ack_sync2;

    function [3:0] next_available;
        input [2:0] current;
        input [5:0] complete;
        input backwards;
        integer step;
        integer candidate_number;
        reg [2:0] candidate;
        begin
            next_available = {1'b0, current};
            for (step = 1; step <= 6; step = step + 1) begin
                candidate_number = backwards ? current + 6 - step : current + step;
                if (candidate_number >= 6)
                    candidate_number = candidate_number - 6;
                candidate = candidate_number[2:0];
                if (!next_available[3] && complete[candidate])
                    next_available = {1'b1, candidate};
            end
        end
    endfunction

    function [3:0] next_available_five;
        input [2:0] current;
        input [5:0] complete;
        input backwards;
        integer step;
        integer base_index;
        integer candidate_number;
        reg [2:0] candidate;
        begin
            next_available_five = {1'b0, current};
            // Treat image 6 as just beyond either end of the normal ring:
            // next enters image 1, previous enters image 5.
            base_index = current < 5 ? current : (backwards ? 0 : 4);
            for (step = 1; step <= 5; step = step + 1) begin
                candidate_number = backwards ? base_index + 5 - step :
                                               base_index + step;
                if (candidate_number >= 5)
                    candidate_number = candidate_number - 5;
                candidate = candidate_number[2:0];
                if (!next_available_five[3] && complete[candidate])
                    next_available_five = {1'b1, candidate};
            end
        end
    endfunction

    task issue_next_request;
        input backwards;
        reg [3:0] selected;
        begin
            selected = next_available_five(sys_current_index, image_complete,
                                           backwards);
            if (request_busy) begin
                control_error <= ERR_REQUEST_BUSY;
            end else if (!selected[3]) begin
                control_error <= ERR_NO_RESOURCE;
            end else begin
                pending_index <= selected[2:0];
                request_toggle <= ~request_toggle;
                auto_counter <= 32'd0;
            end
        end
    endtask

    task issue_manual_next_request;
        reg [3:0] selected;
        begin
            if (manual_next_mode == 2'd2)
                selected = {image_complete[5], 3'd5};
            else if (manual_next_mode == 2'd1)
                selected = next_available_five(sys_current_index, image_complete,
                                               1'b0);
            else
                selected = next_available(sys_current_index, image_complete, 1'b0);

            if (request_busy) begin
                control_error <= ERR_REQUEST_BUSY;
            end else if (!selected[3]) begin
                control_error <= ERR_NO_RESOURCE;
            end else begin
                pending_index <= selected[2:0];
                request_toggle <= ~request_toggle;
                auto_counter <= 32'd0;
            end
        end
    endtask

    task issue_auto_next_request;
        reg [3:0] selected;
        begin
            selected = auto_normal_only ?
                       next_available_five(sys_current_index, image_complete,
                                           1'b0) :
                       next_available(sys_current_index, image_complete, 1'b0);
            if (request_busy) begin
                control_error <= ERR_REQUEST_BUSY;
            end else if (!selected[3]) begin
                control_error <= ERR_NO_RESOURCE;
            end else begin
                pending_index <= selected[2:0];
                request_toggle <= ~request_toggle;
                auto_counter <= 32'd0;
            end
        end
    endtask

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            auto_enabled <= 1'b0;
            active_period_cycles <= DEFAULT_PERIOD_CYCLES;
            pending_index <= 3'd0;
            control_error <= ERR_NONE;
            auto_counter <= 32'd0;
            sys_current_index <= 3'd0;
            request_toggle <= 1'b0;
            ack_sync1 <= 1'b0;
            ack_sync2 <= 1'b0;
            first_request_sent <= 1'b0;
        end else begin
            ack_sync1 <= ack_toggle_pix;
            ack_sync2 <= ack_sync1;
            if (!request_busy)
                sys_current_index <= pending_index;

            if (period_cfg_valid) begin
                if (period_cfg_cycles < MIN_PERIOD_CYCLES ||
                    period_cfg_cycles > MAX_PERIOD_CYCLES) begin
                    control_error <= ERR_PERIOD_RANGE;
                end else begin
                    active_period_cycles <= period_cfg_cycles;
                    auto_counter <= 32'd0;
                end
            end

            if (auto_cfg_valid) begin
                auto_enabled <= auto_cfg_enabled;
                auto_counter <= 32'd0;
            end

            if (toggle_auto_event) begin
                auto_enabled <= ~auto_enabled;
                auto_counter <= 32'd0;
            end

            // Present the first good image without waiting for a key press or
            // the remaining background loads (also handles a bad image zero).
            if (navigation_lock) begin
                // Keep the selected image fixed while the special image-6
                // key lock is active. Preserve auto_enabled for resume.
                auto_counter <= 32'd0;
            end else if (!first_request_sent && image_complete != 0 && !request_busy) begin
                first_request_sent <= 1'b1;
                pending_index <= first_available;
                request_toggle <= ~request_toggle;
                auto_counter <= 0;
            end else if (next_event) begin
                issue_manual_next_request;
            end else if (prev_event) begin
                issue_next_request(1'b1);
            end else if (auto_enabled) begin
                if (request_busy)
                    auto_counter <= 32'd0;
                else if (auto_counter >= current_auto_period - 1'b1)
                    issue_auto_next_request;
                else
                    auto_counter <= auto_counter + 1'b1;
            end else begin
                auto_counter <= 32'd0;
            end
        end
    end

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            index_sync1 <= 3'd0;
            index_sync2 <= 3'd0;
            req_sync1 <= 1'b0;
            req_sync2 <= 1'b0;
            req_seen_pix <= 1'b0;
            requested_index_pix <= 3'd0;
            commit_pending_pix <= 1'b0;
            active_index <= 3'd0;
            index_commit <= 1'b0;
            ack_toggle_pix <= 1'b0;
        end else begin
            index_sync1 <= pending_index;
            index_sync2 <= index_sync1;
            req_sync1 <= request_toggle;
            req_sync2 <= req_sync1;
            index_commit <= 1'b0;

            if (req_sync2 != req_seen_pix && !commit_pending_pix) begin
                req_seen_pix <= req_sync2;
                requested_index_pix <= index_sync2;
                commit_pending_pix <= 1'b1;
            end

            if (frame_start && commit_pending_pix) begin
                active_index <= requested_index_pix;
                index_commit <= 1'b1;
                commit_pending_pix <= 1'b0;
                ack_toggle_pix <= req_seen_pix;
            end
        end
    end
endmodule
