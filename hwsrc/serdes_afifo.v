// 跨时钟域的 FIFO：两边各一个时钟，读写指针用格雷码过对面，每次只变一位，对面采到的要么是旧值要么是新值。
// 深度 2^A。数据在写指针过去之前已经写稳，读侧直接读存储。
module serdes_afifo #(
  parameter W = 9,
  parameter A = 4
) (
  input  wire         wclk,
  input  wire         wrst_n,
  input  wire [W-1:0] wdata,
  input  wire         wvalid,
  output wire         wready,
  input  wire         rclk,
  input  wire         rrst_n,
  output wire [W-1:0] rdata,
  output wire         rvalid,
  input  wire         rready
);
  reg [W-1:0] mem [0:(1 << A) - 1];
  reg [A:0]   wbin, wgray, rbin, rgray;
  reg [A:0]   rg1, rg2;     // 读指针在写时钟域
  reg [A:0]   wg1, wg2;     // 写指针在读时钟域

  wire [A:0] wbin_n = wbin + {{A{1'b0}}, wvalid && wready};
  wire [A:0] rbin_n = rbin + {{A{1'b0}}, rvalid && rready};

  // 满：格雷码的最高两位相反、其余相同
  assign wready = wgray != {~rg2[A:A-1], rg2[A-2:0]};
  assign rvalid = rgray != wg2;
  assign rdata = mem[rbin[A-1:0]];

  always @(posedge wclk) begin
    if (wvalid && wready) mem[wbin[A-1:0]] <= wdata;
  end

  always @(posedge wclk or negedge wrst_n) begin
    if (!wrst_n) begin
      wbin <= {(A + 1){1'b0}};
      wgray <= {(A + 1){1'b0}};
      rg1 <= {(A + 1){1'b0}};
      rg2 <= {(A + 1){1'b0}};
    end else begin
      wbin <= wbin_n;
      wgray <= wbin_n ^ (wbin_n >> 1);
      rg1 <= rgray;
      rg2 <= rg1;
    end
  end

  always @(posedge rclk or negedge rrst_n) begin
    if (!rrst_n) begin
      rbin <= {(A + 1){1'b0}};
      rgray <= {(A + 1){1'b0}};
      wg1 <= {(A + 1){1'b0}};
      wg2 <= {(A + 1){1'b0}};
    end else begin
      rbin <= rbin_n;
      rgray <= rbin_n ^ (rbin_n >> 1);
      wg1 <= wgray;
      wg2 <= wg1;
    end
  end
endmodule
