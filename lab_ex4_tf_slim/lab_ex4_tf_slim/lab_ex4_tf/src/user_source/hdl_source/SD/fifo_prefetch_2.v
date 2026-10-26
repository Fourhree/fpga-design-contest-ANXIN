// Two output registers absorb the synchronous RAM's read latency.
module fifo_prefetch_2 #(parameter DATA_WIDTH=32)(
    input clk, rst, raw_empty, raw_valid,
    input [DATA_WIDTH-1:0] raw_data,
    output raw_read_en,
    input consume,
    output out_valid, out_empty,
    output [DATA_WIDTH-1:0] out_data,
    output [1:0] buffered_words
);
reg [DATA_WIDTH-1:0] words[0:1];
reg wr_ptr, rd_ptr, pending;
reg [1:0] count;
wire pop = consume && count != 0;
wire [2:0] reserved = {1'b0,count} + {2'd0,pending};
assign raw_read_en = !rst && !raw_empty && (reserved < 2 || (pop && reserved == 2));
assign out_valid = count != 0;
assign out_empty = count == 0;
assign out_data = words[rd_ptr];
assign buffered_words = count;
always @(posedge clk or posedge rst) begin
    if (rst) begin wr_ptr <= 0; rd_ptr <= 0; pending <= 0; count <= 0; end
    else begin
        pending <= raw_read_en;
        if (raw_valid) begin words[wr_ptr] <= raw_data; wr_ptr <= ~wr_ptr; end
        if (pop) rd_ptr <= ~rd_ptr;
        case ({raw_valid,pop})
            2'b10: count <= count + 1'b1;
            2'b01: count <= count - 1'b1;
            default: ;
        endcase
    end
end
endmodule
