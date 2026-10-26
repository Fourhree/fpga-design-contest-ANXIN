// START, RGB and terminal markers share one FIFO, preserving their order
// across the independent 50 MHz SD and 100 MHz SDRAM clocks.
module media_pixel_cdc (
    input sd_clk, sd_rst_n, mem_clk, mem_rst_n,
    input source_start,
    input [2:0] source_index,
    input [15:0] source_width, source_height,
    input source_bottom_up,
    input source_pixel_valid,
    input [23:0] source_pixel_rgb,
    input source_commit,
    input [7:0] source_error,
    output reg load_start,
    output reg [2:0] image_index,
    output reg [15:0] image_width, image_height,
    output reg image_bottom_up,
    output reg pixel_valid,
    output reg [23:0] pixel_rgb,
    output reg frame_commit,
    output reg [7:0] decode_error
);
wire fifo_rst = !sd_rst_n || !mem_rst_n;
wire fifo_full, fifo_empty, fifo_valid;
wire [63:0] fifo_data;
reg terminal_pending;
reg [7:0] pending_error;
reg overflow_sd;
reg overflow_mem1, overflow_mem2;
wire terminal_now = source_commit || source_error != 0;
wire fifo_we = source_start || source_pixel_valid || terminal_pending || terminal_now;
wire [1:0] token = source_start ? 2'd1 : source_pixel_valid ? 2'd0 :
                  ((terminal_pending ? pending_error : source_error) != 0 ? 2'd3 : 2'd2);
wire [23:0] payload = source_start ? {21'd0,source_index} :
                      source_pixel_valid ? source_pixel_rgb :
                      {16'd0,(terminal_pending ? pending_error : source_error)};
always @(posedge sd_clk or posedge fifo_rst) begin
    if (fifo_rst) begin
        terminal_pending <= 0; pending_error <= 0; overflow_sd <= 0;
    end else begin
        if (terminal_pending && !source_pixel_valid && !source_start)
            terminal_pending <= 0;
        if (terminal_now && (source_pixel_valid || source_start)) begin
            terminal_pending <= 1;
            pending_error <= source_error;
        end
        if (fifo_we && fifo_full) overflow_sd <= 1;
    end
end
always @(posedge mem_clk or posedge fifo_rst) begin
    if (fifo_rst) begin overflow_mem1 <= 0; overflow_mem2 <= 0; end
    else begin overflow_mem1 <= overflow_sd; overflow_mem2 <= overflow_mem1; end
end
rfifo_32_32_512 #(.DATA_WIDTH_W(64),.DATA_WIDTH_R(64)) u_stream_fifo (
    .rst(fifo_rst), .clkw(sd_clk), .clkr(mem_clk),
    .we(fifo_we), .di({5'd0,source_bottom_up,source_height,source_width,token,payload}), .re(!fifo_empty),
    .dout(fifo_data), .valid(fifo_valid), .full_flag(fifo_full),
    .empty_flag(fifo_empty), .afull(), .aempty(), .wrusedw(), .rdusedw()
);
// Decode the synchronous FIFO output into a registered loader interface.
// All markers and their payloads take the same extra cycle, preserving order
// while removing the BRAM output delay from the loader's write-enable path.
always @(posedge mem_clk or posedge fifo_rst) begin
    if (fifo_rst) begin
        load_start<=0; image_index<=0; image_width<=0; image_height<=0;
        image_bottom_up<=0; pixel_valid<=0; pixel_rgb<=0;
        frame_commit<=0; decode_error<=0;
    end else begin
        load_start <= fifo_valid && fifo_data[25:24] == 1;
        image_index <= fifo_data[2:0];
        image_width <= fifo_data[41:26];
        image_height <= fifo_data[57:42];
        image_bottom_up <= fifo_data[58];
        pixel_valid <= fifo_valid && fifo_data[25:24] == 0;
        pixel_rgb <= fifo_data[23:0];
        frame_commit <= fifo_valid && fifo_data[25:24] == 2;
        decode_error <= overflow_mem2 ? 8'h81 :
                        (fifo_valid && fifo_data[25:24] == 3 ? fifo_data[7:0] : 8'd0);
    end
end
endmodule
