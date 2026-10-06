// 两条通道对接：两端各用自己的时钟（差 600 ppm），线上每个跳变带 0 至 6 纳秒的随机抖动（采样间隔 10 纳秒）。
// 依次核对：两端锁定；随机数据与控制字夹着空隙双向传，逐个符号比对；PRBS 双向零误码；
// 线上翻一位，对端记到错且不失锁；线断开后失锁，接回来重新锁定；自环。
`timescale 1ns/1ps
module tb_lane;
  reg ca = 1'b0, cb = 1'b0;
  reg rst_n = 1'b0;
  always #5.000 ca = ~ca;
  always #5.003 cb = ~cb;

  reg        a_loop = 1'b0, a_ptx = 1'b0, a_prx = 1'b0, a_inj = 1'b0, a_clr = 1'b0;
  reg        b_loop = 1'b0, b_ptx = 1'b0, b_prx = 1'b0, b_inj = 1'b0, b_clr = 1'b0;
  reg  [7:0] a_td = 8'd0, b_td = 8'd0;
  reg        a_tk = 1'b0, b_tk = 1'b0, a_tv = 1'b0, b_tv = 1'b0;
  wire       a_tr, b_tr;
  wire [7:0] a_rd, b_rd;
  wire       a_rk, b_rk, a_re, b_re, a_rv, b_rv;
  wire       a_al, b_al, a_lk, b_lk;
  wire [31:0] a_ns, b_ns, a_pb, b_pb, a_pe, b_pe;
  wire [15:0] a_nc, b_nc, a_nd, b_nd;
  wire [7:0]  a_nr, b_nr;
  wire       a_tx, b_tx;
  reg        a2b = 1'b0, b2a = 1'b0;
  reg        cut = 1'b0;

  always @(a_tx) a2b <= #({$random} % 7) a_tx;
  always @(b_tx) b2a <= #({$random} % 7) b_tx;

  serdes_lane a (
    .clk(ca), .rst_n(rst_n), .loopback(a_loop), .prbs_tx(a_ptx), .prbs_rx(a_prx), .inject(a_inj), .clear(a_clr),
    .tx_data(a_td), .tx_k(a_tk), .tx_valid(a_tv), .tx_ready(a_tr),
    .rx_data(a_rd), .rx_k(a_rk), .rx_err(a_re), .rx_valid(a_rv),
    .aligned(a_al), .locked(a_lk), .n_sym(a_ns), .n_code(a_nc), .n_disp(a_nd), .n_realign(a_nr),
    .n_prbs_byte(a_pb), .n_prbs_err(a_pe), .tx(a_tx), .rx(b2a)
  );
  serdes_lane b (
    .clk(cb), .rst_n(rst_n), .loopback(b_loop), .prbs_tx(b_ptx), .prbs_rx(b_prx), .inject(b_inj), .clear(b_clr),
    .tx_data(b_td), .tx_k(b_tk), .tx_valid(b_tv), .tx_ready(b_tr),
    .rx_data(b_rd), .rx_k(b_rk), .rx_err(b_re), .rx_valid(b_rv),
    .aligned(b_al), .locked(b_lk), .n_sym(b_ns), .n_code(b_nc), .n_disp(b_nd), .n_realign(b_nr),
    .n_prbs_byte(b_pb), .n_prbs_err(b_pe), .tx(b_tx), .rx(cut ? 1'b0 : a2b)
  );

  // 期望队列：发端被取走一个就记一个，收端出一个就比一个
  reg [8:0] qa [0:8191];
  reg [8:0] qb [0:8191];
  integer   qa_w = 0, qa_r = 0, qb_w = 0, qb_r = 0;
  integer   errors = 0;
  reg       a_send = 1'b0, b_send = 1'b0, compare = 1'b0;
  integer   a_left = 0, b_left = 0;

  // 能当数据发的控制字：K28.5 留给空闲，K28.7 会与后面的符号凑出假逗号
  function [8:0] pick (input integer r);
    reg [3:0] s;
    begin
      s = r[11:8] % 10;
      if (r[3:0] != 4'd0) pick = {1'b0, r[23:16]};
      else case (s)
        4'd0: pick = 9'h11c;
        4'd1: pick = 9'h13c;
        4'd2: pick = 9'h15c;
        4'd3: pick = 9'h17c;
        4'd4: pick = 9'h19c;
        4'd5: pick = 9'h1dc;
        4'd6: pick = 9'h1f7;
        4'd7: pick = 9'h1fb;
        4'd8: pick = 9'h1fd;
        default: pick = 9'h1fe;
      endcase
    end
  endfunction

  always @(posedge ca) begin
    if (a_tv && a_tr) begin
      qa[qa_w] = {a_tk, a_td};
      qa_w = qa_w + 1;
      a_left = a_left - 1;
      a_tv <= 1'b0;
    end
    if (a_send && a_left > 0 && !(a_tv && !a_tr) && ({$random} % 3) != 0) begin
      {a_tk, a_td} <= pick($random);
      a_tv <= 1'b1;
    end
    if (compare && a_rv) begin
      if (a_re || {a_rk, a_rd} !== qb[qb_r]) begin
        errors = errors + 1;
        if (errors < 10) $display("FAIL a got %h err=%b, b sent %h (symbol %0d)", {a_rk, a_rd}, a_re, qb[qb_r], qb_r);
      end
      qb_r = qb_r + 1;
    end
  end

  always @(posedge cb) begin
    if (b_tv && b_tr) begin
      qb[qb_w] = {b_tk, b_td};
      qb_w = qb_w + 1;
      b_left = b_left - 1;
      b_tv <= 1'b0;
    end
    if (b_send && b_left > 0 && !(b_tv && !b_tr) && ({$random} % 3) != 0) begin
      {b_tk, b_td} <= pick($random);
      b_tv <= 1'b1;
    end
    if (compare && b_rv) begin
      if (b_re || {b_rk, b_rd} !== qa[qa_r]) begin
        errors = errors + 1;
        if (errors < 10) $display("FAIL b got %h err=%b, a sent %h (symbol %0d)", {b_rk, b_rd}, b_re, qa[qa_r], qa_r);
      end
      qa_r = qa_r + 1;
    end
  end

  task expect_ (input cond, input [255:0] what);
    begin
      if (!cond) begin
        errors = errors + 1;
        $display("FAIL %0s", what);
      end
    end
  endtask

  task wait_lock (input integer limit);
    integer n;
    begin
      n = 0;
      while (!(a_lk && b_lk) && n < limit) begin
        @(posedge ca);
        n = n + 1;
      end
      expect_(a_lk && b_lk, "both ends lock");
    end
  endtask

  task pulse_clear;
    begin
      @(posedge ca) a_clr <= 1'b1;
      @(posedge ca) a_clr <= 1'b0;
      @(posedge cb) b_clr <= 1'b1;
      @(posedge cb) b_clr <= 1'b0;
    end
  endtask

  integer t0, n;
  initial begin
    repeat (8) @(posedge ca);
    rst_n = 1'b1;
    wait_lock(40000);
    $display("locked after %0t; realigned a %0d, b %0d times", $time, a_nr, b_nr);

    // 一：随机数据双向
    compare = 1'b1;
    a_left = 3000;
    b_left = 3000;
    a_send = 1'b1;
    b_send = 1'b1;
    while (a_left > 0 || b_left > 0) @(posedge ca);
    repeat (400) @(posedge ca);
    expect_(qa_r == 3000 && qb_r == 3000, "every symbol sent arrives, none twice");
    expect_(a_nc == 0 && a_nd == 0 && b_nc == 0 && b_nd == 0, "no code or disparity errors on random data");
    expect_(a_lk && b_lk, "still locked after random data");
    $display("data: a->b %0d, b->a %0d symbols", qa_r, qb_r);
    a_send = 1'b0;
    b_send = 1'b0;
    compare = 1'b0;

    // 二：PRBS 双向
    a_ptx = 1'b1;
    b_ptx = 1'b1;
    repeat (200) @(posedge ca);
    a_prx = 1'b1;
    b_prx = 1'b1;
    pulse_clear;
    repeat (160000) @(posedge ca);
    expect_(a_pb > 3000 && b_pb > 3000, "PRBS bytes are checked at both ends");
    expect_(a_pe == 0 && b_pe == 0, "PRBS runs with no bit error");
    expect_(a_nc == 0 && b_nc == 0 && a_nd == 0 && b_nd == 0, "no code or disparity errors under PRBS");
    $display("prbs: a checked %0d bytes, b %0d", a_pb, b_pb);

    // 三：a 的线上翻一位，b 记到错，不失锁。翻八次，每次落在符号里不同的位上，每一次都要记到
    for (n = 0; n < 8; n = n + 1) begin
      t0 = b_pe + b_nc + b_nd;
      @(posedge ca) a_inj <= 1'b1;
      @(posedge ca) a_inj <= 1'b0;
      repeat (1200 + 13 * n) @(posedge ca);
      expect_(b_pe + b_nc + b_nd > t0, "every flipped bit is counted at the far end");
    end
    expect_(b_lk, "isolated flipped bits do not unlock the receiver");
    expect_(a_pe == 0 && a_nc == 0, "the other direction is untouched");
    $display("inject: b counts prbs %0d, code %0d, disparity %0d", b_pe, b_nc, b_nd);

    // 四：断线失锁，接回重锁
    t0 = b_nr;
    cut = 1'b1;
    repeat (4000) @(posedge ca);
    expect_(!b_lk, "a dead line unlocks the receiver");
    cut = 1'b0;
    wait_lock(40000);
    expect_(b_nr > t0, "the receiver realigned on a comma after the line came back");
    pulse_clear;
    repeat (40000) @(posedge ca);
    expect_(b_pe == 0 && b_pb > 500, "PRBS is clean again after relock");

    // 五：自环，不看对端
    cut = 1'b1;
    a_loop = 1'b1;
    b_loop = 1'b1;
    repeat (8000) @(posedge ca);
    pulse_clear;
    repeat (40000) @(posedge ca);
    expect_(a_lk && b_lk, "both ends lock on their own transmitter in loopback");
    expect_(a_pe == 0 && b_pe == 0 && a_pb > 500 && b_pb > 500, "loopback PRBS is clean");

    if (errors == 0) $display("PASS tb_lane");
    else $display("FAILED tb_lane: %0d errors", errors);
    $finish;
  end

  initial begin
    #40_000_000;
    $display("FAILED tb_lane: timeout");
    $finish;
  end
endmodule
