// 8b/10b 编码（Widmer 与 Franaszek，IEEE 802.3 第 36 条的表 36-1、36-2）。组合逻辑。
// 输入字节 HGFEDCBA 拆成 x = EDCBA 与 y = HGF，分别查 5b/6b 与 3b/4b；code 是 {a,b,c,d,e,i,f,g,h,j}，a 先上线。
// rd 是进来的游程差：0 为负，1 为正。两张表都只存游程差为负时的码字，为正时该取反的取反。
module serdes_enc8b10b (
  input  wire [7:0] d,
  input  wire       k,
  input  wire       rd,
  output wire [9:0] code,
  output wire       rd_next,
  output wire       bad_k      // k 为 1 而 d 不是十二个控制字之一
);
  wire [4:0] x = d[4:0];
  wire [2:0] y = d[7:5];
  wire       k28 = k && x == 5'd28;
  wire       kx7 = k && y == 3'd7 && (x == 5'd23 || x == 5'd27 || x == 5'd29 || x == 5'd30);
  assign bad_k = k && !k28 && !kx7;

  reg [5:0] b6;
  always @* begin
    case (x)
      5'd0:  b6 = 6'b100111;
      5'd1:  b6 = 6'b011101;
      5'd2:  b6 = 6'b101101;
      5'd3:  b6 = 6'b110001;
      5'd4:  b6 = 6'b110101;
      5'd5:  b6 = 6'b101001;
      5'd6:  b6 = 6'b011001;
      5'd7:  b6 = 6'b111000;
      5'd8:  b6 = 6'b111001;
      5'd9:  b6 = 6'b100101;
      5'd10: b6 = 6'b010101;
      5'd11: b6 = 6'b110100;
      5'd12: b6 = 6'b001101;
      5'd13: b6 = 6'b101100;
      5'd14: b6 = 6'b011100;
      5'd15: b6 = 6'b010111;
      5'd16: b6 = 6'b011011;
      5'd17: b6 = 6'b100011;
      5'd18: b6 = 6'b010011;
      5'd19: b6 = 6'b110010;
      5'd20: b6 = 6'b001011;
      5'd21: b6 = 6'b101010;
      5'd22: b6 = 6'b011010;
      5'd23: b6 = 6'b111010;
      5'd24: b6 = 6'b110011;
      5'd25: b6 = 6'b100110;
      5'd26: b6 = 6'b010110;
      5'd27: b6 = 6'b110110;
      5'd28: b6 = k ? 6'b001111 : 6'b001110;
      5'd29: b6 = 6'b101110;
      5'd30: b6 = 6'b011110;
      default: b6 = 6'b101011;
    endcase
  end

  // 六位码里四个 1 的是不平衡的：游程差为正时取反，并翻转游程差。D.07 平衡却也有两种写法
  wire       u6 = ~^b6;
  wire [5:0] c6 = rd && (u6 || (x == 5'd7 && !k)) ? ~b6 : b6;
  wire       rd6 = rd ^ u6;

  // D.x.7 与前面的六位码连起来会出五连 0 或五连 1 时改用备选码；控制字一律用备选码
  wire a7 = k || (!rd6 && (x == 5'd17 || x == 5'd18 || x == 5'd20))
              || ( rd6 && (x == 5'd11 || x == 5'd13 || x == 5'd14));

  reg [3:0] b4;
  always @* begin
    case (y)
      3'd0: b4 = 4'b1011;
      3'd1: b4 = 4'b1001;
      3'd2: b4 = 4'b0101;
      3'd3: b4 = 4'b1100;
      3'd4: b4 = 4'b1101;
      3'd5: b4 = 4'b1010;
      3'd6: b4 = 4'b0110;
      default: b4 = a7 ? 4'b0111 : 4'b1110;
    endcase
  end

  // 四位码里三个 1 的不平衡；.3 平衡却有两种写法。K28 的四位码两种游程差下互为反码
  wire       u4 = ^b4;
  wire       alt4 = u4 || y == 3'd3;
  wire [3:0] c4 = (k28 ? rd6 ~^ alt4 : rd6 && alt4) ? ~b4 : b4;

  assign code = {c6, c4};
  assign rd_next = rd6 ^ u4;
endmodule
