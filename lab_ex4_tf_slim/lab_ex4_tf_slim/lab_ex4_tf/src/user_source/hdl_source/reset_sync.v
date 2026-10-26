`timescale 1ns / 1ps

module reset_sync (
    input  wire clk,
    input  wire ext_rst_n,
    output wire rst_n_sync
);

    (* async_reg = "true" *) reg sync_ff1;
    (* async_reg = "true" *) reg sync_ff2;

    always @(posedge clk or negedge ext_rst_n) begin
        if (!ext_rst_n) begin
            sync_ff1 <= 1'b0;
            sync_ff2 <= 1'b0;
        end else begin
            sync_ff1 <= 1'b1;
            sync_ff2 <= sync_ff1;
        end
    end

    assign rst_n_sync = sync_ff2;

endmodule
