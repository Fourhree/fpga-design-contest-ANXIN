`timescale 1ns/1ps
module tb_color_bar_coordinates;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    wire hs,vs,de,line_active;
    wire [11:0] x,y;
    color_bar dut(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),
        .line_active(line_active),.pixel_x(x),.pixel_y(y),.rgb_r(),.rgb_g(),.rgb_b());
    integer pixels=0,frames=0;
    reg prior_de=0,prior_vs=1,test_pass=0;
    reg [11:0] last_de_x=0;
    always @(posedge clk) if(!rst) begin
        prior_de<=de; prior_vs<=vs;
        if(de) begin
            if(x!==pixels%640 || y!==(pixels/640)%480)
                $fatal(1,"Coordinate %d got (%d,%d)",pixels,x,y);
            pixels=pixels+1;
            last_de_x<=x;
        end
        if(prior_de && !de && last_de_x!==639) $fatal(1,"Last active x was not 639");
        if(prior_vs && !vs) frames=frames+1;
        if(pixels==640*480) begin
            test_pass=1; $display("PASS: color_bar DE coordinates cover 640x480 in raster order"); $finish;
        end
    end
    initial begin repeat(5) @(negedge clk); rst=0; end
    initial begin #10000000; $fatal(1,"Timing timeout"); end
endmodule
