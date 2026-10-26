// BMP validation and pixel delivery over the FAT32 byte stream. Read the
// header sector first, then restart after the SDRAM FIFO reset handshake.
module bmp_fat_reader #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer MAX_PIXELS = 307200,
    parameter integer STRETCH_TO_DISPLAY = 0
)(
    input clk, rst, load_start, load_abort,
    input [31:0] load_cluster, load_file_size,
    input [7:0] sectors_per_cluster,
    input [31:0] fat_start_lba, data_start_lba, max_cluster,
    input [15:0] bmp_width, bmp_height,
    output [15:0] decoded_width, decoded_height,
    output decoded_bottom_up,
    output ready,
    output reg [2:0] bmp_error,
    output reg load_error,
    output reg write_req,
    input write_req_ack,
    output wire bmp_data_wr_en,
    output wire [23:0] bmp_data,
    output reg frame_commit,
    output sector_req,
    output [31:0] sector_lba,
    input sector_busy, sector_valid, sector_done,
    input [7:0] sector_byte, sector_error,
    input [8:0] sector_byte_index
);
localparam IDLE=4'd0, HEADER=4'd1, VALIDATE_GEOM=4'd2, VALIDATE_CAP=4'd3,
           VALIDATE_SIZE=4'd4, WAIT_ACK=4'd5, RELEASE=4'd6, DATA=4'd7, FINISH_SCALE=4'd8;
