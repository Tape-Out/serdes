// 接收端的定向核对：码字一位一位地喂进去（每位 4 拍），每个符号该报什么逐个比。
// 头一个逗号用游程差为正的那种写法：定界时游程差要照逗号的写法认，认错了头一个符号就会被冤枉。
// 之后各放一个「码字在表里、游程差不对」的与一个「表里没有」的，两种错要分得开，报完都能接着收。
`timescale 1ns/1ps
module tb_rx;
  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg rst_n = 1'b0;
  reg line = 1'b0;

  wire [7:0] data;
  wire       k, valid, code_err, disp_err, aligned, locked, realign;
  serdes_rx dut (
    .clk(clk), .rst_n(rst_n), .rx(line), .data(data), .k(k), .valid(valid),
    .code_err(code_err), .disp_err(disp_err), .aligned(aligned), .locked(locked), .realign(realign)
  );

  localparam [9:0] KP = 10'b1100000101;   // K28.5，发端游程差为正时的写法，发完变负
  localparam [9:0] KN = 10'b0011111010;   // 为负时的写法，发完变正

  // 期望：{code_err, disp_err, k, d}。码字不合法时译出的字节不比
  reg [10:0] q [0:255];
  integer    q_w = 0, q_r = 0, errors = 0;
  reg        stop = 1'b0;

  task send (input [9:0] c, input [10:0] want);
    integer i;
    begin
      q[q_w] = want;
      q_w = q_w + 1;
      for (i = 9; i >= 0; i = i - 1) begin
        line = c[i];
        repeat (4) @(posedge clk);
      end
    end
  endtask

  always @(posedge clk) begin
    if (valid && !stop) begin
      if ({code_err, disp_err} !== q[q_r][10:9] || (!code_err && {k, data} !== q[q_r][8:0])) begin
        errors = errors + 1;
        $display("FAIL symbol %0d: got code_err=%b disp_err=%b %h, expected %b %b %h", q_r,
                 code_err, disp_err, {k, data}, q[q_r][10], q[q_r][9], q[q_r][8:0]);
      end
      q_r = q_r + 1;
    end
  end

  integer n;
  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    for (n = 0; n < 12; n = n + 1) begin
      send(KP, {2'b00, 9'h1bc});
      send(KN, {2'b00, 9'h1bc});
    end
    if (!locked) begin
      errors = errors + 1;
      $display("FAIL not locked after 24 commas");
    end
    // 游程差此刻为正。D21.5 两种游程差下是同一个码字
    send(10'b1010101010, {2'b00, 9'h0b5});
    // D0.0 在负游程差下的写法出现在正游程差下
    send(10'b1001110100, {2'b01, 9'h000});
    // 报完照这个码字接着认：D0.0 不动游程差，按负的往下走
    send(KN, {2'b00, 9'h1bc});
    send(KP, {2'b00, 9'h1bc});
    // 六位全 0，表里没有
    send(10'b0000001011, {2'b10, 9'h000});
    // 这个码字里 1 少于五个，游程差重新认成负
    send(KN, {2'b00, 9'h1bc});
    send(KP, {2'b00, 9'h1bc});
    send(KN, {2'b00, 9'h1bc});
    // 最后一个符号出来就收手：线停在一个电平上不动，再往后收到的是凑不成码字的东西
    repeat (16) @(posedge clk);
    stop = 1'b1;
    if (q_r != q_w) begin
      errors = errors + 1;
      $display("FAIL %0d symbols sent, %0d came out", q_w, q_r);
    end
    if (!locked) begin
      errors = errors + 1;
      $display("FAIL two isolated errors unlocked the receiver");
    end
    if (errors == 0) $display("PASS tb_rx");
    else $display("FAILED tb_rx: %0d errors", errors);
    $finish;
  end
endmodule
