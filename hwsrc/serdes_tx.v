// 发送端：一个符号 10 位，a 先上线，每位占 4 个时钟（接收端按同一个比例过采样）。
// 上层在 ready 那一拍给一个字节；不给就发空闲的 K28.5，线上因此一直有跳变，对端随时能重新定界。
module serdes_tx (
  input  wire       clk,
  input  wire       rst_n,
  input  wire [7:0] d,
  input  wire       k,
  input  wire       valid,
  output wire       ready,
  input  wire       flip,     // 置一拍：把接下来上线的那一位取反，注入一个误码
  output reg        tx
);
  localparam [8:0] IDLE = {1'b1, 8'hbc};   // K28.5

  reg [1:0] ph;      // 位内的拍
  reg [3:0] bc;      // 线上正在发符号的第几位
  reg [9:0] sh;
  reg [8:0] hold;    // 下一个符号，提前一拍取进来，编码的组合路径只跨这一拍
  reg       rd;
  reg       bad;

  wire [9:0] code;
  wire       rdn;
  serdes_enc8b10b enc (.d(hold[7:0]), .k(hold[8]), .rd(rd), .code(code), .rd_next(rdn), .bad_k());

  assign ready = ph == 2'd2 && bc == 4'd9;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph <= 2'd0;
      bc <= 4'd9;
      sh <= 10'd0;
      hold <= IDLE;
      rd <= 1'b0;
      bad <= 1'b0;
      tx <= 1'b0;
    end else begin
      ph <= ph + 2'd1;
      if (flip) bad <= 1'b1;
      if (ready) hold <= valid ? {k, d} : IDLE;
      if (ph == 2'd3) begin
        bad <= flip;
        if (bc == 4'd9) begin
          tx <= code[9] ^ bad;
          sh <= {code[8:0], 1'b0};
          rd <= rdn;
          bc <= 4'd0;
        end else begin
          tx <= sh[9] ^ bad;
          sh <= {sh[8:0], 1'b0};
          bc <= bc + 4'd1;
        end
      end
    end
  end
endmodule
