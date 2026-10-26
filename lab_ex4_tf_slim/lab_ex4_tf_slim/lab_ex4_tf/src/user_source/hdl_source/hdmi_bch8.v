`timescale 1ns/1ps

module hdmi_bch8 #(
    parameter integer DATA_BYTES = 3
) (
    input  wire [DATA_BYTES*8-1:0] data,
    output reg  [7:0]              ecc
);
    integer byte_index;
    integer bit_index;
    reg [7:0] remainder;
    reg feedback;

    // HDMI transmits packet bytes least-significant bit first. For
    // G(x)=1+x^6+x^7+x^8, the reflected feedback polynomial is 8'h83.
    always @* begin
        remainder = 8'h00;
        feedback = 1'b0;
        for (byte_index = 0; byte_index < DATA_BYTES;
             byte_index = byte_index + 1) begin
            for (bit_index = 0; bit_index < 8;
                 bit_index = bit_index + 1) begin
                feedback = data[byte_index*8 + bit_index] ^ remainder[0];
                remainder = {1'b0, remainder[7:1]};
                if (feedback)
                    remainder = remainder ^ 8'h83;
            end
        end
        ecc = remainder;
    end
endmodule
