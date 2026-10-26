`timescale 1ns/1ps

// Bundled-data mailbox. The source holds the complete parameter pair until
// the pixel domain applies it at vertical blanking and acknowledges it.
module param_config_service (
    input wire ctrl_clk,
    input wire ctrl_rst_n,
    input wire update_valid,
    input wire [7:0] brightness_in,
    input wire [7:0] contrast_in,
    output wire ready,
    input wire pix_clk,
    input wire pix_rst_n,
    input wire frame_start,
    output reg [7:0] brightness_frame,
    output reg [7:0] contrast_frame
);
    reg [15:0] held_params;
    reg request_toggle;
    reg applied_toggle;
    (* async_reg = "true" *) reg ack_sync_ff1, ack_sync_ff2;
    (* async_reg = "true" *) reg req_sync_ff1, req_sync_ff2;
    reg req_sync_q;
    reg [15:0] params_pix1, params_pix2;
    assign ready = request_toggle == ack_sync_ff2;

    always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            held_params <= 16'hc080;
            request_toggle <= 1'b0;
            ack_sync_ff1 <= 1'b0;
            ack_sync_ff2 <= 1'b0;
        end else begin
            ack_sync_ff1 <= applied_toggle;
            ack_sync_ff2 <= ack_sync_ff1;
            if (update_valid && ready) begin
                held_params <= {brightness_in, contrast_in};
                request_toggle <= !request_toggle;
            end
        end
    end

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            req_sync_ff1 <= 1'b0;
            req_sync_ff2 <= 1'b0;
            req_sync_q <= 1'b0;
            params_pix1 <= 16'hc080;
            params_pix2 <= 16'hc080;
            applied_toggle <= 1'b0;
            brightness_frame <= 8'd192;
            contrast_frame <= 8'd128;
        end else begin
            req_sync_ff1 <= request_toggle;
            req_sync_ff2 <= req_sync_ff1;
            req_sync_q <= req_sync_ff2;
            params_pix1 <= held_params;
            params_pix2 <= params_pix1;
            // The extra request stage gives the held data time to settle.
            if (frame_start && req_sync_q != applied_toggle) begin
                brightness_frame <= params_pix2[15:8];
                contrast_frame <= params_pix2[7:0];
                applied_toggle <= req_sync_q;
            end
        end
    end
endmodule
