`timescale 1ns/1ps

module tb_hdmi_audio_format;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    wire [223:0] body;
    wire [23:0] header;
    wire [3:0] channel0;
    reg [4:0] pixel_index = 0;
    integer errors = 0;
    reg test_pass = 0;
    integer i;

    hdmi_audio_acr_packetizer acr (
        .clk(clk), .rst_n(rst_n), .packet_ready(1'b0),
        .packet_header(header), .packet_body(body), .packet_valid(),
        .packet_header_ecc(), .packet_body_ecc()
    );
    hdmi_data_island_mapper mapper (
        .pixel_index(pixel_index), .hsync(1'b1), .vsync(1'b0),
        .packet_header(24'h123456), .packet_header_ecc(8'h78),
        .packet_body(224'd0), .packet_body_ecc(32'd0),
        .channel0_terc4(channel0), .channel1_terc4(), .channel2_terc4()
    );

    initial begin
        #20 rst_n = 1;
        #1;
        // HDMI ACR SB0 is reserved; SB1..3 hold CTS MSB first,
        // SB4..6 hold N MSB first. The mapper transmits SB0 first.
        // 25 MHz / 48 kHz: CTS=25000 (0x061a8), N=6144 (0x01800).
        for (i = 0; i < 4; i = i + 1) begin
            if (body[i*56 +: 56] !== 56'h001800a8610000) begin
                $display("FAIL: ACR subpacket %0d has bytes %h", i, body[i*56 +: 56]);
                errors = errors + 1;
            end
        end
        if (header !== 24'h000001) errors = errors + 1;
        for (i = 0; i < 32; i = i + 1) begin
            pixel_index = i;
            #1;
            if (channel0[3] !== (i != 0)) begin
                $display("FAIL: HDMI packet boundary bit at pixel %0d", i);
                errors = errors + 1;
            end
        end
        if (errors != 0) $fatal(1, "HDMI format: %0d errors", errors);
        $display("PASS: HDMI ACR bytes and data-island packet boundary");
        test_pass = 1;
        $finish;
    end
endmodule
