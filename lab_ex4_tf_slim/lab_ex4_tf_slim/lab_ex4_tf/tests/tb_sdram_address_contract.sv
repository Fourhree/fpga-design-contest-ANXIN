`timescale 1ns/1ps
// Real encrypted controller plus SDR command/DQ responder (CAS=3, BL=4).
module tb_sdram_address_contract;
    reg clk=0,rst=1,rd=0,wr=0;
    always #5 clk=~clk;
    wire init,busy,refresh,refresh_pending,controller_refresh,valid,sclk,ras,cas,we,app_refresh_request;
    wire [1:0] bank;
    wire [10:0] address;
    wire [3:0] dm;
    wire [31:0] data;
    tri [31:0] dq;
    reg [20:0] app_address=0;
    sdram_refresh_scheduler #(.REFRESH_INTERVAL_CYCLES(64)) refresh_scheduler (
        .clk(clk),.rst(rst),.init_done(init),.refresh_active(controller_refresh),
        .request_allowed(!wr && !rd && !busy),.refresh_pending(refresh_pending),
        .refresh_request(app_refresh_request));
    assign refresh=controller_refresh|refresh_pending;
    sdr_as_ram #(.self_refresh_open(1'b0)) controller (
        .Sdr_clk(clk),.Sdr_clk_sft(!clk),.Rst(rst),
        .Sdr_init_done(init),.Sdr_init_ref_vld(controller_refresh),.Sdr_busy(busy),.App_ref_req(app_refresh_request),
        .App_wr_en(wr),.App_wr_addr(app_address),.App_wr_dm(4'd0),.App_wr_din({11'd0,app_address}),
        .App_rd_en(rd),.App_rd_addr(app_address),.Sdr_rd_en(valid),.Sdr_rd_dout(data),
        .SDRAM_CLK(sclk),.SDR_RAS(ras),.SDR_CAS(cas),.SDR_WE(we),
        .SDR_BA(bank),.SDR_ADDR(address),.SDR_DM(dm),.SDR_DQ(dq));
    reg [10:0] rows[0:3];
    reg [20:0] pipe[0:2];
    reg [2:0] pv=0;
    reg dqvalid=0;
    reg [31:0] dqdata;
    assign dq=dqvalid ? dqdata : 32'bz;
    reg [20:0] native;
    integer left=0,reads=0,writes=0,returns=0,refreshes=0,i,j;
    reg test_pass=0;
    function [20:0] group_address;
        input integer g;
        begin group_address=((g*7919+7)%307200)&~3; end
    endfunction
    always @(posedge sclk) begin
        dqvalid<=pv[2]; dqdata<={11'd0,pipe[2]};
        pv<={pv[1:0],1'b0}; pipe[2]<=pipe[1]; pipe[1]<=pipe[0];
        if({ras,cas,we}==3'b011) rows[bank]=address;
        if(init && {ras,cas,we}==3'b001) refreshes=refreshes+1;
        if({ras,cas,we}==3'b101) begin
            native={rows[bank],address[7:2],bank,address[1:0]};
            if(native!==group_address(reads)) $fatal(1,"Physical address contract: group %d got %h expected %h",reads,native,group_address(reads));
            reads=reads+1; left=4;
        end
        if({ras,cas,we}==3'b100) begin
            native={rows[bank],address[7:2],bank,address[1:0]};
            if(native!==group_address(writes)) $fatal(1,"Physical write address: group %d got %h expected %h",writes,native,group_address(writes));
            writes=writes+1;
        end
        if(left!=0) begin
            pipe[0]<=native; pv[0]<=1;
            native=native+1'b1; left=left-1;
        end
    end
    always @(posedge clk) if(valid) begin
        if(data!=={11'd0,group_address(returns/4)}+(returns%4))
            $fatal(1,"Returned word %d got %h expected %h",returns,data,group_address(returns/4)+(returns%4));
        returns=returns+1;
    end
    initial begin
        repeat(10) @(negedge clk); rst=0;
        wait(init); wait(!busy && !refresh);
        @(negedge clk);
        for(j=0;j<4;j=j+1) begin
            for(i=0;i<128;i=i+1) begin wr=1; app_address=group_address(j*32+i/4)+i%4; @(negedge clk); end
            wr=0; repeat(20) @(negedge clk); wait(!busy && !refresh);
            repeat(2) @(negedge clk);
        end
        for(j=0;j<4;j=j+1) begin
            for(i=0;i<128;i=i+1) begin rd=1; app_address=group_address(j*32+i/4)+i%4; @(negedge clk); end
            rd=0; repeat(20) @(negedge clk); wait(!busy && !refresh);
            repeat(2) @(negedge clk);
        end
        repeat(50) @(negedge clk);
        if(writes!=128 || reads!=128 || returns!=512) $fatal(1,"Write/read/return count %d/%d/%d",writes,reads,returns);
        if(refreshes<2) $fatal(1,"Periodic AUTO REFRESH commands missing: %d",refreshes);
        test_pass=1; $display("PASS: real SDRAM controller, address contract and %0d periodic refreshes",refreshes); $finish;
    end
    initial begin #10000000; $fatal(1,"Controller timeout"); end
endmodule
