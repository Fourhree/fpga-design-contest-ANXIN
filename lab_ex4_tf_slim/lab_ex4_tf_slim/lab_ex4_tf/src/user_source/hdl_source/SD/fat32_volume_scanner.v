`timescale 1ns/1ps

module fat32_volume_scanner (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    output reg  [5:0]  resource_valid,
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] resource4_cluster,
    output reg  [31:0] resource5_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
    output reg  [31:0] resource4_size,
    output reg  [31:0] resource5_size,
    output reg         wav1_valid,
    output reg  [31:0] wav1_cluster,
    output reg  [31:0] wav1_size,
    output reg         wav_valid,
    output reg  [31:0] wav_cluster,
    output reg  [31:0] wav_size,
    output reg         wav2_valid,
    output reg  [31:0] wav2_cluster,
    output reg  [31:0] wav2_size,
    output reg         wav3_valid,
    output reg  [31:0] wav3_cluster,
    output reg  [31:0] wav3_size,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);

    localparam ERR_NONE            = 8'h00;
    localparam ERR_SECTOR          = 8'h10;
    localparam ERR_BOOT_SIGNATURE  = 8'h20;
    localparam ERR_UNSUPPORTED_BPB = 8'h21;
    localparam ERR_RESOURCE_MISSING= 8'h22;

    localparam ST_IDLE       = 4'd0;
    localparam ST_READ0_REQ  = 4'd1;
    localparam ST_READ0_WAIT = 4'd2;
    localparam ST_BOOT_PARSE = 4'd3;
    localparam ST_BOOT_REQ   = 4'd4;
    localparam ST_BOOT_WAIT  = 4'd5;
    localparam ST_ROOT_REQ   = 4'd6;
    localparam ST_ROOT_WAIT  = 4'd7;
    localparam ST_DIR_SCAN   = 4'd8;
    localparam ST_FINISH     = 4'd9;
    localparam ST_BOOT_LAYOUT= 4'd10;
    localparam ST_BOOT_ROOT  = 4'd11;
    localparam ST_ROOT_FAT_REQ = 4'd12;
    localparam ST_ROOT_FAT_WAIT = 4'd13;
    localparam ST_ROOT_FAT_PARSE = 4'd14;

    reg [3:0] state;
    reg [7:0] sector_buffer [0:511];
    reg [4:0] directory_entry_index;
    reg [31:0] root_cluster;
    reg [31:0] total_sectors;
    reg [31:0] fat_sectors;
    reg [7:0] fat_count;
    reg [15:0] reserved_sectors;
    reg [31:0] root_lba;
    reg [31:0] data_sector_count;
    reg [31:0] fat_span;
    reg [2:0] sectors_per_cluster_shift;
    reg [7:0] dir_name0;
    reg [7:0] dir_name1;
    reg [7:0] dir_name2;
    reg [7:0] dir_name3;
    reg [7:0] dir_name4;
    reg [7:0] dir_name5;
    reg [7:0] dir_name6;
    reg [7:0] dir_name7;
    reg [7:0] dir_name8;
    reg [7:0] dir_name9;
    reg [7:0] dir_name10;
    reg       dir_entry_match;
    reg       dir_wav_match;
    reg [1:0] dir_wav_index;
    reg [2:0] dir_resource_index;
    reg [15:0] dir_cluster_high;
    reg [15:0] dir_cluster_low;
    reg [31:0] dir_file_size;
    reg [2:0] resource_count;
    reg [7:0] root_sector_index;
    reg [13:0] root_clusters_visited;
    reg directory_end;
    reg [7:0] root_fat0, root_fat1, root_fat2, root_fat3;
    wire [8:0] root_fat_offset = {root_cluster[6:0], 2'b00};
    wire [31:0] root_next_cluster = {4'd0, root_fat3[3:0], root_fat2, root_fat1, root_fat0};

    assign scan_busy = (state != ST_IDLE);

    function [15:0] le16;
        input integer offset;
        begin
            le16 = {sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function [31:0] le32;
        input integer offset;
        begin
            le32 = {sector_buffer[offset+3], sector_buffer[offset+2],
                    sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function valid_spc;
        input [7:0] value;
        begin
            valid_spc = value != 0 && ((value & (value - 1'b1)) == 0);
        end
    endfunction

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                8'd2:   spc_shift = 3'd1;
                8'd4:   spc_shift = 3'd2;
                8'd8:   spc_shift = 3'd3;
                8'd16:  spc_shift = 3'd4;
                8'd32:  spc_shift = 3'd5;
                8'd64:  spc_shift = 3'd6;
                8'd128: spc_shift = 3'd7;
                default: spc_shift = 3'd0;
            endcase
        end
    endfunction

    function [2:0] matching_resource;
        input integer base;
        begin
            if (sector_buffer[base+0] == "P" && sector_buffer[base+1] == "I" &&
                sector_buffer[base+2] == "C" && sector_buffer[base+3] == "1" &&
                sector_buffer[base+8] == "B" && sector_buffer[base+9] == "M" &&
                sector_buffer[base+10] == "P")
                matching_resource = 3'd0;
            else if (sector_buffer[base+0] == "P" && sector_buffer[base+1] == "I" &&
                     sector_buffer[base+2] == "C" && sector_buffer[base+3] == "2" &&
                     sector_buffer[base+8] == "B" && sector_buffer[base+9] == "M" &&
                     sector_buffer[base+10] == "P")
                matching_resource = 3'd1;
            else if (sector_buffer[base+0] == "P" && sector_buffer[base+1] == "I" &&
                     sector_buffer[base+2] == "C" && sector_buffer[base+3] == "3" &&
                     sector_buffer[base+8] == "B" && sector_buffer[base+9] == "M" &&
                     sector_buffer[base+10] == "P")
                matching_resource = 3'd2;
            else if (sector_buffer[base+0] == "P" && sector_buffer[base+1] == "I" &&
                     sector_buffer[base+2] == "C" && sector_buffer[base+3] == "4" &&
                     sector_buffer[base+8] == "B" && sector_buffer[base+9] == "M" &&
                     sector_buffer[base+10] == "P")
                matching_resource = 3'd3;
            else if (sector_buffer[base+0] == "P" && sector_buffer[base+1] == "I" &&
                     sector_buffer[base+2] == "C" && sector_buffer[base+3] == "5" &&
                     sector_buffer[base+8] == "B" && sector_buffer[base+9] == "M" &&
                     sector_buffer[base+10] == "P")
                matching_resource = 3'd4;
            else
                matching_resource = 3'd5;
        end
    endfunction

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    task accept_directory_entry;
        input integer base;
        reg [2:0] resource_index;
        reg [31:0] first_cluster;
        reg [31:0] file_size;
        begin
            resource_index = matching_resource(base);
            first_cluster = {sector_buffer[base+21], sector_buffer[base+20],
                             sector_buffer[base+27], sector_buffer[base+26]};
            file_size = le32(base+28);
            case (resource_index)
                3'd0: begin
                    resource0_cluster <= first_cluster;
                    resource0_size <= file_size;
                    resource_valid[0] <= 1'b1;
                end
                3'd1: begin
                    resource1_cluster <= first_cluster;
                    resource1_size <= file_size;
                    resource_valid[1] <= 1'b1;
                end
                3'd2: begin
                    resource2_cluster <= first_cluster;
                    resource2_size <= file_size;
                    resource_valid[2] <= 1'b1;
                end
                3'd3: begin
                    resource3_cluster <= first_cluster;
                    resource3_size <= file_size;
                    resource_valid[3] <= 1'b1;
                end
                3'd4: begin
                    resource4_cluster <= first_cluster;
                    resource4_size <= file_size;
                    resource_valid[4] <= 1'b1;
                end
                default: begin
                    resource5_cluster <= first_cluster;
                    resource5_size <= file_size;
                    resource_valid[5] <= 1'b1;
                end
            endcase
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            scan_done <= 1'b0;
            fs_error <= ERR_NONE;
            partition_lba <= 32'd0;
            sectors_per_cluster <= 8'd0;
            fat_start_lba <= 32'd0;
            data_start_lba <= 32'd0;
            max_cluster <= 32'd0;
            resource_valid <= 6'd0;
            resource0_cluster <= 32'd0;
            resource1_cluster <= 32'd0;
            resource2_cluster <= 32'd0;
            resource3_cluster <= 32'd0;
            resource4_cluster <= 32'd0;
            resource5_cluster <= 32'd0;
            resource0_size <= 32'd0;
            resource1_size <= 32'd0;
            resource2_size <= 32'd0;
            resource3_size <= 32'd0;
            resource4_size <= 32'd0;
            resource5_size <= 32'd0;
            wav1_valid <= 0; wav1_cluster <= 0; wav1_size <= 0;
            wav_valid <= 0; wav_cluster <= 0; wav_size <= 0;
            wav2_valid <= 0; wav2_cluster <= 0; wav2_size <= 0;
            wav3_valid <= 0; wav3_cluster <= 0; wav3_size <= 0;
            dir_wav_match <= 0;
            dir_wav_index <= 0;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            directory_entry_index <= 5'd0;
            root_cluster <= 32'd0;
            total_sectors <= 32'd0;
            fat_sectors <= 32'd0;
            fat_count <= 8'd0;
            reserved_sectors <= 16'd0;
            root_lba <= 32'd0;
            data_sector_count <= 32'd0;
            fat_span <= 32'd0;
            sectors_per_cluster_shift <= 3'd0;
            dir_name0 <= 8'd0;
            dir_name1 <= 8'd0;
            dir_name2 <= 8'd0;
            dir_name3 <= 8'd0;
            dir_name4 <= 8'd0;
            dir_name5 <= 8'd0;
            dir_name6 <= 8'd0;
            dir_name7 <= 8'd0;
            dir_name8 <= 8'd0;
            dir_name9 <= 8'd0;
            dir_name10 <= 8'd0;
            dir_entry_match <= 1'b0;
            dir_resource_index <= 3'd5;
            dir_cluster_high <= 16'd0;
            dir_cluster_low <= 16'd0;
            dir_file_size <= 32'd0;
            resource_count <= 0;
            root_sector_index <= 0;
            root_clusters_visited <= 0;
            directory_end <= 0;
            root_fat0 <= 0; root_fat1 <= 0; root_fat2 <= 0; root_fat3 <= 0;
        end else begin
            scan_done <= 1'b0;
            sector_req <= 1'b0;
            if (sector_valid && (state == ST_READ0_WAIT || state == ST_BOOT_WAIT))
                sector_buffer[sector_byte_index] <= sector_byte;

            // Capture only this FAT entry, avoiding a 512-byte combinational
            // lookup mux in the 100 MHz SD clock domain.
            if (sector_valid && state == ST_ROOT_FAT_WAIT) begin
                if (sector_byte_index == root_fat_offset)
                    root_fat0 <= sector_byte;
                else if (sector_byte_index == root_fat_offset + 9'd1)
                    root_fat1 <= sector_byte;
                else if (sector_byte_index == root_fat_offset + 9'd2)
                    root_fat2 <= sector_byte;
                else if (sector_byte_index == root_fat_offset + 9'd3)
                    root_fat3 <= sector_byte;
            end

            if (sector_valid && state == ST_ROOT_WAIT) begin
                case (sector_byte_index[4:0])
                    5'd0: begin
                        dir_name0 <= sector_byte;
                        dir_entry_match <= 1'b0;
                        dir_wav_match <= 1'b0;
                        dir_wav_index <= 2'd0;
                        if (sector_byte == 0)
                            directory_end <= 1;
                    end
                    5'd1:  dir_name1 <= sector_byte;
                    5'd2:  dir_name2 <= sector_byte;
                    5'd3:  dir_name3 <= sector_byte;
                    5'd4:  dir_name4 <= sector_byte;
                    5'd5:  dir_name5 <= sector_byte;
                    5'd6:  dir_name6 <= sector_byte;
                    5'd7:  dir_name7 <= sector_byte;
                    5'd8:  dir_name8 <= sector_byte;
                    5'd9:  dir_name9 <= sector_byte;
                    5'd10: dir_name10 <= sector_byte;
                    5'd11: begin
                        if (!directory_end &&
                            dir_name0 != 0 && dir_name0 != 8'he5 &&
                            (sector_byte & 8'h18) == 0 && sector_byte != 8'h0f &&
                            dir_name0 == "A" && dir_name1 == "U" &&
                            dir_name2 == "D" && dir_name3 == "I" &&
                            dir_name4 == "O" &&
                            dir_name6 == " " && dir_name7 == " " &&
                            dir_name8 == "W" && dir_name9 == "A" && dir_name10 == "V") begin
                            if (dir_name5 == "1") begin
                                dir_wav_match <= 1'b1;
                                dir_wav_index <= 2'd0;
                            end else if (dir_name5 == "2") begin
                                dir_wav_match <= 1'b1;
                                dir_wav_index <= 2'd1;
                            end else if (dir_name5 == "3") begin
                                dir_wav_match <= 1'b1;
                                dir_wav_index <= 2'd2;
                            end else if (dir_name5 == "4") begin
                                dir_wav_match <= 1'b1;
                                dir_wav_index <= 2'd3;
                            end else if (dir_name5 == " " && !wav_valid) begin
                                // Keep the original AUDIO.WAV name valid for image 6.
                                dir_wav_match <= 1'b1;
                                dir_wav_index <= 2'd3;
                            end
                        end
                        // Accept ordinary BMP files regardless of their base
                        // name; skip deleted, LFN, directory and volume entries.
                        if (!directory_end && resource_count < 6 &&
                            dir_name0 != 0 && dir_name0 != 8'he5 &&
                            (sector_byte & 8'h18) == 0 && sector_byte != 8'h0f &&
                            dir_name8 == "B" && dir_name9 == "M" && dir_name10 == "P") begin
                            dir_entry_match <= 1'b1;
                            dir_resource_index <= resource_count;
                        end
                    end
                    5'd20: dir_cluster_high[7:0] <= sector_byte;
                    5'd21: dir_cluster_high[15:8] <= sector_byte;
                    5'd26: dir_cluster_low[7:0] <= sector_byte;
                    5'd27: dir_cluster_low[15:8] <= sector_byte;
                    5'd28: dir_file_size[7:0] <= sector_byte;
                    5'd29: dir_file_size[15:8] <= sector_byte;
                    5'd30: dir_file_size[23:16] <= sector_byte;
                    5'd31: begin
                        dir_file_size[31:24] <= sector_byte;
                        if (dir_wav_match &&
                            {dir_cluster_high[11:0], dir_cluster_low} >= 2 &&
                            {sector_byte, dir_file_size[23:0]} >= 44) begin
                            case (dir_wav_index)
                                2'd0: begin
                                    wav1_valid <= 1;
                                    wav1_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    wav1_size <= {sector_byte, dir_file_size[23:0]};
                                end
                                2'd1: begin
                                    wav2_valid <= 1;
                                    wav2_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    wav2_size <= {sector_byte, dir_file_size[23:0]};
                                end
                                2'd2: begin
                                    wav3_valid <= 1;
                                    wav3_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    wav3_size <= {sector_byte, dir_file_size[23:0]};
                                end
                                default: begin
                                    // Legacy WAV outputs carry image 6 (AUDIO.WAV/AUDIO4.WAV).
                                    wav_valid <= 1;
                                    wav_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    wav_size <= {sector_byte, dir_file_size[23:0]};
                                end
                            endcase
                        end
                        if (dir_entry_match && {dir_cluster_high[11:0], dir_cluster_low} >= 2 &&
                            {sector_byte, dir_file_size[23:0]} != 0) begin
                            resource_count <= resource_count + 1'b1;
                            case (dir_resource_index)
                                3'd0: begin
                                    resource0_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    resource0_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[0] <= 1'b1;
                                end
                                3'd1: begin
                                    resource1_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    resource1_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[1] <= 1'b1;
                                end
                                3'd2: begin
                                    resource2_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    resource2_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[2] <= 1'b1;
                                end
                                3'd3: begin
                                    resource3_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    resource3_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[3] <= 1'b1;
                                end
                                3'd4: begin
                                    resource4_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    resource4_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[4] <= 1'b1;
                                end
                                default: begin
                                    resource5_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    resource5_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[5] <= 1'b1;
                                end
                            endcase
                        end
                    end
                    default: begin end
                endcase
            end

            case (state)
                ST_IDLE: if (scan_start) begin
                    fs_error <= ERR_NONE;
                    partition_lba <= 32'd0;
                    resource_valid <= 6'd0;
                    wav1_valid <= 0; wav1_cluster <= 0; wav1_size <= 0;
                    wav_valid <= 0; wav_cluster <= 0; wav_size <= 0;
                    wav2_valid <= 0; wav2_cluster <= 0; wav2_size <= 0;
                    wav3_valid <= 0; wav3_cluster <= 0; wav3_size <= 0;
                    resource_count <= 0;
                    root_sector_index <= 0;
                    root_clusters_visited <= 1;
                    directory_end <= 0;
                    state <= ST_READ0_REQ;
                end
                ST_READ0_REQ: if (!sector_busy) begin
                    sector_lba <= 32'd0;
                    sector_req <= 1'b1;
                    state <= ST_READ0_WAIT;
                end
                ST_READ0_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sector_buffer[510] != 8'h55 || sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else if (sector_buffer[0] == 8'heb || sector_buffer[0] == 8'he9) begin
                        partition_lba <= 32'd0;
                        state <= ST_BOOT_PARSE;
                    end else if (sector_buffer[450] == 8'h0b || sector_buffer[450] == 8'h0c) begin
                        partition_lba <= le32(454);
                        sector_lba <= le32(454);
                        state <= ST_BOOT_REQ;
                    end else begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end
                end
                ST_BOOT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_BOOT_WAIT;
                end
                ST_BOOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sector_buffer[510] != 8'h55 || sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else
                        state <= ST_BOOT_PARSE;
                end
                ST_BOOT_PARSE: begin
                    if (le16(11) != 16'd512 || !valid_spc(sector_buffer[13]) ||
                        le16(14) == 0 || (sector_buffer[16] != 1 && sector_buffer[16] != 2) ||
                        le16(17) != 0 || le16(22) != 0 || le32(32) == 0 ||
                        le32(36) == 0 || le32(44) < 2) begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end else begin
                        sectors_per_cluster <= sector_buffer[13];
                        reserved_sectors <= le16(14);
                        fat_count <= sector_buffer[16];
                        total_sectors <= le32(32);
                        fat_sectors <= le32(36);
                        root_cluster <= le32(44);
                        sectors_per_cluster_shift <= spc_shift(sector_buffer[13]);
                        fat_span <= sector_buffer[16] == 2 ? (le32(36) << 1) : le32(36);
                        fat_start_lba <= partition_lba + le16(14);
                        state <= ST_BOOT_LAYOUT;
                    end
                end
                ST_BOOT_LAYOUT: begin
                    data_start_lba <= partition_lba + reserved_sectors + fat_span;
                    data_sector_count <= total_sectors - reserved_sectors - fat_span;
                    state <= ST_BOOT_ROOT;
                end
                ST_BOOT_ROOT: begin
                    max_cluster <= (data_sector_count >> sectors_per_cluster_shift) + 1'b1;
                    root_lba <= data_start_lba
                                + ((root_cluster - 2) << sectors_per_cluster_shift);
                    sector_lba <= data_start_lba
                                  + ((root_cluster - 2) << sectors_per_cluster_shift);
                    state <= ST_ROOT_REQ;
                end
                ST_ROOT_REQ: if (!sector_busy) begin
                    dir_entry_match <= 1'b0;
                    sector_req <= 1'b1;
                    state <= ST_ROOT_WAIT;
                end
                ST_ROOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else begin
                        directory_entry_index <= 5'd0;
                        state <= ST_DIR_SCAN;
                    end
                end
                ST_DIR_SCAN: begin
                    if (resource_valid == 6'h3f && wav1_valid &&
                        wav2_valid && wav3_valid && wav_valid)
                        state <= ST_FINISH;
                    else if (directory_end)
                        finish_with_error(ERR_RESOURCE_MISSING);
                    else if (root_sector_index + 1'b1 < sectors_per_cluster) begin
                        root_sector_index <= root_sector_index + 1'b1;
                        sector_lba <= sector_lba + 1'b1;
                        state <= ST_ROOT_REQ;
                    end else begin
                        sector_lba <= fat_start_lba + (root_cluster >> 7);
                        state <= ST_ROOT_FAT_REQ;
                    end
                end
                ST_ROOT_FAT_REQ: if (!sector_busy) begin
                    sector_req <= 1;
                    state <= ST_ROOT_FAT_WAIT;
                end
                ST_ROOT_FAT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else
                        state <= ST_ROOT_FAT_PARSE;
                end
                ST_ROOT_FAT_PARSE: begin
                    if (root_next_cluster >= 32'h0ffffff8)
                        finish_with_error(ERR_RESOURCE_MISSING);
                    else if (root_next_cluster < 2 || root_next_cluster > max_cluster ||
                             root_next_cluster == root_cluster || root_clusters_visited >= 8192)
                        finish_with_error(ERR_RESOURCE_MISSING);
                    else begin
                        root_cluster <= root_next_cluster;
                        root_clusters_visited <= root_clusters_visited + 1'b1;
                        root_sector_index <= 0;
                        sector_lba <= data_start_lba + ((root_next_cluster - 2) << sectors_per_cluster_shift);
                        state <= ST_ROOT_REQ;
                    end
                end
                ST_FINISH: begin
                    scan_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
