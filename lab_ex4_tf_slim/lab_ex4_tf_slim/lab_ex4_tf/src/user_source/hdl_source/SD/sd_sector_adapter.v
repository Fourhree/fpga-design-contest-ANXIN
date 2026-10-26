// SD卡扇区读接口适配层
// 把完赛工程FAT32模块的sector_*接口，转换成官方sd_card_top的sd_sec_*接口
module sd_sector_adapter #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer TIMEOUT_MS = 500
) (
    input  wire        clk,
    input  wire        rst_n,               // 低有效复位
    // === 新模块侧（sector接口，FAT32模块用）===
    input  wire        sector_req,           // 读扇区请求（电平，req=1表示请求读）
    input  wire [31:0] sector_lba,           // 扇区号
    output wire        sector_busy,           // 忙（正在读）
    output wire        sector_valid,          // 字节有效脉冲
    output wire [7:0]  sector_byte,           // 当前字节
    output wire [8:0]  sector_byte_index,     // 字节索引（0~511）
    output wire        sector_done,            // 读完成脉冲
    output wire [7:0]  sector_error,           // SD 读取错误或扇区超时为 8'h10
    // === 官方sd_card_top侧（sd_sec接口）===
    output reg         sd_sec_read,            // 读扇区请求（电平）
    output reg  [31:0] sd_sec_read_addr,       // 扇区号
    input  wire        sd_sec_read_data_valid,  // 字节有效
    input  wire [7:0]  sd_sec_read_data,       // 当前字节
    input  wire        sd_sec_read_end,
    input  wire        sd_sec_read_error
);

    reg [8:0] byte_cnt;       // 字节索引计数器（0~511）
    reg       busy_reg;        // 忙寄存器
    localparam [63:0] TIMEOUT_CYCLES = (64'd1 * CLK_FREQ_HZ * TIMEOUT_MS) / 1000;
    localparam integer COUNT_BITS = $clog2(TIMEOUT_CYCLES + 1);
    reg [COUNT_BITS-1:0] timeout_count;
    wire timed_out = busy_reg && timeout_count >= TIMEOUT_CYCLES - 1;

    // 忙信号：请求发出后到读完成之间为1
    assign sector_busy = busy_reg;

    // 字节有效和字节直接透传
    assign sector_valid = sd_sec_read_data_valid && busy_reg;
    assign sector_byte  = sd_sec_read_data;
    assign sector_byte_index = byte_cnt;
    assign sector_done  = busy_reg && (sd_sec_read_end || timed_out);
    assign sector_error = (sd_sec_read_error || timed_out) ? 8'h10 : 8'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sd_sec_read      <= 1'b0;
            sd_sec_read_addr <= 32'd0;
            byte_cnt          <= 9'd0;
            busy_reg          <= 1'b0;
            timeout_count     <= 0;
        end else begin
            if (!busy_reg)
                timeout_count <= 0;
            else if (!timed_out)
                timeout_count <= timeout_count + 1'b1;
            // 请求到来且不忙时，锁存扇区号，发出读请求
            if (sector_req && !busy_reg) begin
                sd_sec_read      <= 1'b1;
                sd_sec_read_addr <= sector_lba;
                busy_reg          <= 1'b1;
                byte_cnt          <= 9'd0;
            end
            // 读完成：撤销请求，清零计数器和忙
            else if (sector_done) begin
                sd_sec_read <= 1'b0;
                busy_reg     <= 1'b0;
                byte_cnt     <= 9'd0;
            end
            // 读进行中：字节有效时计数器递增
            else if (sd_sec_read_data_valid) begin
                byte_cnt <= byte_cnt + 9'd1;
            end
        end
    end

endmodule