reg [3:0] state;
reg raw_pixel_valid;
reg [23:0] raw_pixel;
wire scaled_valid, scale_ready, scale_done;
wire [23:0] scaled_pixel;
reg stream_start;
reg [31:0] cluster_latched, size_latched;
wire stream_rst = rst || load_abort || state == IDLE || state == WAIT_ACK || state == RELEASE;
wire file_done, file_valid, file_sector_done;
wire [7:0] file_byte, fs_error;
wire [31:0] file_offset;
reg [7:0] signature0, signature1;
reg [31:0] file_len, pixel_offset, dib_size, width, height, compression;
reg [15:0] planes, bit_count;
reg [31:0] pixel_count, row_byte, row_pixels_bytes, row_stride, expected_pixels;
reg [63:0] required_bytes;
reg [1:0] byte_phase;
wire [31:0] abs_height = height[31] ? (~height + 32'd1) : height;
assign decoded_width = STRETCH_TO_DISPLAY ? 16'd640 : width[15:0];
assign decoded_height = STRETCH_TO_DISPLAY ? 16'd480 : abs_height[15:0];
assign decoded_bottom_up = !height[31];
assign bmp_data_wr_en = STRETCH_TO_DISPLAY ? scaled_valid : raw_pixel_valid;
assign bmp_data = STRETCH_TO_DISPLAY ? scaled_pixel : raw_pixel;
generate if (STRETCH_TO_DISPLAY) begin : stretch
    bmp_stream_stretch scaler (
        .clk(clk), .rst(rst || load_abort || state==IDLE),
        .start(state==RELEASE && !write_req_ack),
        .source_width(width[15:0]), .source_height(abs_height[15:0]),
        .bottom_up(!height[31]), .in_valid(raw_pixel_valid), .in_rgb(raw_pixel),
        .in_ready(scale_ready), .out_valid(scaled_valid), .out_rgb(scaled_pixel),
        .output_done(scale_done)
    );
end else begin : native
    assign scale_ready=1'b1;
    assign scale_done=1'b1;
    assign scaled_valid=1'b0;
    assign scaled_pixel=24'd0;
end endgenerate
wire basic_header_match = signature0 == "B" && signature1 == "M" &&
    dib_size >= 40 && width != 0 && width <= 65535 &&
    abs_height != 0 && abs_height <= 65535 &&
    (STRETCH_TO_DISPLAY || bmp_width == 0 || width == {16'd0,bmp_width}) &&
    (STRETCH_TO_DISPLAY || bmp_height == 0 || abs_height == {16'd0,bmp_height}) &&
    planes == 1 && bit_count == 24 && compression == 0 &&
    pixel_offset >= 14 + {32'd0,dib_size} && pixel_offset < file_len && file_len <= size_latched;
assign ready = state == IDLE;

fat32_file_streamer #(.BUFFERED_DELIVERY(STRETCH_TO_DISPLAY)) streamer (
    .clk(clk), .rst_n(~stream_rst), .file_start(stream_start),
    .data_enable(state == HEADER || state == DATA),
    .file_ready(state==HEADER || (state==DATA && scale_ready && !raw_pixel_valid)),
    .first_cluster(cluster_latched), .file_size(size_latched),
    .sectors_per_cluster(sectors_per_cluster), .fat_start_lba(fat_start_lba),
    .data_start_lba(data_start_lba), .max_cluster(max_cluster),
    .file_busy(), .file_done(file_done), .file_valid(file_valid), .file_byte(file_byte),
    .file_byte_offset(file_offset), .file_sector_done(file_sector_done), .fs_error(fs_error),
    .sector_req(sector_req), .sector_lba(sector_lba), .sector_busy(sector_busy),
    .sector_valid(sector_valid), .sector_byte(sector_byte),
    .sector_byte_index(sector_byte_index), .sector_done(sector_done), .sector_error(sector_error)
);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= IDLE;
        stream_start <= 0;
        cluster_latched <= 0; size_latched <= 0;
        bmp_error <= 0; load_error <= 0; write_req <= 0;
        raw_pixel_valid <= 0; raw_pixel <= 0; frame_commit <= 0;
        signature0 <= 0; signature1 <= 0;
        file_len <= 0; pixel_offset <= 0; dib_size <= 0;
        width <= 0; height <= 0; planes <= 0; bit_count <= 0; compression <= 0;
        pixel_count <= 0; row_byte <= 0; byte_phase <= 0;
        row_pixels_bytes<=0; row_stride<=0; expected_pixels<=0; required_bytes<=0;
    end else begin
        stream_start <= 0;
        load_error <= 0;
        raw_pixel_valid <= 0;
        frame_commit <= 0;
        if (load_abort) begin
            state <= IDLE;
            write_req <= 0;
        end else begin
            if (state == HEADER && file_valid) begin
                case (file_offset)
                    0: signature0 <= file_byte;
                    1: signature1 <= file_byte;
                    2: file_len[7:0] <= file_byte;
                    3: file_len[15:8] <= file_byte;
                    4: file_len[23:16] <= file_byte;
                    5: file_len[31:24] <= file_byte;
                    10: pixel_offset[7:0] <= file_byte;
                    11: pixel_offset[15:8] <= file_byte;
                    12: pixel_offset[23:16] <= file_byte;
                    13: pixel_offset[31:24] <= file_byte;
                    14: dib_size[7:0] <= file_byte;
                    15: dib_size[15:8] <= file_byte;
                    16: dib_size[23:16] <= file_byte;
                    17: dib_size[31:24] <= file_byte;
                    18: width[7:0] <= file_byte;
                    19: width[15:8] <= file_byte;
                    20: width[23:16] <= file_byte;
                    21: width[31:24] <= file_byte;
                    22: height[7:0] <= file_byte;
                    23: height[15:8] <= file_byte;
                    24: height[23:16] <= file_byte;
                    25: height[31:24] <= file_byte;
                    26: planes[7:0] <= file_byte;
                    27: planes[15:8] <= file_byte;
                    28: bit_count[7:0] <= file_byte;
                    29: bit_count[15:8] <= file_byte;
                    30: compression[7:0] <= file_byte;
                    31: compression[15:8] <= file_byte;
                    32: compression[23:16] <= file_byte;
                    33: compression[31:24] <= file_byte;
                    default: ;
                endcase
            end
            case (state)
                IDLE: if (load_start) begin
                    cluster_latched <= load_cluster;
                    size_latched <= load_file_size;
                    bmp_error <= 0;
                    signature0 <= 0; signature1 <= 0;
                    file_len <= 0; pixel_offset <= 0; dib_size <= 0;
                    width <= 0; height <= 0; planes <= 0; bit_count <= 0; compression <= 0;
                    pixel_count <= 0; row_byte <= 0; byte_phase <= 0;
                    row_pixels_bytes<=0; row_stride<=0; expected_pixels<=0; required_bytes<=0;
                    stream_start <= 1;
                    state <= HEADER;
                end
                HEADER: begin
                    if (file_sector_done) begin
                        if (sector_error != 0) begin
                            bmp_error <= 3'd2;
                            load_error <= 1;
                            state <= IDLE;
                        end else begin
                            state <= VALIDATE_GEOM;
                        end
                    end else if (file_done) begin
                        bmp_error <= fs_error == 8'h10 ? 3'd2 : 3'd1;
                        load_error <= 1;
                        state <= IDLE;
                    end
                end
                VALIDATE_GEOM: begin
                    if (!basic_header_match) begin
                        bmp_error<=3'd1; load_error<=1; state<=IDLE;
                    end else begin
                        row_pixels_bytes<=width*32'd3;
                        row_stride<=((width*32'd3)+32'd3)&32'hfffffffc;
                        expected_pixels<=width*abs_height;
                        state<=VALIDATE_CAP;
                    end
                end
                VALIDATE_CAP: begin
                    if (!STRETCH_TO_DISPLAY && expected_pixels>MAX_PIXELS) begin
                        bmp_error<=3'd4; load_error<=1; state<=IDLE;
                    end else begin
                        required_bytes<={32'd0,row_stride}*{32'd0,abs_height};
                        state<=VALIDATE_SIZE;
                    end
                end
                VALIDATE_SIZE: begin
                    if ({32'd0,file_len-pixel_offset}<required_bytes) begin
                        bmp_error<=3'd1; load_error<=1; state<=IDLE;
                    end else begin
                        write_req<=1; state<=WAIT_ACK;
                    end
                end
                WAIT_ACK: if (write_req_ack) begin
                    write_req <= 0;
                    state <= RELEASE;
                end
                RELEASE: if (!write_req_ack) begin
                    stream_start <= 1;
                    state <= DATA;
                end
                DATA: begin
                    if (file_valid && file_offset >= pixel_offset &&
                        file_offset < file_len && pixel_count < expected_pixels) begin
                        row_byte <= row_byte == row_stride - 1 ? 0 : row_byte + 1'b1;
                        if (row_byte < row_pixels_bytes) begin
                            case (byte_phase)
                                0: raw_pixel[7:0] <= file_byte;
                                1: raw_pixel[15:8] <= file_byte;
                                2: begin
                                    raw_pixel[23:16] <= file_byte;
                                    raw_pixel_valid <= 1;
                                    pixel_count <= pixel_count + 1'b1;
                                end
                                default: ;
                            endcase
                            byte_phase <= byte_phase == 2 ? 0 : byte_phase + 1'b1;
                        end
                    end
                    if (file_done) begin
                        if (fs_error != 0 ||
                            pixel_count + ((file_valid && byte_phase == 2 &&
                            row_byte < row_pixels_bytes && file_offset >= pixel_offset &&
                            file_offset < file_len && pixel_count < expected_pixels) ? 32'd1 : 32'd0)
                            != expected_pixels) begin
                            bmp_error <= fs_error == 8'h10 ? 3'd2 : 3'd3;
                            load_error <= 1;
                            state <= IDLE;
                        end else begin
                            // Validated completion, after the final RGB output. IDLE/ready
                            // alone also occurs at reset, abort and decode failure.
                            if (STRETCH_TO_DISPLAY) state<=FINISH_SCALE;
                            else begin frame_commit<=1; state<=IDLE; end
                        end
                    end
                end
                FINISH_SCALE: if (scale_done) begin frame_commit<=1; state<=IDLE; end
                default: state <= IDLE;
            endcase
        end
    end
end
endmodule
