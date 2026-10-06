// PRBS15（x^15 + x^14 + 1，ITU-T O.150），一次出、一次核一个字节，字节里低位先出。

module serdes_prbs_gen (
  input  wire       clk,
  input  wire       rst_n,
  input  wire       en,      // 为低时回到初值
  input  wire       take,    // 这一拍取走 d
  output wire [7:0] d
);
  reg [14:0] l;      // l[0] 是最近出的一位
  reg [14:0] n;
  reg [7:0]  b;
  integer    i;
  always @* begin
    n = l;
    for (i = 0; i < 8; i = i + 1) begin
      b[i] = n[14] ^ n[13];
      n = {n[13:0], b[i]};
    end
  end
  assign d = b;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) l <= 15'h7fff;
    else if (!en) l <= 15'h7fff;
    else if (take) l <= n;
  end
endmodule

// 自同步的核对：每一位都拿收到的前 15 位去预测，不必与发端对齐初值。
// 线上错一位在这里记三次（它自己，以及它进到两个抽头的那两次）。开头两个字节用来灌满历史，不计。
module serdes_prbs_chk (
  input  wire       clk,
  input  wire       rst_n,
  input  wire       en,
  input  wire       valid,
  input  wire [7:0] d,
  output reg        stb,     // 一拍：核过一个字节
  output reg  [3:0] nerr     // 与 stb 同拍：这个字节里对不上的位数
);
  reg [14:0] h;
  reg [1:0]  warm;
  reg [14:0] n;
  reg [7:0]  e;
  integer    i;
  always @* begin
    n = h;
    for (i = 0; i < 8; i = i + 1) begin
      e[i] = d[i] ^ n[14] ^ n[13];
      n = {n[13:0], d[i]};
    end
  end
  wire [3:0] cnt = e[0] + e[1] + e[2] + e[3] + e[4] + e[5] + e[6] + e[7];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      h <= 15'd0;
      warm <= 2'd0;
      stb <= 1'b0;
      nerr <= 4'd0;
    end else begin
      stb <= 1'b0;
      if (!en) begin
        warm <= 2'd0;
      end else if (valid) begin
        h <= n;
        if (warm != 2'd2) warm <= warm + 2'd1;
        else begin
          stb <= 1'b1;
          nerr <= cnt;
        end
      end
    end
  end
endmodule
