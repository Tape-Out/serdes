// serdes_apb：两份带寄存器的通道，总线时钟与线路时钟四个各不相同（线路两端差 600 ppm），线上带 0 至 6 纳秒的抖动。
// 依次核对：标识与复位值；自环收发，数据与控制字原样回来；PRBS 自环零误码，注入之后记到错，清零之后回零；
// 两份对接，双向逐字节比对，PRBS 双向零误码；收的队列满了记 RX_OVER、读回来的还是最先到的十六个；中断；关掉 EN 失锁。
`timescale 1ns/1ps
module apb_bfm (
  input  wire        pclk,
  output reg         psel,
  output reg         penable,
  output reg         pwrite,
  output reg  [7:0]  paddr,
  output reg  [31:0] pwdata,
  input  wire [31:0] prdata
);
  initial begin
    psel = 1'b0;
    penable = 1'b0;
    pwrite = 1'b0;
    paddr = 8'd0;
    pwdata = 32'd0;
  end

  task write(input [7:0] a, input [31:0] d);
    begin
      @(posedge pclk); #1 psel = 1'b1; pwrite = 1'b1; paddr = a; pwdata = d;
      @(posedge pclk); #1 penable = 1'b1;
      @(posedge pclk); #1 psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
    end
  endtask

  task read(input [7:0] a, output [31:0] d);
    begin
      @(posedge pclk); #1 psel = 1'b1; pwrite = 1'b0; paddr = a;
      @(posedge pclk); #1 penable = 1'b1;
      @(posedge pclk); d = prdata; #1 psel = 1'b0; penable = 1'b0;
    end
  endtask
endmodule

module tb_apb;
  localparam ID = 8'h00, CTRL = 8'h04, CMD = 8'h08, STAT = 8'h0c, TX = 8'h10, RX = 8'h14;
  localparam N_SYM = 8'h18, N_BAD = 8'h1c, N_PBYTE = 8'h24, N_PERR = 8'h28;
  localparam EN = 32'h1, LOOP = 32'h2, PTX = 32'h4, PRX = 32'h8, IE = 32'h100;

  reg pa = 1'b0, pb = 1'b0, la = 1'b0, lb = 1'b0;
  reg rst_n = 1'b1;
  always #10.000 pa = ~pa;
  always #11.300 pb = ~pb;
  always #5.000 la = ~la;
  always #5.003 lb = ~lb;

  wire        a_psel, a_pen, a_pwr, b_psel, b_pen, b_pwr;
  wire [7:0]  a_addr, b_addr;
  wire [31:0] a_wd, a_rd, b_wd, b_rd;
  wire        a_irq, b_irq, a_tx, b_tx;
  reg         a2b = 1'b0, b2a = 1'b0;
  always @(a_tx) a2b <= #({$random} % 7) a_tx;
  always @(b_tx) b2a <= #({$random} % 7) b_tx;

  apb_bfm ma (.pclk(pa), .psel(a_psel), .penable(a_pen), .pwrite(a_pwr), .paddr(a_addr), .pwdata(a_wd), .prdata(a_rd));
  apb_bfm mb (.pclk(pb), .psel(b_psel), .penable(b_pen), .pwrite(b_pwr), .paddr(b_addr), .pwdata(b_wd), .prdata(b_rd));
  serdes_apb a (
    .pclk(pa), .presetn(rst_n), .psel(a_psel), .penable(a_pen), .pwrite(a_pwr), .paddr(a_addr), .pwdata(a_wd),
    .prdata(a_rd), .irq(a_irq), .lclk(la), .tx(a_tx), .rx(b2a)
  );
  serdes_apb b (
    .pclk(pb), .presetn(rst_n), .psel(b_psel), .penable(b_pen), .pwrite(b_pwr), .paddr(b_addr), .pwdata(b_wd),
    .prdata(b_rd), .irq(b_irq), .lclk(lb), .tx(b_tx), .rx(a2b)
  );

  integer errs = 0;
  task check(input ok, input string what);
    begin
      // 判据里有 X 也算不过：if (!ok) 遇到 X 是不进分支的
      if (ok !== 1'b1) begin
        errs = errs + 1;
        $display("FAIL %0s（%0t）", what, $time);
      end
    end
  endtask

  reg [31:0] v, w;
  integer    i, n;

  // 等 STAT 的某几位变成想要的样子，最多等 t 纳秒
  task a_wait(input [31:0] mask, input [31:0] want, input integer t);
    integer t0;
    begin
      t0 = $time;
      ma.read(STAT, v);
      while ((v & mask) != want && $time - t0 < t) ma.read(STAT, v);
    end
  endtask
  task b_wait(input [31:0] mask, input [31:0] want, input integer t);
    integer t0;
    begin
      t0 = $time;
      mb.read(STAT, w);
      while ((w & mask) != want && $time - t0 < t) mb.read(STAT, w);
    end
  endtask
  // 换模式的那几个符号里可能收进半截的东西：取空
  task a_drain;
    begin
      ma.read(RX, v);
      while (v[31]) ma.read(RX, v);
    end
  endtask
  task b_drain;
    begin
      mb.read(RX, w);
      while (w[31]) mb.read(RX, w);
    end
  endtask
  task a_snap;
    begin
      ma.write(CMD, 32'h4);
      a_wait(32'h20, 32'h0, 100000);
    end
  endtask
  task b_snap;
    begin
      mb.write(CMD, 32'h4);
      b_wait(32'h20, 32'h0, 100000);
    end
  endtask

  // 第 i 个要发的符号：第 7 个是控制字 K28.0，其余是数据
  function [8:0] sym(input integer k);
    sym = k == 7 ? 9'h11c : {1'b0, k[7:0] * 8'd7 + 8'd3};
  endfunction

  initial begin
    #1 rst_n = 1'b0;
    repeat (5) @(posedge pa);
    rst_n = 1'b1;
    repeat (5) @(posedge pa);

    ma.read(ID, v);
    check(v == 32'h53524431, "标识不对");
    ma.read(CTRL, v);
    check(v == 32'h0, "CTRL 的复位值不是 0");
    ma.read(STAT, v);
    check(v == 32'h0, "STAT 的复位值不是 0");
    ma.read(RX, v);
    check(v == 32'h0, "队列空着，RX 读出来却不是 0");

    // 自环：数据与控制字原样回来
    ma.write(CTRL, EN | LOOP);
    ma.read(CTRL, v);
    check(v == (EN | LOOP), "CTRL 读回来不是写进去的");
    a_wait(32'h2, 32'h2, 400000);
    check(v[1:0] == 2'b11, "自环没锁上");
    for (i = 0; i < 12; i = i + 1) ma.write(TX, {23'd0, sym(i)});
    for (i = 0; i < 12; i = i + 1) begin
      a_wait(32'h8, 32'h8, 100000);
      ma.read(RX, v);
      check(v == {1'b1, 21'd0, 1'b0, sym(i)}, "自环收回来的与发出去的不一样");
    end
    ma.read(RX, v);
    check(v == 32'h0, "十二个取完了，队列里还有");

    // PRBS 自环
    ma.write(CTRL, EN | LOOP | PTX | PRX);
    #200000;
    a_snap;
    ma.read(N_PBYTE, v);
    check(v > 32'd200, "PRBS 核过的字节太少");
    n = v;
    ma.read(N_PERR, v);
    check(v == 32'd0, "PRBS 自环有误码");
    ma.read(N_BAD, v);
    check(v == 32'd0, "自环记到了码字或游程差的错");
    ma.read(STAT, v);
    check(!v[3] && !v[4], "PRBS_RX 开着，字节却进了收的队列");
    ma.write(CMD, 32'h1);
    #40000;
    a_snap;
    ma.read(N_PERR, v);
    check(v > 32'd0, "线上翻了一位，PRBS 没记到错");
    ma.write(CMD, 32'h2);
    #2000;
    a_snap;
    ma.read(N_PBYTE, v);
    check(v < n, "清零之后计数没回去");
    #40000;
    a_snap;
    ma.read(N_PERR, v);
    check(v == 32'd0, "清零之后又冒出了误码");

    // 两份对接
    ma.write(CTRL, EN);
    mb.write(CTRL, EN);
    a_wait(32'h2, 32'h2, 400000);
    b_wait(32'h2, 32'h2, 400000);
    check(v[1] && w[1], "对接没锁上");
    #20000;
    a_drain;
    b_drain;
    for (i = 0; i < 12; i = i + 1) begin
      ma.write(TX, {23'd0, sym(i)});
      mb.write(TX, {23'd0, sym(i + 100)});
    end
    for (i = 0; i < 12; i = i + 1) begin
      b_wait(32'h8, 32'h8, 100000);
      mb.read(RX, w);
      check(w == {1'b1, 21'd0, 1'b0, sym(i)}, "甲发给乙的对不上");
      a_wait(32'h8, 32'h8, 100000);
      ma.read(RX, v);
      check(v == {1'b1, 21'd0, 1'b0, sym(i + 100)}, "乙发给甲的对不上");
    end
    ma.write(CTRL, EN | PTX | PRX);
    mb.write(CTRL, EN | PTX | PRX);
    #300000;
    a_snap;
    b_snap;
    ma.read(N_PBYTE, v);
    mb.read(N_PBYTE, w);
    check(v > 32'd300 && w > 32'd300, "对接时 PRBS 核过的字节太少");
    ma.read(N_PERR, v);
    mb.read(N_PERR, w);
    check(v == 32'd0 && w == 32'd0, "对接时 PRBS 有误码");

    // 收的队列满：乙不读，甲发二十四个
    ma.write(CTRL, EN);
    mb.write(CTRL, EN);
    #20000;
    a_drain;
    b_drain;
    mb.write(CMD, 32'h2);
    for (i = 0; i < 24; i = i + 1) begin
      a_wait(32'h4, 32'h0, 100000);
      ma.write(TX, {23'd0, sym(i + 30)});
    end
    b_wait(32'h10, 32'h10, 400000);
    check(w[4], "乙的队列满了，RX_OVER 没起来");
    #20000;
    for (i = 0; i < 16; i = i + 1) begin
      mb.read(RX, w);
      check(w == {1'b1, 21'd0, 1'b0, sym(i + 30)}, "队列满过之后，留下的不是最先到的那十六个");
    end
    mb.read(RX, w);
    check(w == 32'h0, "十六个取完了，队列里还有");
    mb.write(CMD, 32'h2);
    b_wait(32'h10, 32'h0, 100000);
    check(!w[4], "清零之后 RX_OVER 还在");

    // 中断：开了 IE、队列里有字节才报，取走就落
    ma.write(TX, 32'h5a);
    b_wait(32'h8, 32'h8, 100000);
    #100;
    check(w[3] && !b_irq, "没开 IE，中断却起来了");
    mb.write(CTRL, EN | IE);
    #100;
    check(b_irq, "开了 IE、队列里有字节，中断没起来");
    mb.read(RX, w);
    check(w[7:0] == 8'h5a, "中断那个字节不对");
    #100;
    check(!b_irq, "取走之后中断没落");

    // 关掉 EN：失锁
    mb.write(CTRL, 32'h0);
    b_wait(32'h3, 32'h0, 100000);
    check(w[1:0] == 2'b00, "关掉 EN 之后还报锁着");

    if (errs == 0) $display("PASS tb_apb");
    else $display("FAIL tb_apb：%0d 处", errs);
    $finish;
  end

  initial begin
    #20000000;
    $display("FAIL tb_apb：超时");
    $finish;
  end
endmodule
