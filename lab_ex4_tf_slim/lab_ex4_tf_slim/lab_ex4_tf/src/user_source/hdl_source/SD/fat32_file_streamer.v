`timescale 1ns/1ps

module fat32_file_streamer #(
    parameter integer MAX_VISITED_CLUSTERS = 8192,
    parameter integer BUFFERED_DELIVERY = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        file_start,
    input  wire        data_enable,
    // Used only with BUFFERED_DELIVERY: the SD transaction itself cannot stall.
    input  wire        file_ready,
    input  wire [31:0] first_cluster,
    input  wire [31:0] file_size,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [31:0] fat_start_lba,
    input  wire [31:0] data_start_lba,
    input  wire [31:0] max_cluster,
    output wire        file_busy,
    output reg         file_done,
    output reg         file_valid,
    output reg  [7:0]  file_byte,
    output reg  [31:0] file_byte_offset,
    output wire        file_sector_done,
    output reg  [7:0]  fs_error,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);
    localparam ERR_NONE              = 8'h00;
    localparam ERR_SECTOR            = 8'h10;
    localparam ERR_FAT_LOOP          = 8'h23;
    localparam ERR_CLUSTER_RANGE     = 8'h24;
    localparam ERR_EARLY_EOF         = 8'h25;
    localparam ERR_VISITED_EXHAUSTED = 8'h26;

    localparam ST_IDLE       = 4'd0;
    localparam ST_DATA_REQ   = 4'd1;
    localparam ST_DATA_WAIT  = 4'd2;
    localparam ST_FAT_REQ    = 4'd3;
    localparam ST_FAT_WAIT   = 4'd4;
    localparam ST_FAT_PARSE  = 4'd5;
    localparam ST_FINISH     = 4'd7;
    localparam ST_DATA_DRAIN = 4'd6;
    localparam ST_DRAIN_READ = 4'd8;

    localparam integer CHAIN_COUNT_WIDTH = $clog2(MAX_VISITED_CLUSTERS + 1);

    reg [3:0] state;
    reg [31:0] current_cluster;
    reg [31:0] next_cluster;
    reg [31:0] remaining_bytes;
    reg [7:0] sector_in_cluster;
    reg [8:0] fat_entry_offset;
    reg [7:0] fat_byte0, fat_byte1, fat_byte2, fat_byte3;
    reg [CHAIN_COUNT_WIDTH-1:0] chain_count;
    reg final_chain_check;
    reg [2:0] cluster_shift;
    reg [7:0] sector_buffer [0:511] /* fehdl force_ram=1, ram_style="bram" */;
    reg [7:0] buffered_byte;
    reg [8:0] drain_index;
    reg delivery_sector_done;

    // A synchronous RAM read avoids a large register/multiplexer sector store.
    always @(posedge clk) begin
        if (BUFFERED_DELIVERY && state == ST_DATA_WAIT && sector_valid)
            sector_buffer[sector_byte_index] <= sector_byte;
        if (BUFFERED_DELIVERY && state == ST_DRAIN_READ)
            buffered_byte <= sector_buffer[drain_index];
    end

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                2: spc_shift = 1;
                4: spc_shift = 2;
                8: spc_shift = 3;
                16: spc_shift = 4;
                32: spc_shift = 5;
                64: spc_shift = 6;
                128: spc_shift = 7;
                default: spc_shift = 0;
            endcase
        end
    endfunction

    assign file_busy = (state != ST_IDLE);
    assign file_sector_done = BUFFERED_DELIVERY ? delivery_sector_done :
                              (state == ST_DATA_WAIT) && sector_done;

    task advance_data_sector;
        input final_sector;
        begin
            if (final_sector) begin
                final_chain_check <= 1'b1;
                sector_in_cluster <= 8'd0;
                fat_entry_offset <= {current_cluster[6:0], 2'b00};
                sector_lba <= fat_start_lba + (current_cluster >> 7);
                state <= ST_FAT_REQ;
            end else if (sector_in_cluster + 1'b1 < sectors_per_cluster) begin
                sector_in_cluster <= sector_in_cluster + 1'b1;
                sector_lba <= sector_lba + 1'b1;
                state <= ST_DATA_REQ;
            end else begin
                sector_in_cluster <= 8'd0;
                fat_entry_offset <= {current_cluster[6:0], 2'b00};
                sector_lba <= fat_start_lba + (current_cluster >> 7);
                state <= ST_FAT_REQ;
            end
        end
    endtask

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    task advance_to_next_cluster;
        input [31:0] cluster_value;
        begin
            chain_count <= chain_count + 1'b1;
            current_cluster <= cluster_value;
            sector_lba <= data_start_lba + ((cluster_value - 2) << cluster_shift);
            state <= ST_DATA_REQ;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            file_done <= 1'b0;
            file_valid <= 1'b0;
            file_byte <= 8'd0;
            file_byte_offset <= 32'd0;
            fs_error <= ERR_NONE;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            current_cluster <= 32'd0;
            next_cluster <= 32'd0;
            remaining_bytes <= 32'd0;
            sector_in_cluster <= 8'd0;
            fat_entry_offset <= 9'd0;
            fat_byte0 <= 8'd0;
            fat_byte1 <= 8'd0;
            fat_byte2 <= 8'd0;
            fat_byte3 <= 8'd0;
            chain_count <= 0;
            final_chain_check <= 1'b0;
            cluster_shift <= 0;
            drain_index <= 0;
            delivery_sector_done <= 0;
        end else begin
            file_done <= 1'b0;
            file_valid <= 1'b0;
            sector_req <= 1'b0;
            delivery_sector_done <= 0;

            if (!BUFFERED_DELIVERY && state == ST_DATA_WAIT && sector_valid && remaining_bytes != 0) begin
                file_valid <= 1'b1;
                file_byte <= sector_byte;
                file_byte_offset <= file_size - remaining_bytes;
                remaining_bytes <= remaining_bytes - 1'b1;
            end

            if (state == ST_FAT_WAIT && sector_valid) begin
                if (sector_byte_index == fat_entry_offset)
                    fat_byte0 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 1'b1)
                    fat_byte1 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 2'd2)
                    fat_byte2 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 2'd3)
                    fat_byte3 <= sector_byte;
            end

            case (state)
                ST_IDLE: if (file_start) begin
                    fs_error <= ERR_NONE;
                    file_byte_offset <= 32'd0;
                    remaining_bytes <= file_size;
                    sector_in_cluster <= 8'd0;
                    chain_count <= 1;
                    final_chain_check <= 1'b0;
                    cluster_shift <= spc_shift(sectors_per_cluster);
                    if (file_size == 0) begin
                        state <= ST_FINISH;
                    end else if (first_cluster < 2 || first_cluster > max_cluster ||
                                 sectors_per_cluster == 0) begin
                        finish_with_error(ERR_CLUSTER_RANGE);
                    end else begin
                        current_cluster <= first_cluster;
                        sector_lba <= data_start_lba + ((first_cluster - 2) << spc_shift(sectors_per_cluster));
                        state <= ST_DATA_REQ;
                    end
                end
                ST_DATA_REQ: if (!sector_busy && data_enable) begin
                    sector_req <= 1'b1;
                    state <= ST_DATA_WAIT;
                end
                ST_DATA_WAIT: if (sector_done) begin
                    if (sector_error != 0) begin
                        finish_with_error(ERR_SECTOR);
                    end else if (BUFFERED_DELIVERY) begin
                        drain_index <= 0;
                        state <= ST_DRAIN_READ;
                    end else begin
                        advance_data_sector(remaining_bytes == 0 ||
                                            (remaining_bytes == 1 && sector_valid));
                    end
                end
                ST_DRAIN_READ: if (data_enable && file_ready && !file_valid)
                    state <= ST_DATA_DRAIN;
                ST_DATA_DRAIN: begin
                    // A bubble reserves the registered output byte, so a
                    // consumer may withdraw ready as soon as it receives it.
                    file_valid <= 1;
                    file_byte <= buffered_byte;
                    file_byte_offset <= file_size - remaining_bytes;
                    remaining_bytes <= remaining_bytes - 1'b1;
                    drain_index <= drain_index + 1'b1;
                    state <= ST_DRAIN_READ;
                    if (drain_index == 511 || remaining_bytes == 1) begin
                        delivery_sector_done <= 1;
                        advance_data_sector(remaining_bytes == 1);
                    end
                end
                ST_FAT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_FAT_WAIT;
                end
                ST_FAT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else
                        state <= ST_FAT_PARSE;
                end
                ST_FAT_PARSE: begin
                    next_cluster <= {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0};
                    if (final_chain_check) begin
                        final_chain_check <= 1'b0;
                        if ({fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} >= 28'hffffff8)
                            state <= ST_FINISH;
                        else if ({4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} < 2 ||
                                 {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} > max_cluster)
                            finish_with_error(ERR_CLUSTER_RANGE);
                        else
                            finish_with_error(ERR_FAT_LOOP);
                    end else if ({fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} >= 28'hffffff8) begin
                        finish_with_error(ERR_EARLY_EOF);
                    end else if ({4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} < 2 ||
                                 {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} > max_cluster) begin
                        finish_with_error(ERR_CLUSTER_RANGE);
                    end else if (chain_count >= MAX_VISITED_CLUSTERS) begin
                        finish_with_error(ERR_VISITED_EXHAUSTED);
                    end else if ({4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} == current_cluster) begin
                        finish_with_error(ERR_FAT_LOOP);
                    end else begin
                        advance_to_next_cluster({4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0});
                    end
                end
                ST_FINISH: begin
                    file_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
