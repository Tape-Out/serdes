// serdes_lane 加一组 APB4 寄存器，零等待。总线在 pclk 上，线路在 lclk 上，两个时钟可以不同源：
// 字节经 serdes_afifo 过域；准静态的控制打两拍；注入、清零、抓计数各是一根翻一次算一下的线；
// 计数器不逐位过域，抓的时候在线路那一侧整组存下，总线这一侧等应答回来再读。
//   0x00 ID      只读，0x53524431（"SRD1"）
//   0x04 CTRL    第 0 位 EN（为 0 时线路那一侧按在复位里）、1 LOOP、2 PRBS_TX、3 PRBS_RX、8 IE（收的队列里有字节就报中断）
//   0x08 CMD     只写，写 1 起作用：第 0 位线上翻一位，1 计数清零（连同 RX_OVER），2 抓一次计数
//   0x0C STAT    只读：第 0 位 ALIGNED、1 LOCKED、2 TX_FULL、3 RX_VALID、4 RX_OVER（收的队列满过，丢了字节）、5 BUSY（抓计数还没回来）
//   0x10 TX      只写：7:0 字节，第 8 位是 K。队列满时这一次写丢掉
//   0x14 RX      只读：7:0 字节，第 8 位 K，第 9 位这个符号有错，第 31 位有效。读一次取走一个
//   0x18 N_SYM   0x1C N_BAD（31:16 游程差不对的，15:0 码字不合法的）   0x20 N_REALIGN
//   0x24 N_PRBS_BYTE   0x28 N_PRBS_ERR      都是上一次抓计数时的值
// PRBS_RX 开着时收到的字节只拿去核对，不进收的队列。
`default_nettype none
module serdes_apb (
  input  wire        pclk,
  input  wire        presetn,
  input  wire        psel,
  input  wire        penable,
  input  wire        pwrite,
  input  wire [7:0]  paddr,
  input  wire [31:0] pwdata,
  output reg  [31:0] prdata,
  output wire        irq,
  input  wire        lclk,     // 线路时钟，每位四拍
  output wire        tx,
  input  wire        rx
);
  wire       wr = psel && penable && pwrite;
  wire       rd = psel && penable && !pwrite;
  wire [3:0] sel = paddr[5:2];

  reg en, loop, ptx, prx, ie;
  reg t_inj, t_clr, t_snap;
  always @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
      en     <= 1'b0;
      loop   <= 1'b0;
      ptx    <= 1'b0;
      prx    <= 1'b0;
      ie     <= 1'b0;
      t_inj  <= 1'b0;
      t_clr  <= 1'b0;
      t_snap <= 1'b0;
    end else if (wr && sel == 4'd1) begin
      en   <= pwdata[0];
      loop <= pwdata[1];
      ptx  <= pwdata[2];
      prx  <= pwdata[3];
      ie   <= pwdata[8];
    end else if (wr && sel == 4'd2) begin
      if (pwdata[0]) t_inj <= !t_inj;
      if (pwdata[1]) t_clr <= !t_clr;
      if (pwdata[2]) t_snap <= !t_snap;
    end
  end

  // 线路那一侧的复位：异步落下，同步松开
  reg [1:0] lrst_s;
  always @(posedge lclk or negedge presetn) begin
    if (!presetn) lrst_s <= 2'b00;
    else lrst_s <= {lrst_s[0], 1'b1};
  end
  wire lrst_n = lrst_s[1];

  reg [1:0] en_s, loop_s, ptx_s, prx_s;
  reg [2:0] inj_s, clr_s, snap_s;
  reg       lane_rst_n;
  always @(posedge lclk or negedge lrst_n) begin
    if (!lrst_n) begin
      en_s       <= 2'b00;
      loop_s     <= 2'b00;
      ptx_s      <= 2'b00;
      prx_s      <= 2'b00;
      inj_s      <= 3'b000;
      clr_s      <= 3'b000;
      snap_s     <= 3'b000;
      lane_rst_n <= 1'b0;
    end else begin
      en_s       <= {en_s[0], en};
      loop_s     <= {loop_s[0], loop};
      ptx_s      <= {ptx_s[0], ptx};
      prx_s      <= {prx_s[0], prx};
      inj_s      <= {inj_s[1:0], t_inj};
      clr_s      <= {clr_s[1:0], t_clr};
      snap_s     <= {snap_s[1:0], t_snap};
      lane_rst_n <= en_s[1];
    end
  end
  wire l_inj = inj_s[2] ^ inj_s[1];
  wire l_clr = clr_s[2] ^ clr_s[1];
  wire l_snap = snap_s[2] ^ snap_s[1];

  wire [8:0]  tq;
  wire        tq_valid, tx_ready, tx_wready;
  wire [7:0]  rx_data;
  wire        rx_k, rx_err, rx_valid, aligned, locked;
  wire [31:0] n_sym, n_prbs_byte, n_prbs_err;
  wire [15:0] n_code, n_disp;
  wire [7:0]  n_realign;

  serdes_afifo #(.W(9), .A(4)) u_txq (
    .wclk(pclk), .wrst_n(presetn), .wdata(pwdata[8:0]), .wvalid(wr && sel == 4'd4), .wready(tx_wready),
    // 通道在复位里时不取，免得把 EN 之前写进来的字节漏掉
    .rclk(lclk), .rrst_n(lrst_n), .rdata(tq), .rvalid(tq_valid), .rready(tx_ready && lane_rst_n)
  );

  serdes_lane u_lane (
    .clk(lclk), .rst_n(lane_rst_n),
    .loopback(loop_s[1]), .prbs_tx(ptx_s[1]), .prbs_rx(prx_s[1]), .inject(l_inj), .clear(l_clr),
    .tx_data(tq[7:0]), .tx_k(tq[8]), .tx_valid(tq_valid), .tx_ready(tx_ready),
    .rx_data(rx_data), .rx_k(rx_k), .rx_err(rx_err), .rx_valid(rx_valid),
    .aligned(aligned), .locked(locked),
    .n_sym(n_sym), .n_code(n_code), .n_disp(n_disp), .n_realign(n_realign),
    .n_prbs_byte(n_prbs_byte), .n_prbs_err(n_prbs_err),
    .tx(tx), .rx(rx)
  );

  wire       rq_wvalid = rx_valid && !prx_s[1];
  wire       rq_wready, rq_valid;
  wire [9:0] rq;
  serdes_afifo #(.W(10), .A(4)) u_rxq (
    .wclk(lclk), .wrst_n(lrst_n), .wdata({rx_err, rx_k, rx_data}), .wvalid(rq_wvalid), .wready(rq_wready),
    .rclk(pclk), .rrst_n(presetn), .rdata(rq), .rvalid(rq_valid), .rready(rd && sel == 4'd5)
  );

  reg        over, t_ack;
  reg [31:0] h_sym, h_pbyte, h_perr;
  reg [15:0] h_code, h_disp;
  reg [7:0]  h_realign;
  always @(posedge lclk or negedge lrst_n) begin
    if (!lrst_n) begin
      over      <= 1'b0;
      t_ack     <= 1'b0;
      h_sym     <= 32'd0;
      h_pbyte   <= 32'd0;
      h_perr    <= 32'd0;
      h_code    <= 16'd0;
      h_disp    <= 16'd0;
      h_realign <= 8'd0;
    end else begin
      if (l_clr) over <= 1'b0;
      else if (rq_wvalid && !rq_wready) over <= 1'b1;
      if (l_snap) begin
        h_sym     <= n_sym;
        h_pbyte   <= n_prbs_byte;
        h_perr    <= n_prbs_err;
        h_code    <= n_code;
        h_disp    <= n_disp;
        h_realign <= n_realign;
        t_ack     <= !t_ack;
      end
    end
  end

  reg [1:0] aligned_p, locked_p, over_p, ack_p;
  always @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
      aligned_p <= 2'b00;
      locked_p  <= 2'b00;
      over_p    <= 2'b00;
      ack_p     <= 2'b00;
    end else begin
      aligned_p <= {aligned_p[0], aligned && lane_rst_n};
      locked_p  <= {locked_p[0], locked && lane_rst_n};
      over_p    <= {over_p[0], over};
      ack_p     <= {ack_p[0], t_ack};
    end
  end
  wire busy = t_snap != ack_p[1];

  always @(*) begin
    case (sel)
      4'd0: prdata = 32'h5352_4431;
      4'd1: prdata = {23'd0, ie, 4'd0, prx, ptx, loop, en};
      4'd3: prdata = {26'd0, busy, over_p[1], rq_valid, !tx_wready, locked_p[1], aligned_p[1]};
      4'd5: prdata = {rq_valid, 21'd0, rq_valid ? rq : 10'd0};
      4'd6: prdata = h_sym;
      4'd7: prdata = {h_disp, h_code};
      4'd8: prdata = {24'd0, h_realign};
      4'd9: prdata = h_pbyte;
      4'd10: prdata = h_perr;
      default: prdata = 32'd0;
    endcase
  end

  assign irq = ie && rq_valid;
endmodule
`default_nettype wire
