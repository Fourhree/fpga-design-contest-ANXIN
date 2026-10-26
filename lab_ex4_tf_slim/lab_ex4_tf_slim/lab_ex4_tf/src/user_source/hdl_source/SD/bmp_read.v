module bmp_read #(
    parameter integer SD_READ_TIMEOUT_MS = 500,
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer PAUSE_ON_FOUND = 0
)(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input                       scan_resume,
    output reg                  scan_paused,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output [31:0]               scan_found_size,
    output reg [2:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input                       load_abort,
    input  [31:0]               load_sector,
    output reg [2:0]            bmp_error,
    output reg                  load_error,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,
    input                       sd_sec_read_error,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;
localparam ST_ABORT_WAIT = 3'd5;
localparam ST_LOAD_RELEASE = 3'd6;

localparam [2:0] ERR_NONE      = 3'd0;
localparam [2:0] ERR_HEADER    = 3'd1;
localparam [2:0] ERR_TIMEOUT   = 3'd2;
localparam [2:0] ERR_TRUNCATED = 3'd3;
// Widen before multiplying: 500 * 100 MHz exceeds 32 bits.
localparam [63:0] TIMEOUT_CYCLES = (64'd1 * SD_READ_TIMEOUT_MS * CLK_FREQ_HZ) / 1000;
localparam integer TIMEOUT_CNT_BITS = (TIMEOUT_CYCLES < 2) ? 1 : $clog2(TIMEOUT_CYCLES + 1);
reg [TIMEOUT_CNT_BITS-1:0] sd_timeout_cnt;
reg [31:0] pixel_count;
wire [31:0] expected_pixels = bmp_width * bmp_height;
// Include the registered pixel being delivered on this clock edge.
wire [31:0] delivered_pixels = pixel_count + {31'd0, bmp_data_wr_en};

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] dib_size;
reg [31:0] width;
reg [31:0] height;
reg [15:0] planes;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;

wire header_match;
wire bmp_data_valid;
reg [31:0] file_sector_count;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;

assign ready = (state == ST_IDLE);
assign scan_found_size = file_len;
assign header_match = (header_0 == "B") &&
                      (header_1 == "M") &&
                      (dib_size >= 32'd40) &&
                      (width[15:0]  == bmp_width) &&
                      (height[15:0] == bmp_height) &&
                      (planes == 16'd1) &&
                      (bit_count    == 16'd24) &&
                      (compression  == 32'd0) &&
                      (pixel_offset >= 32'd54) &&
                      (pixel_offset < file_len) &&
                      (file_len >= pixel_offset + bmp_width * bmp_height * 3);
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt <  file_len);
// Header length is stable hundreds of clocks before the end of its sector.
// Register this calculation to avoid two cascaded 32-bit additions when
// advancing the catalog scan at 100 MHz.
always @(posedge clk or posedge rst) begin
    if (rst)
        file_sector_count <= 32'd1;
    else
        file_sector_count <= (file_len == 32'd0) ? 32'd1 :
                             ((file_len >> 9) + ((file_len[8:0] != 9'd0) ? 32'd1 : 32'd0));
end
assign next_scan_sector_if_match = scan_sector + file_sector_count;
assign next_scan_sector_if_miss  = scan_sector +
    (((header_0 == "B") && (header_1 == "M") && (rd_cnt == 10'd512)) ? file_sector_count : 32'd1);

// Each sector has its own deadline, rather than timing the whole frame/scan.
always @(posedge clk or posedge rst) begin
    if (rst)
        sd_timeout_cnt <= 0;
    else if (!sd_init_done || load_abort || sd_sec_read_end ||
             ((state != ST_SCAN) && (state != ST_LOAD_HDR) && (state != ST_LOAD_DATA)))
        sd_timeout_cnt <= 0;
    else if (sd_timeout_cnt < TIMEOUT_CYCLES)
        sd_timeout_cnt <= sd_timeout_cnt + 1'b1;
end

always @(posedge clk or posedge rst) begin
    if (rst)
        pixel_count <= 32'd0;
    else if (!sd_init_done || load_abort || (state == ST_LOAD_HDR))
        pixel_count <= 32'd0;
    else if ((state == ST_LOAD_DATA) && bmp_data_wr_en)
        pixel_count <= pixel_count + 32'd1;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR) || (state == ST_LOAD_DATA)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        dib_size     <= 32'd0;
        width        <= 32'd0;
        height       <= 32'd0;
        planes       <= 16'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd14: dib_size[7:0] <= sd_sec_read_data;
            10'd15: dib_size[15:8] <= sd_sec_read_data;
            10'd16: dib_size[23:16] <= sd_sec_read_data;
            10'd17: dib_size[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd26: planes[7:0] <= sd_sec_read_data;
            10'd27: planes[15:8] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid)
            bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid) begin
            case (bmp_byte_idx)
                2'd0: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[7:0]  <= sd_sec_read_data;
                end
                2'd1: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[15:8] <= sd_sec_read_data;
                end
                2'd2: begin
                    bmp_data_wr_en  <= 1'b1;
                    bmp_data[23:16] <= sd_sec_read_data;
                end
                default: begin
                    bmp_data_wr_en <= 1'b0;
                end
            endcase
        end else begin
            bmp_data_wr_en <= 1'b0;
        end
    end else begin
        bmp_data_wr_en <= 1'b0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_paused       <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        bmp_error         <= ERR_NONE;
        load_error        <= 1'b0;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_paused       <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        bmp_error         <= ERR_NONE;
        load_error        <= 1'b0;
    end else if (load_abort) begin
        // Abort only this picture, keeping the scanned catalog available
        // for KEY1/KEY2 and slideshow. Drain an in-flight SPI sector before
        // accepting another header, so its trailing bytes cannot corrupt it.
        state            <= (sd_sec_read && !sd_sec_read_end) ? ST_ABORT_WAIT : ST_IDLE;
        state_code       <= 4'd1;
        sd_sec_read      <= 1'b0;
        write_req        <= 1'b0;
        scan_found_valid <= 1'b0;
        load_error       <= 1'b0;
    end else begin
        scan_found_valid <= 1'b0;
        load_error       <= 1'b0;

        case (state)
            ST_ABORT_WAIT: begin
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
                if (sd_sec_read_end)
                    state <= ST_IDLE;
            end

            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    bmp_error        <= ERR_NONE;
                    scan_done        <= 1'b0;
                    scan_paused      <= 1'b0;
                    scan_found_total <= 3'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    bmp_error           <= ERR_NONE;
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end else if (scan_resume && scan_paused) begin
                    // Continue the catalog after the discovered image has
                    // been loaded, without rescanning earlier sectors.
                    bmp_error        <= ERR_NONE;
                    scan_paused      <= 1'b0;
                    sd_sec_read_addr <= scan_sector;
                    state            <= ST_SCAN;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (sd_sec_read_error) begin
                        bmp_error <= ERR_TIMEOUT;
                        load_error <= 1'b1;
                        // Keep pictures found before a card failure usable.
                        scan_done <= 1'b1;
                        state <= ST_IDLE;
                    end else if (header_match && rd_cnt == 10'd512) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;

                        if ((scan_found_total + 3'd1 >= scan_target_count) || (next_scan_sector_if_match > scan_max_sector)) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                            if (PAUSE_ON_FOUND != 0) begin
                                // Let the player show/cache this picture
                                // before searching the rest of the card.
                                scan_paused <= 1'b1;
                                state       <= ST_IDLE;
                            end
                        end
                    end else begin
                        if ((scan_sector >= scan_max_sector) ||
                            (next_scan_sector_if_miss > scan_max_sector) ||
                            (next_scan_sector_if_miss <= scan_sector)) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                        end
                    end
                end else if (sd_timeout_cnt >= TIMEOUT_CYCLES) begin
                    bmp_error   <= ERR_TIMEOUT;
                    load_error  <= 1'b1;
                    scan_done   <= 1'b1;
                    sd_sec_read <= 1'b0;
                    state       <= ST_IDLE;
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (!sd_sec_read_error && header_match && rd_cnt == 10'd512) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        bmp_error <= sd_sec_read_error ? ERR_TIMEOUT : ERR_HEADER;
                        load_error <= 1'b1;
                        state <= ST_IDLE;
                    end
                end else if (sd_timeout_cnt >= TIMEOUT_CYCLES) begin
                    bmp_error   <= ERR_TIMEOUT;
                    load_error  <= 1'b1;
                    sd_sec_read <= 1'b0;
                    state       <= ST_IDLE;
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_RELEASE;
                end
            end

            ST_LOAD_RELEASE: begin
                // Wait until the memory-side FIFO reset/ack has been
                // released before supplying pixels across the clock domains.
                if (!write_req_ack)
                    state <= ST_LOAD_DATA;
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (sd_sec_read_error) begin
                        bmp_error <= ERR_TIMEOUT;
                        load_error <= 1'b1;
                        state <= ST_IDLE;
                    end else if ((rd_cnt != 10'd512) ||
                                 ((bmp_len_cnt >= file_len) && (delivered_pixels != expected_pixels))) begin
                        bmp_error <= ERR_TRUNCATED;
                        load_error <= 1'b1;
                        state <= ST_IDLE;
                    end else if (bmp_len_cnt >= file_len) begin
                        state <= ST_IDLE;
                    end else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    end
                end else if (sd_timeout_cnt >= TIMEOUT_CYCLES) begin
                    bmp_error   <= ERR_TIMEOUT;
                    load_error  <= 1'b1;
                    sd_sec_read <= 1'b0;
                    state       <= ST_IDLE;
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
