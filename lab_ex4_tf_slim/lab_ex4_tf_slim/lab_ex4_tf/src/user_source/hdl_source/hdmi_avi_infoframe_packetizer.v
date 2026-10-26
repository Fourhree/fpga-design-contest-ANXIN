`timescale 1ns/1ps

module hdmi_avi_infoframe_packetizer (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         emit,
    output reg          packet_valid,
    input  wire         packet_ready,
    output wire [23:0]  packet_header,
    output wire [7:0]   packet_header_ecc,
    output wire [223:0] packet_body,
    output wire [31:0]  packet_body_ecc
);
    wire [7:0] ecc0, ecc1, ecc2, ecc3;

    // AVI InfoFrame v2, RGB, 640x480 (VIC 1); PB0 includes the
    // checksum over HB0..HB2 and PB1..PB13.
    assign packet_header = 24'h0d0282;
    assign packet_body = {184'd0, 8'h01, 24'd0, 8'h6e};

    hdmi_bch8 #(.DATA_BYTES(3)) u_header_bch (
        .data(packet_header), .ecc(packet_header_ecc)
    );
    hdmi_bch8 #(.DATA_BYTES(7)) u_body0_bch (
        .data(packet_body[55:0]), .ecc(ecc0)
    );
    hdmi_bch8 #(.DATA_BYTES(7)) u_body1_bch (
        .data(packet_body[111:56]), .ecc(ecc1)
    );
    hdmi_bch8 #(.DATA_BYTES(7)) u_body2_bch (
        .data(packet_body[167:112]), .ecc(ecc2)
    );
    hdmi_bch8 #(.DATA_BYTES(7)) u_body3_bch (
        .data(packet_body[223:168]), .ecc(ecc3)
    );
    assign packet_body_ecc = {ecc3, ecc2, ecc1, ecc0};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            packet_valid <= 1'b0;
        else if (packet_valid) begin
            if (packet_ready)
                packet_valid <= 1'b0;
        end else if (emit)
            packet_valid <= 1'b1;
    end
endmodule
