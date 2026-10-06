// 接收端：线路不带时钟，本地时钟每位采 4 个点，从数据自己的跳变里找相位。
//
// 相位计数 ph 约定跳变之后的第一个采样落在 ph = 0，判决取 ph = 0、1、2 三个采样的多数。
// 每来一个跳变核对一次：落在 1 是来晚了，相位停一拍；落在 3 是来早了，多走一拍；落在 2 差了半位，
// 也只挪一拍。两端时钟的频偏就这样一拍一拍地跟掉，线上的一个毛刺也只让相位偏一拍，不会整位滑走。
//
// 符号边界靠逗号 K28.5 找：没锁定时，十位窗口里出现它就把那里当边界。之后连着 15 个符号没错算锁定；
// 短时间里错了三个符号算失锁，回去重新找逗号。锁定之后不再看逗号，免得误码凑出的假逗号把边界带走。
module serdes_rx (
  input  wire       clk,
  input  wire       rst_n,
  input  wire       rx,
  output reg  [7:0] data,
  output reg        k,
  output reg        valid,      // 一个符号一拍，定了界才出
  output reg        code_err,   // 与 valid 同拍：不是合法码字
  output reg        disp_err,   // 与 valid 同拍：码字在表里，但不该出现在当前的游程差下
  output reg        aligned,
  output reg        locked,
  output reg        realign     // 一拍：按逗号定了一次界
);
  reg       s0, s1, q1, q2;
  reg [1:0] ph;
  reg       bit_r, bit_stb;

  wire edge_ = s1 ^ q1;
  wire maj = (s1 & q1) | (s1 & q2) | (q1 & q2);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s0 <= 1'b0;
      s1 <= 1'b0;
      q1 <= 1'b0;
      q2 <= 1'b0;
      ph <= 2'd0;
      bit_r <= 1'b0;
      bit_stb <= 1'b0;
    end else begin
      s0 <= rx;
      s1 <= s0;
      q1 <= s1;
      q2 <= q1;
      if (edge_) ph <= ph == 2'd2 ? 2'd0 : 2'd1;
      else ph <= ph + 2'd1;
      bit_stb <= ph == 2'd2;
      if (ph == 2'd2) bit_r <= maj;
    end
  end

  reg [9:0] sh;
  reg [3:0] bc;
  reg [9:0] sym;
  reg       sym_stb;

  wire [9:0] win = {sh[8:0], bit_r};
  wire       comma = win == 10'b0011111010 || win == 10'b1100000101;
  wire       take = bit_stb && !locked && comma && (!aligned || bc != 4'd9);

  // 译码分两拍：先查表，再把译出的字节按两种游程差各编一遍，与收到的码字比
  wire [7:0] dec_d;
  wire       dec_k, dec_bad;
  serdes_dec8b10b dec (.code(sym), .d(dec_d), .k(dec_k), .bad(dec_bad));

  reg [9:0] c1;
  reg [7:0] d1;
  reg       k1, bad1, v1;
  reg       rd;

  wire [9:0] e0, e1;
  wire       n0, n1;
  serdes_enc8b10b enc0 (.d(d1), .k(k1), .rd(1'b0), .code(e0), .rd_next(n0), .bad_k());
  serdes_enc8b10b enc1 (.d(d1), .k(k1), .rd(1'b1), .code(e1), .rd_next(n1), .bad_k());

  wire m0 = c1 == e0;
  wire m1 = c1 == e1;
  wire cerr = bad1 || !(m0 || m1);
  wire derr = !cerr && !(rd ? m1 : m0);
  // 出了错就照码字里 1 的个数重新认游程差：多于五个是正，少于五个是负
  wire [3:0] ones = c1[0] + c1[1] + c1[2] + c1[3] + c1[4] + c1[5] + c1[6] + c1[7] + c1[8] + c1[9];
  wire rd_fix = ones > 4'd5 ? 1'b1 : (ones < 4'd5 ? 1'b0 : rd);
  wire rd_new = cerr ? rd_fix : (rd ? (m1 ? n1 : n0) : (m0 ? n0 : n1));

  reg [3:0] goods;
  reg [3:0] errs;
  wire [4:0] errs_up = {1'b0, errs} + 5'd4;
  wire       lost = v1 && (cerr || derr) && errs_up >= 5'd12;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sh <= 10'd0;
      bc <= 4'd0;
      sym <= 10'd0;
      sym_stb <= 1'b0;
      c1 <= 10'd0;
      d1 <= 8'd0;
      k1 <= 1'b0;
      bad1 <= 1'b0;
      v1 <= 1'b0;
      rd <= 1'b0;
      data <= 8'd0;
      k <= 1'b0;
      valid <= 1'b0;
      code_err <= 1'b0;
      disp_err <= 1'b0;
      aligned <= 1'b0;
      locked <= 1'b0;
      realign <= 1'b0;
      goods <= 4'd0;
      errs <= 4'd0;
    end else begin
      sym_stb <= 1'b0;
      realign <= 1'b0;
      if (bit_stb) begin
        sh <= win;
        if (take) begin
          bc <= 4'd0;
          aligned <= 1'b1;
          realign <= 1'b1;
          sym <= win;
          sym_stb <= 1'b1;
        end else if (bc == 4'd9) begin
          bc <= 4'd0;
          sym <= win;
          sym_stb <= aligned;
        end else begin
          bc <= bc + 4'd1;
        end
      end

      v1 <= sym_stb;
      if (sym_stb) begin
        c1 <= sym;
        d1 <= dec_d;
        k1 <= dec_k;
        bad1 <= dec_bad;
      end

      valid <= v1;
      if (v1) begin
        data <= d1;
        k <= k1;
        code_err <= cerr;
        disp_err <= derr;
        rd <= rd_new;
        if (cerr || derr) begin
          goods <= 4'd0;
          errs <= errs_up[4] ? 4'd15 : errs_up[3:0];
        end else begin
          if (goods != 4'd15) goods <= goods + 4'd1;
          if (errs != 4'd0) errs <= errs - 4'd1;
          if (goods == 4'd14) locked <= 1'b1;
        end
      end
      if (lost) begin
        if (!take) aligned <= 1'b0;
        locked <= 1'b0;
        goods <= 4'd0;
        errs <= 4'd0;
      end
      // 刚按逗号定界：之前的错不算在新边界头上；游程差照逗号的写法认（a 位为 0 的那种出自负游程差）
      if (take) begin
        goods <= 4'd0;
        errs <= 4'd0;
        rd <= win[9];
      end
    end
  end
endmodule
