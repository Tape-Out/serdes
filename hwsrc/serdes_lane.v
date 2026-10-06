// 一条收发通道：发送、接收、PRBS、自环与计数，全在线路时钟这一个域里。
// 位速率是 clk 的四分之一，一个符号 40 拍。并行口一拍一个字节，带 K 标记，上层拿控制字当包界。
module serdes_lane (
  input  wire        clk,
  input  wire        rst_n,
  // 控制，都是准静态的；inject 与 clear 是脉冲
  input  wire        loopback,     // 收端接自己的发端，不看 rx 脚
  input  wire        prbs_tx,      // 发 PRBS15，每 64 个符号夹一个逗号；这时不取 tx_*
  input  wire        prbs_rx,      // 把收到的数据字节当 PRBS15 核对
  input  wire        inject,       // 线上翻一位
  input  wire        clear,        // 计数清零
  // 发送：ready 那一拍取走；没给就发空闲
  input  wire [7:0]  tx_data,
  input  wire        tx_k,
  input  wire        tx_valid,
  output wire        tx_ready,
  // 接收：一拍一个符号，空闲的 K28.5 不送出；err 是这个符号码字不合法或游程差不对
  output wire [7:0]  rx_data,
  output wire        rx_k,
  output wire        rx_err,
  output wire        rx_valid,
  // 状态与计数（到顶不回绕）
  output wire        aligned,
  output wire        locked,
  output reg  [31:0] n_sym,        // 定界之后收到的符号，含空闲
  output reg  [15:0] n_code,       // 码字不合法的
  output reg  [15:0] n_disp,       // 游程差不对的
  output reg  [7:0]  n_realign,    // 按逗号定界的次数
  output reg  [31:0] n_prbs_byte,  // 核过的 PRBS 字节
  output reg  [31:0] n_prbs_err,   // 对不上的 PRBS 位
  // 线路
  output wire        tx,
  input  wire        rx
);
  wire       ready;
  wire [7:0] gen_d;
  reg  [5:0] gap;
  wire       comma_slot = gap == 6'd63;

  serdes_prbs_gen gen (.clk(clk), .rst_n(rst_n), .en(prbs_tx), .take(ready && !comma_slot), .d(gen_d));

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) gap <= 6'd0;
    else if (!prbs_tx) gap <= 6'd0;
    else if (ready) gap <= gap + 6'd1;
  end

  assign tx_ready = ready && !prbs_tx;
  serdes_tx u_tx (
    .clk(clk), .rst_n(rst_n),
    .d(prbs_tx ? gen_d : tx_data), .k(prbs_tx ? 1'b0 : tx_k),
    .valid(prbs_tx ? !comma_slot : tx_valid), .ready(ready),
    .flip(inject), .tx(tx)
  );

  wire [7:0] d;
  wire       k, v, cerr, derr, realign;
  serdes_rx u_rx (
    .clk(clk), .rst_n(rst_n), .rx(loopback ? tx : rx),
    .data(d), .k(k), .valid(v), .code_err(cerr), .disp_err(derr),
    .aligned(aligned), .locked(locked), .realign(realign)
  );

  wire idle = k && d == 8'hbc && !cerr;
  assign rx_data = d;
  assign rx_k = k;
  assign rx_err = cerr || derr;
  assign rx_valid = v && !idle;

  wire       chk_stb;
  wire [3:0] chk_n;
  serdes_prbs_chk chk (.clk(clk), .rst_n(rst_n), .en(prbs_rx && locked), .valid(v && !k && !cerr), .d(d),
                       .stb(chk_stb), .nerr(chk_n));

  wire [32:0] err_up = {1'b0, n_prbs_err} + {29'd0, chk_n};

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      n_sym <= 32'd0;
      n_code <= 16'd0;
      n_disp <= 16'd0;
      n_realign <= 8'd0;
      n_prbs_byte <= 32'd0;
      n_prbs_err <= 32'd0;
    end else if (clear) begin
      n_sym <= 32'd0;
      n_code <= 16'd0;
      n_disp <= 16'd0;
      n_realign <= 8'd0;
      n_prbs_byte <= 32'd0;
      n_prbs_err <= 32'd0;
    end else begin
      if (v && !(&n_sym)) n_sym <= n_sym + 32'd1;
      if (v && cerr && !(&n_code)) n_code <= n_code + 16'd1;
      if (v && derr && !(&n_disp)) n_disp <= n_disp + 16'd1;
      if (realign && !(&n_realign)) n_realign <= n_realign + 8'd1;
      if (chk_stb && !(&n_prbs_byte)) n_prbs_byte <= n_prbs_byte + 32'd1;
      if (chk_stb) n_prbs_err <= err_up[32] ? 32'hffff_ffff : err_up[31:0];
    end
  end
endmodule
